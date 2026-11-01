-- | Shared option, environment, and validation helpers.
module Pigeon.Config (
  runParser,
  lookupEnvText,
  normalizeBaseUrl,
  parseBaseUrlText,
  requireToken,
  tokenFromSources,
  exitWithText,

  -- * CLI helpers
  parsePositiveInt,
  parseByteCount,
) where

import Control.Exception.Safe (IOException, try)
import Data.Char (isAscii)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Text.Read qualified as TR
import Options.Applicative
import Servant.Client.Core (
  BaseUrl (..),
  parseBaseUrl,
  showBaseUrl,
 )
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (..), exitSuccess, exitWith)
import System.IO (hPutStrLn, stderr)

import Pigeon.Types (Secret, mkSecret)

{- | Run an optparse parser, exiting with code @2@ on a usage error and @0@ for
help/version completions.
-}
runParser :: String -> ParserInfo a -> IO a
runParser program parserInfo = do
  args <- getArgs
  case execParserPure defaultPrefs parserInfo args of
    Success parsed -> pure parsed
    Failure failure -> do
      let (message, _) = renderFailure failure program
      hPutStrLn stderr message
      exitWith (ExitFailure 2)
    CompletionInvoked completion -> do
      message <- execCompletion completion program
      putStr message
      exitSuccess

-- | Read an environment variable as text, treating an empty value as absent.
lookupEnvText :: String -> IO (Maybe Text)
lookupEnvText name = do
  envValue <- lookupEnv name
  pure $ case envValue of
    Nothing -> Nothing
    Just raw ->
      let envText = T.pack raw
       in if T.null (T.strip envText) then Nothing else Just envText

-- | Read the first line of a token file, stripping trailing CR/LF.
readTokenFile :: FilePath -> IO (Either Text Text)
readTokenFile path = do
  result <- try (TIO.readFile path) :: IO (Either IOException Text)
  pure $ case result of
    Left _ -> Left "token file could not be read"
    Right contents ->
      let firstLine = T.takeWhile (\c -> c /= '\n' && c /= '\r') contents
       in if T.null firstLine
            then Left "token file is empty"
            else Right firstLine

-- | A token is 16–512 printable ASCII characters with no whitespace.
validateToken :: Text -> Either Text Text
validateToken token
  | T.length token < 16 = Left "token must be at least 16 characters"
  | T.length token > 512 = Left "token must be at most 512 characters"
  | not (T.all printable token) = Left "token must contain only printable ASCII characters"
  | otherwise = Right token
 where
  printable :: Char -> Bool
  printable c = isAscii c && c >= '!' && c <= '~'

{- | Validate the mutually exclusive command-line token sources and apply the
documented precedence: flag, then file, then environment.
-}
tokenFromSources :: Maybe Text -> Maybe FilePath -> Maybe Text -> IO (Either Text Secret)
tokenFromSources flagToken tokenFile envToken =
  case (flagToken, tokenFile) of
    (Just _, Just _) -> pure (Left "--token and --token-file are mutually exclusive")
    (Just token, Nothing) -> pure (mkSecret <$> validateToken token)
    (Nothing, Just path) -> do
      result <- readTokenFile path
      pure $ do
        raw <- result
        mkSecret <$> validateToken raw
    (Nothing, Nothing) ->
      pure $ case envToken of
        Nothing -> Left "a token is required (--token, --token-file, or PIGEON_TOKEN)"
        Just token -> mkSecret <$> validateToken token

-- | Fail with a usage-style message when no token is available.
requireToken :: Either Text Secret -> IO Secret
requireToken = either (exitWithText 2 . ("error: " <>)) pure

-- | Write an error line to stderr and exit with the given status code.
exitWithText :: Int -> Text -> IO a
exitWithText code message = do
  TIO.hPutStrLn stderr message
  exitWith (ExitFailure code)

{- | Parse an absolute @http@ or @https@ base URL with no path, query, or
fragment. A single trailing slash is accepted and removed.
-}
normalizeBaseUrl :: Text -> Either Text Text
normalizeBaseUrl raw
  | not (hasScheme raw) = Left "server URL must start with http:// or https://"
  | T.any (`elem` ("?#" :: String)) raw = Left "server URL must not contain a query or fragment"
  | otherwise = case parseBaseUrlText raw of
      Left err -> Left err
      Right baseUrl
        | not (null (baseUrlPath baseUrl)) ->
            Left "server URL must not contain a path"
        | otherwise -> Right (T.pack (showBaseUrl baseUrl))
 where
  hasScheme :: Text -> Bool
  hasScheme t = "http://" `T.isPrefixOf` t || "https://" `T.isPrefixOf` t

-- | Wrapper around servant-client's parser for a friendlier error.
parseBaseUrlText :: Text -> Either Text BaseUrl
parseBaseUrlText raw =
  case parseBaseUrl (T.unpack raw) of
    Nothing -> Left "invalid server URL"
    Just baseUrl -> Right baseUrl

-- | Parse a strictly positive integer.
parsePositiveInt :: Text -> Either Text Int
parsePositiveInt raw = case parseDecimal raw of
  Just n | n > 0 -> Right n
  _ -> Left "expected a positive integer"

-- | Parse a non-negative byte count.
parseByteCount :: Text -> Either Text Int64
parseByteCount raw = case parseDecimal raw of
  Just n | n >= 0 -> Right n
  _ -> Left "expected a non-negative integer"

{- | Read a decimal integer that consumes its whole input, ignoring surrounding
whitespace.
-}
parseDecimal :: (Integral a) => Text -> Maybe a
parseDecimal raw =
  case TR.decimal (T.strip raw) of
    Right (n, rest) | T.null rest -> Just n
    _ -> Nothing
