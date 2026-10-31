-- | Client configuration and CLI grammar.
module Pigeon.Client.Config (
  ClientConfig (..),
  ClientCommand (..),
  UploadOptions (..),
  DeleteOptions (..),
  PasswordSource (..),
  parseClientConfig,
  defaultClientConfig,
) where

import Control.Monad (when)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative
import Servant.Client.Core (BaseUrl (..), Scheme (..))
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

import Pigeon.Config (
  lookupEnvText,
  normalizeBaseUrl,
  parseBaseUrlText,
  requireToken,
  runParser,
  tokenFromSources,
 )
import Pigeon.Duration (parseDuration)
import Pigeon.Types (Secret, mkSecret)

-- | Where a file password comes from.
data PasswordSource
  = NoPassword
  | PromptPassword
  | StdinPassword
  deriving (Eq, Show)

data UploadOptions = UploadOptions
  { uoFile :: FilePath,
    uoExpiresIn :: Maybe Int64,
    uoName :: Maybe Text,
    uoContentType :: Maybe Text,
    uoPassword :: PasswordSource,
    uoNoCompress :: Bool
  }
  deriving (Eq, Show)

data DeleteOptions = DeleteOptions
  { doIds :: [Text],
    doYes :: Bool
  }
  deriving (Eq, Show)

data ClientCommand
  = Upload UploadOptions
  | List
  | Delete DeleteOptions
  deriving (Eq, Show)

-- | Fully resolved client configuration.
data ClientConfig = ClientConfig
  { ccServer :: BaseUrl,
    ccServerText :: Text,
    ccToken :: Secret,
    ccInsecure :: Bool,
    ccTimeoutSeconds :: Int64,
    ccJson :: Bool,
    ccQuiet :: Bool,
    ccVerbose :: Bool,
    ccCommand :: ClientCommand
  }
  deriving (Eq, Show)

-- | A configuration for tests and embedded use.
defaultClientConfig :: ClientConfig
defaultClientConfig =
  ClientConfig
    { ccServer = BaseUrl Http "127.0.0.1" 8080 "",
      ccServerText = "http://127.0.0.1:8080",
      ccToken = mkSecret "dev-token-at-least-16-chars",
      ccInsecure = False,
      ccTimeoutSeconds = 3600,
      ccJson = False,
      ccQuiet = False,
      ccVerbose = False,
      ccCommand = List
    }

durationSecondsOption :: Mod OptionFields Int64 -> Parser Int64
durationSecondsOption =
  option (eitherReader parseReader)
 where
  parseReader :: String -> Either String Int64
  parseReader raw = case parseDuration (T.pack raw) of
    Left message -> Left (T.unpack message)
    Right seconds -> Right seconds

data RawGlobal = RawGlobal
  { rgServer :: Maybe Text,
    rgToken :: Maybe Text,
    rgTokenFile :: Maybe FilePath,
    rgInsecure :: Bool,
    rgTimeout :: Maybe Int64,
    rgJson :: Bool,
    rgQuiet :: Bool,
    rgVerbose :: Bool
  }

data RawClient = RawClient
  { rcGlobal :: RawGlobal,
    rcCommand :: ClientCommand
  }

globalParser :: Parser RawGlobal
globalParser =
  RawGlobal
    <$> optional
      (T.pack <$> strOption (long "server" <> metavar "URL" <> help "Server base URL (env: PIGEON_SERVER)"))
    <*> optional
      (T.pack <$> strOption (long "token" <> metavar "TOKEN" <> help "Bearer token (env: PIGEON_TOKEN)"))
    <*> optional
      (strOption (long "token-file" <> metavar "FILE" <> help "Read the token from the first line of FILE"))
    <*> switch (long "insecure" <> help "Disable TLS certificate validation (development only)")
    <*> optional
      (durationSecondsOption (long "timeout" <> metavar "DURATION" <> help "Request timeout (default 1h)"))
    <*> switch (long "json" <> help "Machine-readable output")
    <*> switch (long "quiet" <> help "Suppress progress and informational messages")
    <*> switch (long "verbose" <> help "Debug output on stderr")

uploadParser :: Parser ClientCommand
uploadParser =
  Upload
    <$> ( UploadOptions
            <$> argument str (metavar "FILE")
            <*> optional
              ( durationSecondsOption
                  (long "expires-in" <> metavar "DURATION" <> help "Lifetime; server default when omitted")
              )
            <*> optional (T.pack <$> strOption (long "name" <> metavar "NAME" <> help "Display filename"))
            <*> optional
              (T.pack <$> strOption (long "content-type" <> metavar "TYPE" <> help "Original content type"))
            <*> passwordParser
            <*> switch (long "no-compress" <> help "Send the body without gzip compression")
        )
 where
  passwordParser :: Parser PasswordSource
  passwordParser =
    fmap
      (fromMaybe NoPassword)
      ( optional
          ( flag' PromptPassword (long "password" <> help "Prompt for a password without echo")
              <|> flag' StdinPassword (long "password-stdin" <> help "Read one password line from stdin")
          )
      )

deleteParser :: Parser ClientCommand
deleteParser =
  Delete
    <$> ( DeleteOptions
            <$> some (T.pack <$> argument str (metavar "ID"))
            <*> switch (long "yes" <> help "Do not ask for confirmation")
        )

commandParser :: Parser ClientCommand
commandParser =
  hsubparser
    ( command "upload" (info uploadParser (progDesc "Upload a file"))
        <> command "list" (info (pure List) (progDesc "List live files"))
        <> command "delete" (info deleteParser (progDesc "Delete files by id"))
    )

rawParser :: Parser RawClient
rawParser = RawClient <$> globalParser <*> commandParser

clientParserInfo :: ParserInfo RawClient
clientParserInfo =
  info
    (rawParser <**> helper <**> versionOption)
    ( fullDesc
        <> progDesc "Upload, list, and delete Pigeon files"
        <> header "pigeon-client"
    )
 where
  versionOption :: Parser (a -> a)
  versionOption =
    infoOption
      "0.1.0.0"
      (long "version" <> help "Print version and exit")

{- | Parse global options and the subcommand, resolve environment fallbacks,
and validate everything that can be checked before a network call. Transport
warnings are always written to stderr, even with @--quiet@.
-}
parseClientConfig :: IO ClientConfig
parseClientConfig = do
  raw <- runParser "pigeon-client" clientParserInfo
  let global = rcGlobal raw
      clientCommand = rcCommand raw
  let RawGlobal{..} = global
  envServer <- lookupEnvText "PIGEON_SERVER"
  envToken <- lookupEnvText "PIGEON_TOKEN"

  when (rgQuiet && rgVerbose) $ do
    hPutStrLn stderr "error: --quiet and --verbose are mutually exclusive"
    exitWith (ExitFailure 2)

  let serverText = fromMaybe "http://127.0.0.1:8080" (rgServer <|> envServer)
  serverBase <- case normalizeBaseUrl serverText of
    Left message -> do
      hPutStrLn stderr ("error: --server: " <> T.unpack message)
      exitWith (ExitFailure 2)
    Right normalized -> case parseBaseUrlText normalized of
      Left message -> do
        hPutStrLn stderr ("error: --server: " <> T.unpack message)
        exitWith (ExitFailure 2)
      Right base -> pure (base, normalized)

  token <- requireToken =<< tokenFromSources rgToken rgTokenFile envToken

  timeout <- case rgTimeout of
    Nothing -> pure 3600
    Just seconds | seconds >= 1 -> pure seconds
    Just _ -> do
      hPutStrLn stderr "error: --timeout must be at least 1s"
      exitWith (ExitFailure 2)

  validatedCommand <- validateCommand clientCommand

  let (baseUrl, serverUrlText) = serverBase
  when ("http://" `T.isPrefixOf` serverUrlText) $
    hPutStrLn stderr "warning: sending the upload token over plain HTTP; use TLS outside development"
  when (rgInsecure && "https://" `T.isPrefixOf` serverUrlText) $
    hPutStrLn stderr "warning: TLS certificate validation is disabled"

  pure
    ClientConfig
      { ccServer = baseUrl,
        ccServerText = serverUrlText,
        ccToken = token,
        ccInsecure = rgInsecure,
        ccTimeoutSeconds = timeout,
        ccJson = rgJson,
        ccQuiet = rgQuiet,
        ccVerbose = rgVerbose,
        ccCommand = validatedCommand
      }

validateCommand :: ClientCommand -> IO ClientCommand
validateCommand = \case
  Upload options -> do
    let expires = uoExpiresIn options
    name <- case uoName options of
      Nothing -> pure Nothing
      Just n
        | T.null n -> usage "error: --name must not be empty"
        | otherwise -> pure (Just n)
    contentType <- case uoContentType options of
      Nothing -> pure Nothing
      Just rawContentType
        | validContentType rawContentType -> pure (Just rawContentType)
        | otherwise -> usage "error: --content-type contains invalid characters"
    pure (Upload options{uoExpiresIn = expires, uoName = name, uoContentType = contentType})
  List -> pure List
  Delete options
    | null (doIds options) -> usage "error: delete requires at least one id"
    | otherwise -> pure (Delete options)
 where
  usage :: String -> IO a
  usage message = do
    hPutStrLn stderr message
    exitWith (ExitFailure 2)

validContentType :: Text -> Bool
validContentType rawType =
  not (T.null rawType)
    && T.length rawType <= 255
    && T.all (\c -> c >= ' ' && c <= '~') rawType
