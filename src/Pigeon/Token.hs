{- | User-token formatting and hashing.

A user token is @pgn_<owner-id>_<secret>@. The owner id is public and lets the
server look a token up with one indexed query; the secret half is 32 random
bytes encoded as unpadded base64url. Only a SHA-256 digest of the complete
token is stored.
-}
module Pigeon.Token (
  ParsedToken (..),
  renderToken,
  parseToken,
  hashToken,
  generateUserToken,
  tokenPrefix,
  tokenSecretBytes,
) where

import Control.Monad (guard)
import Crypto.Hash (SHA256 (..), hashWith)
import Crypto.Random (getRandomBytes)
import Data.Base64.Types (extractBase64)
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64.URL qualified as B64URL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)

import Pigeon.Types (OwnerId (..))

-- | A parsed user token before hash verification.
data ParsedToken = ParsedToken
  { ptOwner :: OwnerId,
    ptHash :: ByteString
  }
  deriving (Eq, Show)

-- | The literal prefix that distinguishes user tokens from the admin token.
tokenPrefix :: Text
tokenPrefix = "pgn_"

-- | Number of random bytes in a user-token secret.
tokenSecretBytes :: Int
tokenSecretBytes = 32

{- | Render a token from its owner id and secret bytes. The caller must pass
exactly 'tokenSecretBytes' bytes.
-}
renderToken :: OwnerId -> ByteString -> Text
renderToken (OwnerId owner) secret =
  tokenPrefix <> owner <> "_" <> extractBase64 (B64URL.encodeBase64Unpadded secret)

{- | Parse a presented bearer token. Returns the owner id and the SHA-256
digest of the whole token, or 'Nothing' when the shape is invalid.
-}
parseToken :: Text -> Maybe ParsedToken
parseToken raw = do
  rest <- T.stripPrefix tokenPrefix raw
  let (ownerText, secretPart) = T.breakOn "_" rest
  encoded <- T.stripPrefix "_" secretPart
  guard (not (T.null encoded))
  guard (T.length ownerText == 16 && T.all (`T.elem` crockfordAlphabet) ownerText)
  secret <- either (const Nothing) Just (B64URL.decodeBase64UnpaddedUntyped (encodeUtf8 encoded))
  if
    | BS.length secret == tokenSecretBytes,
      extractBase64 (B64URL.encodeBase64Unpadded secret) == encoded ->
        Just (ParsedToken (OwnerId ownerText) (hashToken raw))
    | otherwise -> Nothing

-- | SHA-256 of the complete token string, as stored in SQLite.
hashToken :: Text -> ByteString
hashToken = convert . hashWith SHA256 . encodeUtf8

-- | Generate a fresh token and its stored digest.
generateUserToken :: OwnerId -> IO (Text, ByteString)
generateUserToken owner = do
  secret <- getRandomBytes tokenSecretBytes
  let raw = renderToken owner secret
  pure (raw, hashToken raw)

-- | Lowercase Crockford base32, matching file and owner ids.
crockfordAlphabet :: Text
crockfordAlphabet = "0123456789abcdefghjkmnpqrstvwxyz"
