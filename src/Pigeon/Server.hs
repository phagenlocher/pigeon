-- | Server assembly, lifecycle, and graceful shutdown.
module Pigeon.Server (
  runServer,
  mkApp,
  mkAppEnv,
  closeAppEnv,
) where

import Control.Concurrent.Async (cancel, waitCatch)
import Control.Concurrent.MVar (modifyMVar, newMVar)
import Control.Exception.Safe (SomeException, bracket, catch, finally)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import Data.Proxy (Proxy (..))
import Data.Tagged (Tagged (..))
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Network.HTTP.Types (ResponseHeaders, hCacheControl)
import Network.Wai (
  Application,
  Middleware,
  Request,
  Response,
  mapResponseHeaders,
  modifyResponse,
  pathInfo,
  requestMethod,
 )
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Handler.WarpTLS qualified as WarpTLS
import Servant (ServerT, hoistServer, serve, (:<|>) (..))
import System.Exit (ExitCode (..), exitWith)
import System.IO (stderr)
import System.Posix.Process (exitImmediately)
import System.Posix.Signals (
  Handler (Catch),
  installHandler,
  sigINT,
  sigTERM,
 )

import Pigeon.API (FullAPI)
import Pigeon.Server.App (App, MonadLogger (..), appToHandler, runApp)
import Pigeon.Server.Config (ServerConfig (..), TlsMode (..))
import Pigeon.Server.Db (closeDb, migrate, openDb)
import Pigeon.Server.Env (AppEnv (..))
import Pigeon.Server.Handlers (
  deleteHandler,
  healthHandler,
  listHandler,
  uploadHandler,
 )
import Pigeon.Server.Log (
  closeLogger,
  logError,
  logInfo,
  logWarn,
  mkLogger,
  requestLogger,
 )
import Pigeon.Server.PathSafety (UnsafePath (..))
import Pigeon.Server.Storage (StorageHooks (..), defaultStorageHooks, initStorage)
import Pigeon.Server.Sweeper (reconcile, startSweeper)
import Pigeon.Server.Web (robotsHandler, webHandler)

-- | Build the environment without starting a listener. Useful for tests.
mkAppEnv :: ServerConfig -> IO AppEnv
mkAppEnv cfg = do
  logger <- mkLogger cfg
  storage <-
    initStorage
      defaultStorageHooks
        { shWarn = logWarn logger,
          shError = logError logger
        }
      (scDataDir cfg)
  db <- openDb (scDbPath cfg)
  migrate db
  start <- getCurrentTime
  pure
    AppEnv
      { aeConfig = cfg,
        aeDb = db,
        aeStorage = storage,
        aeLogger = logger,
        aeStart = start
      }

closeAppEnv :: AppEnv -> IO ()
closeAppEnv env = do
  closeDb (aeDb env)
  closeLogger (aeLogger env)

-- | Compose middleware and the Servant application.
mkApp :: AppEnv -> Application
mkApp env =
  requestLogger (aeLogger env)
    . securityHeaders (aeConfig env)
    . modifyResponse addNoStore
    $ serve
      (Proxy :: Proxy FullAPI)
      (hoistServer (Proxy :: Proxy FullAPI) (appToHandler env) (server env))

server :: AppEnv -> ServerT FullAPI App
server env =
  ( uploadHandler
      :<|> listHandler
      :<|> deleteHandler
      :<|> healthHandler
  )
    :<|> ( Tagged . webHandler env
             :<|> robotsHandler
         )

-- | Add @Cache-Control: no-store@ when the response did not set one.
addNoStore :: Response -> Response
addNoStore = mapResponseHeaders addIfMissing
 where
  addIfMissing :: ResponseHeaders -> ResponseHeaders
  addIfMissing headers
    | any ((== hCacheControl) . fst) headers = headers
    | otherwise = (hCacheControl, "no-store") : headers

-- | Add HSTS when the configured public URL uses HTTPS.
securityHeaders :: ServerConfig -> Middleware
securityHeaders cfg = modifyResponse addHstsIfHttps
 where
  addHstsIfHttps :: Response -> Response
  addHstsIfHttps response
    | not ("https://" `T.isPrefixOf` scPublicUrl cfg) = response
    | otherwise =
        mapResponseHeaders
          ( \headers ->
              if any ((== "Strict-Transport-Security") . fst) headers
                then headers
                else ("Strict-Transport-Security", "max-age=31536000") : headers
          )
          response

-- | Run the server until a termination signal arrives.
runServer :: ServerConfig -> IO ()
runServer cfg =
  bracket (mkAppEnv cfg) closeAppEnv serveApp `catch` reportUnsafePath
 where
  serveApp :: AppEnv -> IO ()
  serveApp env = do
    result <- runApp env serveForever
    case result of
      Left serverError -> do
        logError (aeLogger env) ("server failed: " <> T.pack (show serverError))
      Right () -> pure ()

  reportUnsafePath :: UnsafePath -> IO ()
  reportUnsafePath (UnsafePath message) = do
    TIO.hPutStrLn stderr ("error: " <> message)
    exitWith (ExitFailure 1)

serveForever :: App ()
serveForever = do
  env <- ask
  reconcile
  sweeper <- startSweeper
  let app = mkApp env
      settings = warpSettings env
  logger <- askLogger
  liftIO
    $ logInfo logger
    $ "startup host="
      <> T.pack (show (scHost (aeConfig env)))
      <> " port="
      <> T.pack (show (scPort (aeConfig env)))
      <> " tls="
      <> (case scTlsMode (aeConfig env) of TlsDisabled -> "off"; TlsEnabled{} -> "on")
      <> " data_dir="
      <> T.pack (scDataDir (aeConfig env))
      <> " default_expiry="
      <> T.pack (show (scDefaultExpiry (aeConfig env)))
      <> " max_expiry="
      <> T.pack (show (scMaxExpiry (aeConfig env)))
      <> " token=<redacted>"
  when (scTlsMode (aeConfig env) == TlsDisabled) $
    liftIO (logWarn logger "WARNING: TLS disabled; tokens and passwords are transmitted in plaintext")
  liftIO $
    ( case scTlsMode (aeConfig env) of
        TlsDisabled -> Warp.runSettings settings app
        TlsEnabled cert key -> WarpTLS.runTLS (WarpTLS.tlsSettings cert key) settings app
    )
      `finally` do
        cancel sweeper
        _ <- waitCatch sweeper
        pure ()
  liftIO (logInfo logger "shutdown complete")

warpSettings :: AppEnv -> Warp.Settings
warpSettings env =
  Warp.setPort (scPort cfg)
    . Warp.setHost (scHost cfg)
    . Warp.setServerName "pigeon"
    . Warp.setTimeout 300
    . Warp.setGracefulShutdownTimeout (Just 30)
    . Warp.setInstallShutdownHandler installShutdown
    . Warp.setOnException onException
    $ Warp.defaultSettings
 where
  cfg :: ServerConfig
  cfg = aeConfig env
  installShutdown :: IO () -> IO ()
  installShutdown closeSocket = do
    stopState <- newMVar False
    let handleSignal :: IO ()
        handleSignal = do
          alreadyStopping <- modifyMVar stopState $ \stopping -> pure (True, stopping)
          if alreadyStopping
            then exitImmediately ExitSuccess
            else closeSocket
    _ <- installHandler sigINT (Catch handleSignal) Nothing
    _ <- installHandler sigTERM (Catch handleSignal) Nothing
    pure ()

  onException :: Maybe Request -> SomeException -> IO ()
  onException maybeRequest exception = do
    let path :: T.Text
        path = case maybeRequest of
          Nothing -> ""
          Just request -> T.intercalate "/" ("/" : pathInfo request)
        method :: T.Text
        method = maybe "" (decodeUtf8With lenientDecode . requestMethod) maybeRequest
    logError (aeLogger env) $
      "request failed method="
        <> method
        <> " path="
        <> path
        <> " cause="
        <> T.pack (show exception)
