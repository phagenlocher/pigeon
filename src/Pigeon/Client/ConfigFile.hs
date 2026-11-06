{- | TOML configuration file support for @pigeon-client@.

The file supplies defaults for the global options so that a user can store
@server@ and @token@ once and then run bare commands such as
@pigeon-client upload report.pdf@. Command-line flags and environment
variables always win over the file (CLI-046). Errors reported about the file
never echo the value of @token@ or @token-file@ (CLI-048): secret values are
redacted from the text before any parser message is rendered.
-}
module Pigeon.Client.ConfigFile (
  FileConfig (..),
  emptyFileConfig,
  TokenLayer (..),
  defaultConfigPath,
  loadFileConfig,
  decodeFileConfig,
  selectTokenLayer,
  resolveServerText,
  expandHomePath,
  expandConfigPaths,
  redactSecretValues,
) where

import Control.Applicative ((<|>))
import Control.Exception.Safe (IOException, try)
import Data.Bifunctor (first)
import Data.Char (isDigit, isSpace)
import Data.HashMap.Strict qualified as HashMap
import Data.List (sort)
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (
  XdgDirectory (XdgConfig),
  doesFileExist,
  getHomeDirectory,
  getXdgDirectory,
 )
import System.FilePath ((</>))
import Toml (
  Codec (..),
  Key,
  TOML (..),
  TomlCodec,
  TomlDecodeError (..),
  bool,
  decode,
  parse,
  prettyKey,
  text,
  unPiece,
  unTomlParseError,
  (.=),
 )
import Validation (Validation (..))

-- | Client defaults supplied by the TOML configuration file (CLI-045).
data FileConfig = FileConfig
  { fcServer :: Maybe Text,
    fcToken :: Maybe Text,
    fcTokenFile :: Maybe Text,
    fcInsecure :: Maybe Bool,
    fcNoHttpWarning :: Maybe Bool
  }
  deriving (Eq, Show)

-- | The configuration of a missing or absent default file.
emptyFileConfig :: FileConfig
emptyFileConfig = FileConfig Nothing Nothing Nothing Nothing Nothing

-- | tomland codec for the flat configuration schema.
fileConfigCodec :: TomlCodec FileConfig
fileConfigCodec =
  FileConfig
    <$> strictOptional (text "server") .= fcServer
    <*> strictOptional (text "token") .= fcToken
    <*> strictOptional (text "token-file") .= fcTokenFile
    <*> strictOptional (bool "insecure") .= fcInsecure
    <*> strictOptional (bool "no-http-warning") .= fcNoHttpWarning

{- | Variant of tomland's @dioptional@ that treats only an absent key as
'Nothing'. Unlike @dioptional@, a present key with a wrong-typed value fails to
decode instead of being silently dropped (CLI-045).
-}
strictOptional :: TomlCodec a -> TomlCodec (Maybe a)
strictOptional codec =
  Codec
    { codecRead = \toml -> case codecRead codec toml of
        Success value -> Success (Just value)
        Failure errors
          | any isKeyNotFound errors -> Success Nothing
          | otherwise -> Failure errors,
      codecWrite = traverse (codecWrite codec)
    }
 where
  isKeyNotFound :: TomlDecodeError -> Bool
  isKeyNotFound = \case
    KeyNotFound _ -> True
    _ -> False

-- | Every top-level key the schema understands; anything else is rejected (CLI-045).
knownConfigKeys :: [Text]
knownConfigKeys = ["server", "token", "token-file", "insecure", "no-http-warning"]

-- | Keys whose values are secrets and must never appear in an error message.
secretConfigKeys :: [Text]
secretConfigKeys = ["token", "token-file"]

-- | The placeholder that replaces a redacted secret value (CLI-048).
redactedPlaceholder :: Text
redactedPlaceholder = "\"REDACTED\""

{- | The configuration path used when @--config@ is not given:
@$XDG_CONFIG_HOME/pigeon/config.toml@, which defaults to
@~/.config/pigeon/config.toml@ (CLI-044).
-}
defaultConfigPath :: IO FilePath
defaultConfigPath = do
  dir <- getXdgDirectory XdgConfig "pigeon"
  pure (dir </> "config.toml")

{- | Load the client configuration file. A missing file at the default path is
silently ignored (CLI-047); an explicit @--config@ path that does not exist or
cannot be read is an error whose message names the path.
-}
loadFileConfig :: Maybe FilePath -> IO (Either Text FileConfig)
loadFileConfig explicitPath = case explicitPath of
  Just path -> loadExisting (labelFor path) path
  Nothing -> do
    path <- defaultConfigPath
    exists <- doesFileExist path
    if exists
      then loadExisting (labelFor path) path
      else pure (Right emptyFileConfig)
 where
  loadExisting :: Text -> FilePath -> IO (Either Text FileConfig)
  loadExisting label path = do
    exists <- doesFileExist path
    if not exists
      then pure (Left (label <> ": file not found"))
      else do
        result <- try (TIO.readFile path)
        pure $ case result of
          Left (_ :: IOException) -> Left (label <> ": file could not be read")
          Right contents -> first ((label <> ": ") <>) (decodeFileConfig contents)

  labelFor :: FilePath -> Text
  labelFor path = case explicitPath of
    Just _ -> "--config (" <> T.pack path <> ")"
    Nothing -> "config file " <> T.pack path

{- | Decode configuration file contents. Unknown top-level keys are rejected by
name (CLI-045); parse and type errors are reported without ever echoing the
value of @token@ or @token-file@ (CLI-048).
-}
decodeFileConfig :: Text -> Either Text FileConfig
decodeFileConfig contents = case parse contents of
  Left _ -> Left (parseErrorMessage contents)
  Right toml ->
    checkUnknownKeys toml
      >> first renderDecodeErrors (decode fileConfigCodec contents)

-- | Reject top-level keys outside the schema, reporting names only (CLI-045).
checkUnknownKeys :: TOML -> Either Text ()
checkUnknownKeys toml = case sort unknown of
  [] -> Right ()
  names -> Left ("unknown config key(s): " <> T.intercalate ", " names)
 where
  unknown :: [Text]
  unknown =
    filter (`notElem` knownConfigKeys) $
      map prettyKey (HashMap.keys (tomlPairs toml))
        <> map unPiece (HashMap.keys (tomlTables toml))
        <> map prettyKey (HashMap.keys (tomlTableArrays toml))

-- | Render decoder failures as one line that contains key names but no values.
renderDecodeErrors :: [TomlDecodeError] -> Text
renderDecodeErrors errors =
  case errors of
    [] -> "invalid configuration"
    _ -> T.intercalate "; " (map renderDecodeError errors)

-- | The message for one decoder error; values are never included (CLI-048).
renderDecodeError :: TomlDecodeError -> Text
renderDecodeError = \case
  BiMapError key _ -> "invalid value for '" <> prettyKey key <> "'" <> expectedType key
  KeyNotFound key -> "missing key '" <> prettyKey key <> "'"
  TableNotFound key -> "unexpected table '" <> prettyKey key <> "'"
  TableArrayNotFound key -> "unexpected table array '" <> prettyKey key <> "'"
  ParseError _ -> "invalid TOML syntax"
  NotExactDecode _ -> "unexpected extra keys"

-- | The expected-type suffix for a known key, empty for anything else.
expectedType :: Key -> Text
expectedType key = case prettyKey key of
  "server" -> ": expected a string"
  "token" -> ": expected a string"
  "token-file" -> ": expected a string"
  "insecure" -> ": expected a boolean"
  "no-http-warning" -> ": expected a boolean"
  _ -> ""

{- | The message for a TOML parse failure. The contents are re-parsed after
secret values are redacted, so the rendered megaparsec output can only quote
redacted text; if the redacted copy parses cleanly, the failure was inside a
secret value and a generic message is used instead (CLI-048).
-}
parseErrorMessage :: Text -> Text
parseErrorMessage contents =
  case parse (redactSecretValues contents) of
    Left redactedError -> summarizeParseError (unTomlParseError redactedError)
    Right _ -> "invalid TOML syntax in a 'token' or 'token-file' value"

-- | Compress megaparsec's multiline output into one line with a position and reason.
summarizeParseError :: Text -> Text
summarizeParseError pretty =
  "invalid TOML syntax" <> positionSuffix <> reasonSuffix
 where
  prettyLines :: [Text]
  prettyLines = T.lines pretty

  positionSuffix :: Text
  positionSuffix =
    case listToMaybe (mapMaybe parsePosition prettyLines) of
      Nothing -> ""
      Just (line, column) -> " at line " <> line <> ", column " <> column

  reasonSuffix :: Text
  reasonSuffix =
    case listToMaybe (mapMaybe reasonLine prettyLines) of
      Nothing -> ""
      Just reason -> " (" <> reason <> ")"

  parsePosition :: Text -> Maybe (Text, Text)
  parsePosition line =
    case reverse (filter (not . T.null) (T.splitOn ":" line)) of
      (column : lineNo : _) | isNumberText column && isNumberText lineNo -> Just (lineNo, column)
      _ -> Nothing

  reasonLine :: Text -> Maybe Text
  reasonLine = T.stripPrefix "unexpected "

  isNumberText :: Text -> Bool
  isNumberText value = not (T.null value) && T.all isDigit value

{- | Replace the value of every @token@ or @token-file@ assignment with a fixed
placeholder, keeping the line count intact so error positions rendered from the
redacted copy still point at the original file. Multi-line string values are
redacted up to their closing delimiter; continuation lines become comments.
-}
redactSecretValues :: Text -> Text
redactSecretValues = T.unlines . maskLines False . T.lines
 where
  maskLines :: Bool -> [Text] -> [Text]
  maskLines inSecret = \case
    [] -> []
    (line : rest)
      | inSecret -> "#" : maskLines (not (hasDelimiter line)) rest
      | otherwise -> case secretAssignment line of
          Nothing -> line : maskLines False rest
          Just (key, value) ->
            (key <> " = " <> redactedPlaceholder) : maskLines (opensMultiline value) rest

  hasDelimiter :: Text -> Bool
  hasDelimiter line = T.isInfixOf "\"\"\"" line || T.isInfixOf "'''" line

  opensMultiline :: Text -> Bool
  opensMultiline value = any check ["\"\"\"", "'''"]
   where
    check :: Text -> Bool
    check delimiter = case T.stripPrefix delimiter (T.stripStart value) of
      Just remainder -> not (T.isInfixOf delimiter remainder)
      Nothing -> False

  secretAssignment :: Text -> Maybe (Text, Text)
  secretAssignment line =
    listToMaybe
      [ (key, value)
      | key <- secretConfigKeys,
        Just afterKey <-
          [ T.stripPrefix ("\"" <> key <> "\"") stripped
              <|> T.stripPrefix key stripped
          ],
        boundaryOk afterKey,
        Just value <- [afterEquals afterKey]
      ]
   where
    stripped :: Text
    stripped = T.stripStart line

    boundaryOk :: Text -> Bool
    boundaryOk value = case T.uncons value of
      Nothing -> False
      Just (c, _) -> isSpace c || c == '='

    afterEquals :: Text -> Maybe Text
    afterEquals value = case T.uncons (T.dropWhile isSpace value) of
      Just ('=', remainder) -> Just remainder
      _ -> Nothing

-- | Expand a leading @~@ or @~/@ in a configuration-file path to the home directory.
expandHomePath :: FilePath -> IO FilePath
expandHomePath path = case path of
  "~" -> getHomeDirectory
  '~' : '/' : rest -> do
    home <- getHomeDirectory
    pure (home </> rest)
  _ -> pure path

-- | Expand @~@ in the configuration file's @token-file@ path.
expandConfigPaths :: FileConfig -> IO FileConfig
expandConfigPaths config = case fcTokenFile config of
  Nothing -> pure config
  Just tokenFile -> do
    expanded <- expandHomePath (T.unpack tokenFile)
    pure config{fcTokenFile = Just (T.pack expanded)}

-- | The layer that supplies the bearer token once precedence is applied.
data TokenLayer
  = TokenText Text
  | TokenPath FilePath
  deriving (Eq, Show)

{- | Choose the token source with the documented precedence: @--token@, then
@--token-file@, then @PIGEON_TOKEN@, then the config file's @token@, then the
config file's @token-file@ (CLI-046). Mutually exclusive sources within the CLI
layer or within the config file are rejected (CLI-022).
-}
selectTokenLayer ::
  Maybe Text ->
  Maybe FilePath ->
  Maybe Text ->
  FileConfig ->
  Either Text TokenLayer
selectTokenLayer flagToken flagTokenFile envToken config
  | Just _ <- flagToken,
    Just _ <- flagTokenFile =
      Left "--token and --token-file are mutually exclusive"
  | Just token <- flagToken = Right (TokenText token)
  | Just path <- flagTokenFile = Right (TokenPath path)
  | Just token <- envToken = Right (TokenText token)
  | Just _ <- fcToken config,
    Just _ <- fcTokenFile config =
      Left "config: 'token' and 'token-file' are mutually exclusive"
  | Just token <- fcToken config = Right (TokenText token)
  | Just path <- fcTokenFile config = Right (TokenPath (T.unpack path))
  | otherwise =
      Left "a token is required (--token, --token-file, PIGEON_TOKEN, or the config file)"

{- | Resolve the server URL text with the precedence flag, then environment,
then config file, then the built-in default (CLI-010, CLI-046). The second
component labels the winning source so parse errors can name it.
-}
resolveServerText :: Maybe Text -> Maybe Text -> FileConfig -> (Text, Text)
resolveServerText flagServer envServer config =
  case flagServer <|> envServer of
    Just server -> (server, "--server")
    Nothing -> case fcServer config of
      Just server -> (server, "config 'server'")
      Nothing -> ("http://127.0.0.1:8080", "--server")
