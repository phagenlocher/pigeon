-- | Bearer-token parsing, admin comparison, and user-token resolution.
module Pigeon.Server.Auth (
  PigeonUser (..),
  AuthFailure (..),
  authenticate,
  extractBearer,
) where

import Data.ByteArray (constEq)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time (UTCTime)

import Pigeon.Server.Db (Db, lookupToken)
import Pigeon.Token (ParsedToken (..), parseToken)
import Pigeon.Types (OwnerId, Secret (..), StoredToken (..))

-- | The authenticated caller.
data PigeonUser
  = -- | The configured admin token.
    PigeonAdmin
  | -- | A live user token, identified by its owner id.
    PigeonTokenUser OwnerId
  deriving (Eq, Show)

-- | Why authentication failed.
data AuthFailure
  = MissingAuthorization
  | MalformedAuthorization
  | WrongToken
  deriving (Eq, Show)

{- | Extract the token from an @Authorization@ header, accepting a
case-insensitive scheme and exactly one space.
-}
extractBearer :: Maybe Text -> Either AuthFailure Text
extractBearer Nothing = Left MissingAuthorization
extractBearer (Just header) =
  case T.breakOn " " header of
    (scheme, rest)
      | T.toLower scheme /= "bearer" -> Left MalformedAuthorization
      | T.length rest < 2 -> Left MalformedAuthorization
      | otherwise ->
          let token = T.drop 1 rest
           in if T.null token || T.any (== ' ') token
                then Left MalformedAuthorization
                else Right token

{- | Resolve a presented bearer token.

The admin token is compared first and directly. A user token is looked up by
its public owner id, rejected when expired, and then verified by comparing the
SHA-256 digest of the complete token. Every failure maps to the same @401@
response at the HTTP layer.
-}
authenticate ::
  Secret ->
  -- | Metadata database used for user-token lookup.
  Db ->
  UTCTime ->
  Maybe Text ->
  IO (Either AuthFailure PigeonUser)
authenticate adminToken db now header =
  case extractBearer header of
    Left failure -> pure (Left failure)
    Right presented
      | constEq (encodeUtf8 presented) (encodeUtf8 (unSecret adminToken)) ->
          pure (Right PigeonAdmin)
      | otherwise -> case parseToken presented of
          Nothing -> pure (Left WrongToken)
          Just ParsedToken{ptOwner, ptHash} -> do
            stored <- lookupToken db ptOwner
            pure $ case stored of
              Nothing -> Left WrongToken
              Just token
                | maybe False (<= now) (stExpiresAt token) -> Left WrongToken
                | constEq ptHash (stHash token) -> Right (PigeonTokenUser ptOwner)
                | otherwise -> Left WrongToken
