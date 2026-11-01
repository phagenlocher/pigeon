-- | Bearer-token parsing and constant-time comparison.
module Pigeon.Server.Auth (
  checkBearer,
  AuthFailure (..),
) where

import Data.ByteArray (constEq)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)

import Pigeon.Types (Secret (..))

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

-- | Compare the presented token with the configured one in constant time.
checkBearer :: Secret -> Maybe Text -> Either AuthFailure ()
checkBearer secret header = do
  presented <- extractBearer header
  if constEq (encodeUtf8 presented) (encodeUtf8 (unSecret secret))
    then Right ()
    else Left WrongToken
