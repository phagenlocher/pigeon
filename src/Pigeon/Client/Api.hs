-- | HTTP manager setup and Servant client calls.
module Pigeon.Client.Api (
  ApiClient (..),
  ClientApi (..),
  mkClientApi,
  runApi,
) where

import Data.Default (def)
import Data.Int (Int64)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Network.Connection (TLSSettings (..))
import Network.HTTP.Client (
  ManagerSettings (..),
  Request (..),
  ResponseTimeout,
  newManager,
  responseTimeoutMicro,
 )
import Network.HTTP.Client.TLS (mkManagerSettings, tlsManagerSettings)
import Network.TLS (Supported)
import Servant.API (NoContent, (:<|>) (..))
import Servant.Client (
  ClientEnv,
  ClientError,
  ClientM,
  client,
  mkClientEnv,
  runClientM,
 )

import Pigeon.API (PigeonAPI, UploadBody)
import Pigeon.Client.Config (ClientConfig (..))
import Pigeon.Types (FileId, FileInfo)

-- | The generated client functions, named for readability.
data ApiClient = ApiClient
  { acUpload ::
      Maybe Text ->
      Maybe Text ->
      Maybe Int64 ->
      Maybe Text ->
      Maybe Text ->
      Maybe Text ->
      UploadBody ->
      ClientM FileInfo,
    acList :: Maybe Text -> ClientM [FileInfo],
    acDelete :: FileId -> Maybe Text -> ClientM NoContent
  }

-- | A manager and environment shared for the process lifetime.
data ClientApi = ClientApi
  { caEnv :: ClientEnv,
    caApi :: ApiClient
  }

-- | Create the HTTP manager and Servant client environment.
mkClientApi :: ClientConfig -> IO ClientApi
mkClientApi cfg = do
  let timeout :: ResponseTimeout
      timeout =
        responseTimeoutMicro
          (fromIntegral (max 1 (ccTimeoutSeconds cfg)) * 1000000)
      baseSettings :: ManagerSettings
      baseSettings
        | ccInsecure cfg =
            let supported = def :: Supported
             in mkManagerSettings (TLSSettingsSimple True False False supported) Nothing
        | otherwise = tlsManagerSettings
      settings :: ManagerSettings
      settings =
        baseSettings
          { managerResponseTimeout = timeout,
            managerModifyRequest = \request -> pure request{redirectCount = 0}
          }
  manager <- newManager settings
  let (upload :<|> list :<|> delete :<|> _health) = client (Proxy :: Proxy PigeonAPI)
  pure
    ClientApi
      { caEnv = mkClientEnv manager (ccServer cfg),
        caApi =
          ApiClient
            { acUpload = upload,
              acList = list,
              acDelete = delete
            }
      }

-- | Run one Servant call.
runApi :: ClientApi -> ClientM a -> IO (Either ClientError a)
runApi clientApi action = runClientM action (caEnv clientApi)
