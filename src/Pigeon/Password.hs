-- | PBKDF2 password hashing, a thin wrapper over "Data.Password.PBKDF2".
module Pigeon.Password (
  StoredPasswordHash (..),
  hashPassword,
  hashPasswordWithIterationsAndSalt,
  verifyPassword,
  parseStoredPasswordHash,
  validatePassword,
) where

import Control.Monad.IO.Class (MonadIO)
import Data.ByteString qualified as BS
import Data.Password.PBKDF2 (
  PBKDF2Algorithm (..),
  PBKDF2Params (..),
  PasswordCheck (..),
  PasswordHash (..),
  Salt (..),
  checkPassword,
  defaultParams,
  extractParams,
  hashPasswordWithParams,
  hashPasswordWithSalt,
  mkPassword,
 )
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)

-- | The opaque, self-describing hash text stored in SQLite.
newtype StoredPasswordHash = StoredPasswordHash
  { unStoredPasswordHash :: Text
  }
  deriving (Eq, Show)

{- | Reject an empty password or one longer than 1024 UTF-8 bytes. The
password itself is never included in the error.
-}
validatePassword :: Text -> Either Text ()
validatePassword password
  | BS.null bytes = Left "password must not be empty"
  | BS.length bytes > 1024 = Left "password must be at most 1024 UTF-8 bytes"
  | otherwise = Right ()
 where
  bytes = encodeUtf8 password

-- | Build PBKDF2 parameters for Pigeon v1.
pigeonParams :: Int -> PBKDF2Params
pigeonParams iterations =
  defaultParams
    { pbkdf2Salt = 16,
      pbkdf2Algorithm = PBKDF2_SHA512,
      pbkdf2Iterations = fromIntegral iterations,
      pbkdf2OutputLength = 64
    }

-- | Hash a password with a fresh random salt.
hashPassword :: (MonadIO m) => Int -> Text -> m StoredPasswordHash
hashPassword iterations password = do
  hashed <- hashPasswordWithParams (pigeonParams iterations) (mkPassword password)
  pure (StoredPasswordHash (unPasswordHash hashed))

{- | Deterministic helper for tests and fixtures. Production code must use
'hashPassword', which generates a random salt.
-}
hashPasswordWithIterationsAndSalt :: Int -> Text -> Text -> StoredPasswordHash
hashPasswordWithIterationsAndSalt iterations salt password =
  StoredPasswordHash . unPasswordHash $
    hashPasswordWithSalt
      (pigeonParams iterations)
      (Salt (encodeUtf8 salt))
      (mkPassword password)

{- | Verify a submitted password against a stored hash.

The caller must have validated the stored value with
'parseStoredPasswordHash' first.
-}
verifyPassword :: Text -> StoredPasswordHash -> Bool
verifyPassword submitted (StoredPasswordHash stored) =
  checkPassword (mkPassword submitted) (PasswordHash stored) == PasswordCheckSuccess

-- | Validate the structure of a stored hash and return it unchanged.
parseStoredPasswordHash :: Text -> Either Text StoredPasswordHash
parseStoredPasswordHash stored
  | length fields /= 4 = Left "stored password hash must have four fields"
  | algorithm /= "sha512" = Left "stored password hash must use sha512"
  | otherwise = case extractParams (PasswordHash stored) of
      Nothing -> Left "stored password hash is malformed"
      Just params
        | pbkdf2Algorithm params /= PBKDF2_SHA512 -> Left "stored password hash must use sha512"
        | pbkdf2Salt params /= 16 -> Left "stored password hash salt must be 16 bytes"
        | pbkdf2OutputLength params /= 64 -> Left "stored password hash key must be 64 bytes"
        | pbkdf2Iterations params > 100000000 -> Left "stored password hash iteration count is too high"
        | otherwise -> Right (StoredPasswordHash stored)
 where
  fields = T.splitOn ":" stored
  algorithm = case fields of
    (a : _) -> a
    [] -> ""
