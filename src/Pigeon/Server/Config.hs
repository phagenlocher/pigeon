-- | Server configuration: flags, environment fallbacks, and validation.
module Pigeon.Server.Config (
  ServerConfig (..),
  TlsMode (..),
  defaultServerConfig,
  parseServerConfig,
  validateServerConfig,
) where

import Control.Monad (unless, when)
import Data.Int (Int64)
import Data.Maybe (fromMaybe, isJust)
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Network.Wai.Handler.Warp (HostPreference)
import Options.Applicative
import System.Directory (doesFileExist, makeAbsolute)
import System.FilePath (isAbsolute, normalise, (</>))
import System.IO (stderr)

import Pigeon.Config (
  exitWithText,
  lookupEnvText,
  normalizeBaseUrl,
  parseByteCount,
  parsePositiveInt,
  requireToken,
  runParser,
  tokenFromSources,
 )
import Pigeon.Duration (parseDuration)
import Pigeon.Types (Secret (..), mkSecret, pigeonVersion)

-- | TLS configuration chosen at startup.
data TlsMode
  = TlsDisabled
  | TlsEnabled FilePath FilePath
  deriving (Eq, Show)

-- | Fully validated server configuration.
data ServerConfig = ServerConfig
  { scHost :: HostPreference,
    scPort :: Int,
    scDataDir :: FilePath,
    scDbPath :: FilePath,
    scToken :: Secret,
    scTlsMode :: TlsMode,
    scPublicUrl :: Text,
    scDefaultExpiry :: Int64,
    scMaxExpiry :: Int64,
    scSweepInterval :: Int64,
    scMaxUploadSize :: Int64,
    scPasswordHashIterations :: Int,
    scQuiet :: Bool,
    scVerbose :: Bool
  }
  deriving (Eq, Show)

{- | A working configuration for tests and embedded use. Callers normally use
'parseServerConfig'.
-}
defaultServerConfig :: ServerConfig
defaultServerConfig =
  ServerConfig
    { scHost = fromString "127.0.0.1",
      scPort = 8080,
      scDataDir = "./data",
      scDbPath = "./data/pigeon.db",
      scToken = mkSecret "dev-token-at-least-16-chars",
      scTlsMode = TlsDisabled,
      scPublicUrl = "http://127.0.0.1:8080",
      scDefaultExpiry = 7 * 86400,
      scMaxExpiry = 365 * 86400,
      scSweepInterval = 60,
      scMaxUploadSize = 0,
      scPasswordHashIterations = 600000,
      scQuiet = False,
      scVerbose = False
    }

data RawOptions = RawOptions
  { roHost :: Maybe String,
    roPort :: Maybe Text,
    roDataDir :: Maybe FilePath,
    roDb :: Maybe FilePath,
    roToken :: Maybe Text,
    roTokenFile :: Maybe FilePath,
    roTlsCert :: Maybe FilePath,
    roTlsKey :: Maybe FilePath,
    roNoTls :: Bool,
    roPublicUrl :: Maybe Text,
    roDefaultExpiry :: Maybe Text,
    roMaxExpiry :: Maybe Text,
    roSweepInterval :: Maybe Text,
    roMaxUploadSize :: Maybe Text,
    roPasswordHashIterations :: Maybe Text,
    roQuiet :: Bool,
    roVerbose :: Bool
  }

rawOptionsParser :: Parser RawOptions
rawOptionsParser =
  RawOptions
    <$> optional (strOption (long "host" <> metavar "HOST" <> help "Bind address (default 127.0.0.1)"))
    <*> optional (strOption (long "port" <> metavar "PORT" <> help "TCP port (default 8080)"))
    <*> optional (strOption (long "data-dir" <> metavar "DIR" <> help "Data directory (default ./data)"))
    <*> optional (strOption (long "db" <> metavar "FILE" <> help "SQLite database path"))
    <*> optional (strOption (long "token" <> metavar "TOKEN" <> help "Shared bearer token"))
    <*> optional (strOption (long "token-file" <> metavar "FILE" <> help "Read the bearer token from FILE"))
    <*> optional (strOption (long "tls-cert" <> metavar "FILE" <> help "PEM certificate chain"))
    <*> optional (strOption (long "tls-key" <> metavar "FILE" <> help "PEM private key"))
    <*> switch (long "no-tls" <> help "Explicitly disable TLS (development only)")
    <*> optional
      (strOption (long "public-url" <> metavar "URL" <> help "Public base URL for share links"))
    <*> optional
      ( strOption
          ( long "default-expiry"
              <> metavar "DURATION"
              <> help "Expiry when uploads omit expires_in (default 7d)"
          )
      )
    <*> optional
      (strOption (long "max-expiry" <> metavar "DURATION" <> help "Maximum allowed expiry (default 365d)"))
    <*> optional
      (strOption (long "sweep-interval" <> metavar "DURATION" <> help "Expiry sweep period (default 60s)"))
    <*> optional
      (strOption (long "max-upload-size" <> metavar "BYTES" <> help "Maximum upload bytes, 0 = unlimited"))
    <*> optional
      ( strOption
          (long "password-hash-iterations" <> metavar "N" <> help "PBKDF2 iterations (default 600000)")
      )
    <*> switch (long "quiet" <> help "Suppress request logs")
    <*> switch (long "verbose" <> help "Enable debug logs")

serverParserInfo :: ParserInfo RawOptions
serverParserInfo =
  info
    (rawOptionsParser <**> helper <**> versionOption)
    ( fullDesc
        <> progDesc "Publish files at unguessable, expiring URLs"
        <> header "pigeon-server"
    )
 where
  versionOption :: Parser (a -> a)
  versionOption =
    infoOption
      (T.unpack pigeonVersion)
      (long "version" <> help "Print version and exit")

-- | Parse command-line flags plus environment fallbacks and validate them.
parseServerConfig :: IO ServerConfig
parseServerConfig = do
  envHost <- fmap T.unpack <$> lookupEnvText "PIGEON_HOST"
  envPort <- lookupEnvText "PIGEON_PORT"
  envDataDir <- fmap T.unpack <$> lookupEnvText "PIGEON_DATA_DIR"
  envDb <- fmap T.unpack <$> lookupEnvText "PIGEON_DB"
  envToken <- lookupEnvText "PIGEON_TOKEN"
  envCert <- fmap T.unpack <$> lookupEnvText "PIGEON_TLS_CERT"
  envKey <- fmap T.unpack <$> lookupEnvText "PIGEON_TLS_KEY"
  envPublicUrl <- lookupEnvText "PIGEON_PUBLIC_URL"
  envDefaultExpiry <- lookupEnvText "PIGEON_DEFAULT_EXPIRY"
  envMaxExpiry <- lookupEnvText "PIGEON_MAX_EXPIRY"
  envSweep <- lookupEnvText "PIGEON_SWEEP_INTERVAL"
  envMaxUpload <- lookupEnvText "PIGEON_MAX_UPLOAD_SIZE"
  envIterations <- lookupEnvText "PIGEON_PASSWORD_HASH_ITERATIONS"

  raw <- runParser "pigeon-server" serverParserInfo
  let pick :: Maybe a -> Maybe a -> Maybe a
      pick cli env = cli <|> env
      host = fromMaybe "127.0.0.1" (pick (roHost raw) envHost)
      portText = fromMaybe "8080" (pick (roPort raw) envPort)
      dataDirText = fromMaybe "./data" (pick (roDataDir raw) envDataDir)
      dbText = pick (roDb raw) envDb
      cert = pick (roTlsCert raw) envCert
      key = pick (roTlsKey raw) envKey
      publicUrlText = pick (roPublicUrl raw) envPublicUrl
      defaultExpiryText = fromMaybe "7d" (pick (roDefaultExpiry raw) envDefaultExpiry)
      maxExpiryText = fromMaybe "365d" (pick (roMaxExpiry raw) envMaxExpiry)
      sweepText = fromMaybe "60s" (pick (roSweepInterval raw) envSweep)
      maxUploadText = fromMaybe "0" (pick (roMaxUploadSize raw) envMaxUpload)
      iterationsText = fromMaybe "600000" (pick (roPasswordHashIterations raw) envIterations)

  token <- requireToken =<< tokenFromSources (roToken raw) (roTokenFile raw) envToken

  port <- case parsePositiveInt portText of
    Right n | n <= 65535 -> pure n
    _ -> exitWithText 1 "error: --port must be an integer between 1 and 65535"

  defaultExpiry <- case parseDuration defaultExpiryText of
    Right n -> pure n
    Left err -> exitWithText 1 ("error: --default-expiry: " <> err)

  maxExpiry <- case parseDuration maxExpiryText of
    Right n -> pure n
    Left err -> exitWithText 1 ("error: --max-expiry: " <> err)

  sweepInterval <- case parseDuration sweepText of
    Right n | n >= 1 -> pure n
    Right _ -> exitWithText 1 "error: --sweep-interval must be at least 1s"
    Left err -> exitWithText 1 ("error: --sweep-interval: " <> err)

  maxUploadSize <- case parseByteCount maxUploadText of
    Right n -> pure n
    Left err -> exitWithText 1 ("error: --max-upload-size: " <> err)

  iterations <- case parsePositiveInt iterationsText of
    Right n | n >= 100000 && n <= 10000000 -> pure n
    _ -> exitWithText 1 "error: --password-hash-iterations must be between 100000 and 10000000"

  when (roNoTls raw && (isJust cert || isJust key)) $ do
    exitWithText 2 "error: --no-tls cannot be combined with --tls-cert or --tls-key"

  tlsMode <- case (roNoTls raw, cert, key) of
    (True, _, _) -> pure TlsDisabled
    (False, Just c, Just k) -> do
      cExists <- doesFileExist c
      kExists <- doesFileExist k
      if cExists && kExists
        then pure (TlsEnabled c k)
        else exitWithText 1 "error: --tls-cert and --tls-key must both exist and be readable"
    (False, _, _) ->
      exitWithText
        1
        "error: TLS is enabled by default; supply --tls-cert and --tls-key, or use --no-tls for development"

  absoluteDataDir <- normalise <$> makeAbsolute dataDirText
  let dbPath :: FilePath
      dbPath = case dbText of
        Nothing -> absoluteDataDir </> "pigeon.db"
        Just p
          | isAbsolute p -> normalise p
          | otherwise -> normalise (absoluteDataDir </> p)

  publicUrl <- case publicUrlText of
    Just url -> case normalizeBaseUrl url of
      Right normalized -> pure normalized
      Left err -> exitWithText 1 ("error: --public-url: " <> err)
    Nothing -> do
      let scheme :: Text
          scheme = case tlsMode of
            TlsDisabled -> "http"
            TlsEnabled{} -> "https"
          url = scheme <> "://127.0.0.1:" <> T.pack (show port)
      unless (isLoopback host) $
        TIO.hPutStrLn
          stderr
          "warning: --public-url not set and --host is not loopback; share links may be wrong"
      pure url

  validateServerConfig
    ServerConfig
      { scHost = fromString host,
        scPort = port,
        scDataDir = absoluteDataDir,
        scDbPath = dbPath,
        scToken = token,
        scTlsMode = tlsMode,
        scPublicUrl = publicUrl,
        scDefaultExpiry = defaultExpiry,
        scMaxExpiry = maxExpiry,
        scSweepInterval = sweepInterval,
        scMaxUploadSize = maxUploadSize,
        scPasswordHashIterations = iterations,
        scQuiet = roQuiet raw,
        scVerbose = roVerbose raw
      }
 where
  isLoopback :: String -> Bool
  isLoopback h = h `elem` ["127.0.0.1", "localhost", "::1", "0:0:0:0:0:0:0:1"]

-- | Final cross-field validation shared by the parser and tests.
validateServerConfig :: ServerConfig -> IO ServerConfig
validateServerConfig cfg
  | scPort cfg < 1 || scPort cfg > 65535 =
      exitWithText 1 "error: port must be between 1 and 65535"
  | scDefaultExpiry cfg <= 0 =
      exitWithText 1 "error: default expiry must be greater than zero"
  | scMaxExpiry cfg <= 0 =
      exitWithText 1 "error: maximum expiry must be greater than zero"
  | scDefaultExpiry cfg > scMaxExpiry cfg =
      exitWithText 1 "error: default expiry must not exceed maximum expiry"
  | scSweepInterval cfg < 1 =
      exitWithText 1 "error: sweep interval must be at least 1s"
  | scPasswordHashIterations cfg < 100000 || scPasswordHashIterations cfg > 10000000 =
      exitWithText 1 "error: password hash iterations must be between 100000 and 10000000"
  | scMaxUploadSize cfg < 0 =
      exitWithText 1 "error: maximum upload size must not be negative"
  | T.null (unSecret (scToken cfg)) =
      exitWithText 1 "error: a token is required"
  | otherwise = pure cfg
