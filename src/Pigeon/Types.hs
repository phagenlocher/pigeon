-- | Shared domain types, identifiers, JSON instances and header helpers.
module Pigeon.Types (
  -- * File identifiers
  FileId (..),
  isValidFileId,
  mkFileId,
  encodeFileId,
  generateFileId,
  fileIdPattern,

  -- * API-facing types
  FileInfo (..),
  Health (..),
  ApiError (..),
  ApiErrorEnvelope (..),

  -- * Storage-facing types
  StoredFile (..),

  -- * Secrets
  Secret (..),
  mkSecret,
  secretText,

  -- * Time
  formatTimestamp,
  parseTimestamp,
  epochToUtc,
  utcToEpoch,
  nowUtc,

  -- * Sanitisation and headers
  sanitizeFilename,
  sanitizeContentType,
  contentDisposition,
  asciiFallbackFilename,
  percentEncodeRfc5987,

  -- * Version
  pigeonVersion,
) where

import Crypto.Random (getRandomBytes)
import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as B8
import Data.Char (isAscii, isAsciiLower, isAsciiUpper, isControl, isDigit, ord)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (
  UTCTime,
  defaultTimeLocale,
  formatTime,
  getCurrentTime,
  parseTimeM,
 )
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Data.ULID.Base32 qualified as Base32
import Data.Word (Word8)
import Servant.API (FromHttpApiData (..), ToHttpApiData (..))
import Text.Printf (printf)

-- | Pigeon's package version, reported by @\/healthz@ and @--version@.
pigeonVersion :: Text
pigeonVersion = "0.1.0.0"

{- | An opaque file identifier.

The parser is deliberately lenient so the HTTP layer can distinguish a
malformed API id (@400@) from a malformed browser id (@404@). Use
'isValidFileId' before turning an id into a filesystem path.
-}
newtype FileId = FileId {unFileId :: Text}
  deriving (Eq, Ord, Show)

-- | The lowercase Crockford base32 alphabet, excluding @i@, @l@, @o@, @u@.
fileIdAlphabet :: Text
fileIdAlphabet = "0123456789abcdefghjkmnpqrstvwxyz"

-- | Human-readable description of a valid id, used in error messages.
fileIdPattern :: Text
fileIdPattern = "^[0-9a-hjkmnp-tv-z]{16}$"

-- | Check that an id is sixteen Crockford base32 characters.
isValidFileId :: FileId -> Bool
isValidFileId (FileId t) = T.length t == 16 && T.all (`T.elem` fileIdAlphabet) t

-- | Smart constructor that rejects invalid ids.
mkFileId :: Text -> Either Text FileId
mkFileId t
  | isValidFileId (FileId t) = Right (FileId t)
  | otherwise = Left ("file id must match " <> fileIdPattern)

{- | Encode ten raw bytes as a sixteen-character Crockford base32 id.

The digits come from 'Base32.encode' in the @ulid@ package; we lowercase
them because 'fileIdAlphabet' is canonical lowercase.
-}
encodeFileId :: ByteString -> FileId
encodeFileId bytes =
  FileId (T.toLower (Base32.encode 16 (BS.foldl' step (0 :: Integer) bytes)))
 where
  step :: Integer -> Word8 -> Integer
  step acc w = acc * 256 + fromIntegral w

-- | Generate a fresh id from ten cryptographically random bytes.
generateFileId :: IO FileId
generateFileId = encodeFileId <$> getRandomBytes 10

instance ToJSON FileId where
  toJSON = String . unFileId

instance FromJSON FileId where
  parseJSON = withText "FileId" (pure . FileId)

instance ToHttpApiData FileId where
  toUrlPiece = unFileId

-- | Lenient: see the note on 'FileId'.
instance FromHttpApiData FileId where
  parseUrlPiece = Right . FileId

-- | Public metadata for a stored file.
data FileInfo = FileInfo
  { fiId :: FileId,
    fiFilename :: Text,
    fiSize :: Int64,
    fiContentType :: Text,
    fiCreatedAt :: UTCTime,
    fiExpiresAt :: UTCTime,
    fiHasPassword :: Bool,
    fiUrl :: Text
  }
  deriving (Eq, Show)

-- | Health check response.
data Health = Health
  { healthStatus :: Text,
    healthVersion :: Text
  }
  deriving (Eq, Show)

-- | Standard API error payload.
data ApiError = ApiError
  { aeCode :: Text,
    aeMessage :: Text
  }
  deriving (Eq, Show)

newtype ApiErrorEnvelope = ApiErrorEnvelope {unApiErrorEnvelope :: ApiError}
  deriving (Eq, Show)

-- | Internal stored-file record. Never serialized to clients.
data StoredFile = StoredFile
  { sfId :: FileId,
    sfFilename :: Text,
    sfContentType :: Text,
    sfSize :: Int64,
    sfStoredSize :: Int64,
    sfPasswordHash :: Maybe Text,
    sfCreatedAt :: UTCTime,
    sfExpiresAt :: UTCTime
  }
  deriving (Eq, Show)

instance ToJSON FileInfo where
  toJSON FileInfo{..} =
    object
      [ "id" .= fiId,
        "filename" .= fiFilename,
        "size" .= fiSize,
        "contentType" .= fiContentType,
        "createdAt" .= formatTimestamp fiCreatedAt,
        "expiresAt" .= formatTimestamp fiExpiresAt,
        "hasPassword" .= fiHasPassword,
        "url" .= fiUrl
      ]

instance FromJSON FileInfo where
  parseJSON = withObject "FileInfo" $ \o -> do
    createdAtText <- o .: "createdAt"
    expiresAtText <- o .: "expiresAt"
    createdAt <- parseTimestampField "createdAt" createdAtText
    expiresAt <- parseTimestampField "expiresAt" expiresAtText
    FileInfo
      <$> o .: "id"
      <*> o .: "filename"
      <*> o .: "size"
      <*> o .: "contentType"
      <*> pure createdAt
      <*> pure expiresAt
      <*> o .: "hasPassword"
      <*> o .: "url"
   where
    parseTimestampField :: Text -> Text -> Parser UTCTime
    parseTimestampField name value =
      maybe (fail ("invalid " <> T.unpack name <> " timestamp")) pure (parseTimestamp value)

instance ToJSON Health where
  toJSON Health{..} =
    object ["status" .= healthStatus, "version" .= healthVersion]

instance FromJSON Health where
  parseJSON = withObject "Health" $ \o ->
    Health <$> o .: "status" <*> o .: "version"

instance ToJSON ApiError where
  toJSON ApiError{..} = object ["code" .= aeCode, "message" .= aeMessage]

instance FromJSON ApiError where
  parseJSON = withObject "ApiError" $ \o ->
    ApiError <$> o .: "code" <*> o .: "message"

instance ToJSON ApiErrorEnvelope where
  toJSON (ApiErrorEnvelope e) = object ["error" .= e]

instance FromJSON ApiErrorEnvelope where
  parseJSON = withObject "ApiErrorEnvelope" $ \o ->
    ApiErrorEnvelope <$> o .: "error"

-- | A value that must never leak through 'Show'.
newtype Secret = Secret {unSecret :: Text}
  deriving (Eq)

instance Show Secret where
  show _ = "<redacted>"

-- | Wrap a value as a secret.
mkSecret :: Text -> Secret
mkSecret = Secret

-- | Extract the underlying text. Callers must not log the result.
secretText :: Secret -> Text
secretText = unSecret

-- | RFC3339 UTC with second precision and a literal @Z@.
formatTimestamp :: UTCTime -> Text
formatTimestamp = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

-- | Parse the format produced by 'formatTimestamp'.
parseTimestamp :: Text -> Maybe UTCTime
parseTimestamp =
  parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" . T.unpack

epochToUtc :: Int64 -> UTCTime
epochToUtc = posixSecondsToUTCTime . fromIntegral

utcToEpoch :: UTCTime -> Int64
utcToEpoch = floor . utcTimeToPOSIXSeconds

nowUtc :: IO UTCTime
nowUtc = getCurrentTime

{- | Make a user-supplied display filename safe.

Path separators and control characters become @_@, leading and trailing
spaces are trimmed, dot-only names become @file@, and the result is
truncated to at most 255 UTF-8 bytes at a character boundary.
-}
sanitizeFilename :: Text -> Text
sanitizeFilename input =
  let replaced = T.map replaceChar input
      trimmed = T.strip replaced
      truncated = truncateUtf8 255 trimmed
   in if T.null truncated || T.all (== '.') truncated then "file" else truncated
 where
  replaceChar :: Char -> Char
  replaceChar c
    | c == '/' || c == '\\' || isControl c = '_'
    | otherwise = c

-- | Truncate text so its UTF-8 encoding is at most @limit@ bytes.
truncateUtf8 :: Int -> Text -> Text
truncateUtf8 limit t = T.pack (go 0 (T.unpack t))
 where
  go :: Int -> String -> String
  go _ [] = []
  go used (c : cs)
    | used + utf8Length c > limit = []
    | otherwise = c : go (used + utf8Length c) cs

  utf8Length :: Char -> Int
  utf8Length c
    | ord c <= 0x7f = 1
    | ord c <= 0x7ff = 2
    | ord c <= 0xffff = 3
    | otherwise = 4

-- | Sanitize a content type. Invalid values become @application/octet-stream@.
sanitizeContentType :: Text -> Text
sanitizeContentType t
  | T.null t = "application/octet-stream"
  | T.length t > 255 = "application/octet-stream"
  | not (T.all valid t) = "application/octet-stream"
  | otherwise = t
 where
  valid :: Char -> Bool
  valid c = isAscii c && not (isControl c) && c /= '\r' && c /= '\n'

-- | Build the value of a @Content-Disposition: attachment@ header.
contentDisposition :: Text -> ByteString
contentDisposition filename =
  B8.pack
    ( "attachment; filename=\""
        <> T.unpack (asciiFallbackFilename filename)
        <> "\"; filename*=UTF-8''"
        <> T.unpack (percentEncodeRfc5987 filename)
    )

-- | ASCII fallback used inside the quoted @filename@ parameter.
asciiFallbackFilename :: Text -> Text
asciiFallbackFilename = T.map replace
 where
  replace :: Char -> Char
  replace c
    | isAscii c && c /= '"' && c /= '\\' && not (isControl c) = c
    | otherwise = '_'

-- | RFC 5987 percent-encoding of UTF-8 text.
percentEncodeRfc5987 :: Text -> Text
percentEncodeRfc5987 = T.concatMap encodeChar
 where
  encodeChar :: Char -> Text
  encodeChar c
    | isAttrChar c = T.singleton c
    | otherwise =
        T.concat (map encodeByte (BS.unpack (TE.encodeUtf8 (T.singleton c))))

  encodeByte :: Word8 -> Text
  encodeByte w = T.pack (printf "%%%02X" w)

  isAttrChar :: Char -> Bool
  isAttrChar c =
    isAsciiUpper c
      || isAsciiLower c
      || isDigit c
      || c `elem` ("!#$&+-.^_`|~" :: String)
