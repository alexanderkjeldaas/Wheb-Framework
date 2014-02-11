{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE MultiParamTypeClasses      #-}

module Web.Wheb.Types where

import           Blaze.ByteString.Builder (Builder, fromLazyByteString)
import           Control.Concurrent.STM
import           Control.Applicative
import           Control.Monad.Error
import           Control.Monad.Trans
import           Control.Monad.IO.Class
import           Control.Monad.State
import           Control.Monad.Reader
import           Control.Monad.Writer
import           Data.Monoid ((<>))

import qualified Data.ByteString.Lazy as LBS
import           Data.List (intercalate)
import           Data.Map as M
import           Data.String (IsString(..))
import qualified Data.Text.Lazy as T
import           Data.Typeable

import           Network.Wai (Request, Response, Middleware, responseBuilder)
import           Network.Wai.Handler.Warp as Warp
import           Network.Wai.Parse
import           Network.HTTP.Types.Method
import           Network.HTTP.Types.Status
import           Network.HTTP.Types.Header

import           Data.ByteString (ByteString)


-- | WhebT g s m
--
--   * g -> The global confirgured context (Read-only data shared between threads)
-- 
--   * s -> Handler state initailized at the start of each request using Default
--
--   * m -> Monad we are transforming
newtype WhebT g s m a = WhebT 
  { runWhebT :: ErrorT WhebError 
                  (ReaderT (HandlerData g s m) (StateT (InternalState s) m)) a 
  } deriving ( Functor, Applicative, Monad, MonadIO )

instance MonadTrans (WhebT g s) where
  lift = WhebT . lift . lift . lift

instance (Monad m) => MonadError WhebError (WhebT g s m) where
    throwError = WhebT . throwError
    catchError (WhebT m) f = WhebT  (catchError m (runWhebT . f))

-- | Writer Monad to build options.
newtype InitM g s m a = InitM { runInitM :: WriterT (InitOptions g s m) IO a}
  deriving (Functor, Applicative, Monad, MonadIO)

-- | Converts a type to a WAI 'Response'
class WhebContent a where
  toResponse :: Status -> ResponseHeaders -> a -> Response

-- | A Wheb response that represents a file.
data WhebFile = WhebFile T.Text

data HandlerResponse = forall a . WhebContent a => HandlerResponse Status a

-- | Our 'ReaderT' portion of 'WhebT' uses this.
data HandlerData g s m = 
  HandlerData { globalCtx      :: g
              , request        :: Request
              , postData       :: ([Param], [File LBS.ByteString])
              , routeParams    :: RouteParamList
              , globalSettings :: WhebOptions g s m }

-- | Our 'StateT' portion of 'WhebT' uses this.
data InternalState s =
  InternalState { reqState     :: s
                , respHeaders  :: M.Map HeaderName ByteString } 
                
data SettingsValue = forall a. (Typeable a) => MkVal a

data WhebError = Error500 String 
               | Error404
               | Error403
               | RouteParamDoesNotExist
               | URLError T.Text UrlBuildError
  deriving (Show)

instance Error WhebError where 
    strMsg = Error500

-- | Monoid to use in InitM's WriterT
data InitOptions g s m =
  InitOptions { initRoutes      :: [ Route g s m ]
              , initSettings    :: CSettings
              , initWaiMw       :: Middleware
              , initWhebMw      :: [ WhebMiddleware g s m ]
              , initCleanup     :: [ IO () ] }

instance Monoid (InitOptions g s m) where
  mappend (InitOptions a1 b1 c1 d1 e1) (InitOptions a2 b2 c2 d2 e2) = 
      InitOptions (a1 <> a2) (b1 <> b2) (c2 . c1) (d1 <> d2) (e1 <> e2)
  mempty = InitOptions mempty mempty id mempty mempty

-- | The main option datatype for Wheb
data WhebOptions g s m = MonadIO m => 
  WhebOptions { appRoutes           :: [ Route g s m ]
              , runTimeSettings     :: CSettings
              , warpSettings        :: Warp.Settings
              , startingCtx         :: g -- ^ Global ctx shared between requests
              , startingState       :: InternalState s -- ^ Handler state given each request
              , waiStack            :: Middleware
              , whebMiddlewares     :: [ WhebMiddleware g s m ]
              , defaultErrorHandler :: WhebError -> WhebHandlerT g s m
              , shutdownTVar       :: TVar Bool
              , activeConnections   :: TVar Int
              , cleanupActions      :: [ IO () ] }

type EResponse = Either WhebError Response

type CSettings = M.Map T.Text SettingsValue
    
type WhebHandler g s      = WhebT g s IO HandlerResponse
type WhebHandlerT g s m   = WhebT g s m HandlerResponse
type WhebMiddleware g s m = WhebT g s m (Maybe HandlerResponse)

-- | A minimal type for WhebT
type MinWheb a = WhebT () () IO a
type MinHandler = MinWheb HandlerResponse
-- | A minimal type for WhebOptions
type MinOpts = WhebOptions () () IO

-- * Routes

type  RouteParamList = [(T.Text, ParsedChunk)]
type  MethodMatch = StdMethod -> Bool

data ParsedChunk = forall a. (Typeable a, Show a) => MkChunk a

instance Show ParsedChunk where
  show (MkChunk a) = show a

data UrlBuildError = NoParam | ParamTypeMismatch T.Text | UrlNameNotFound
     deriving (Show) 

-- | A Parser should be able to extract params and regenerate URL from params.
data UrlParser = UrlParser 
    { parseFunc :: ([T.Text] -> Maybe RouteParamList)
    , genFunc   :: (RouteParamList -> Either UrlBuildError T.Text) }

data Route g s m = Route 
  { routeName    :: (Maybe T.Text)
  , routeMethod  :: MethodMatch
  , routeParser  :: UrlParser
  , routeHandler :: (WhebHandlerT g s m) }

data ChunkType = IntChunk | TextChunk
  deriving (Show)

data UrlPat = Chunk T.Text
            | Composed [UrlPat]
            | FuncChunk 
                { chunkParamName :: T.Text
                , chunkFunc :: (T.Text -> Maybe ParsedChunk)
                , chunkType :: ChunkType }

instance Show UrlPat where
  show (Chunk a) = "(Chunk " ++ (T.unpack a) ++ ")"
  show (Composed a) = intercalate "/" $ fmap show a
  show (FuncChunk pn _ ct) = "(FuncChunk " ++ (T.unpack pn) ++ " | " ++ (show ct) ++ ")"

instance IsString UrlPat where
  fromString = Chunk . T.pack