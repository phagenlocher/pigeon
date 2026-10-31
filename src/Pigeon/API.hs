-- | The shared Servant contract. Both executables derive from this type.
module Pigeon.API (
  PigeonAPI,
  WebAPI,
  FullAPI,
  UploadBody,
)
where

import Control.Monad.Trans.Resource (ResourceT)
import Data.ByteString (ByteString)
import Data.Conduit (ConduitT)
import Data.Int (Int64)
import Data.Text (Text)
import Pigeon.Types (FileId, FileInfo, Health)
import Servant
import Servant.Conduit ()

-- | A streaming upload body. Nothing in this type permits whole-file buffering.
type UploadBody = ConduitT () ByteString (ResourceT IO) ()

-- | The authenticated metadata API.
type PigeonAPI =
  ( "api"
      :> "v1"
      :> "files"
      :> Header "Authorization" Text
      :> QueryParam "filename" Text
      :> QueryParam "expires_in" Int64
      :> QueryParam "content_type" Text
      :> Header "Content-Encoding" Text
      :> Header "X-Pigeon-Password" Text
      :> StreamBody NoFraming OctetStream UploadBody
      :> PostCreated '[JSON] FileInfo
  )
    :<|> ( "api"
             :> "v1"
             :> "files"
             :> Header "Authorization" Text
             :> Get '[JSON] [FileInfo]
         )
    :<|> ( "api"
             :> "v1"
             :> "files"
             :> Capture "id" FileId
             :> Header "Authorization" Text
             :> DeleteNoContent
         )
    :<|> ( "healthz"
             :> Get '[JSON] Health
         )

{- | Public browser routes. The file route is raw so one handler can return
either HTML or a streamed download.
-}
type WebAPI =
  "f" :> Capture "id" FileId :> Raw
    :<|> "robots.txt" :> Get '[PlainText] Text

type FullAPI = PigeonAPI :<|> WebAPI
