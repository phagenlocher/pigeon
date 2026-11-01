-- | Streaming helpers: gzip, counting, and @Accept-Encoding@ negotiation.
module Pigeon.Streaming (
  sourceHandleChunked,
  gzipConduit,
  ungzipConduit,
  passThrough,
  countBytes,
  countBytesLimited,
  UploadTooLarge (..),
  AcceptEncoding (..),
  parseAcceptEncoding,
)
where

import Control.Monad (when)
import Control.Monad.Catch (Exception, MonadThrow, throwM)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Primitive (PrimMonad)
import Control.Monad.Trans.Resource (ResourceT)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as B8
import Data.Conduit
import Data.Conduit.Zlib (gzip, ungzip)
import Data.IORef
import Data.Int (Int64)
import Data.Maybe (fromMaybe, mapMaybe)
import System.IO (Handle)

import Pigeon.Types (lowerAsciiChar)

-- | Gzip compression conduit (level 6, the zlib default).
gzipConduit :: (MonadThrow m, PrimMonad m) => ConduitT ByteString ByteString m ()
gzipConduit = gzip

-- | Streaming gzip decompression.
ungzipConduit :: (MonadThrow m, PrimMonad m) => ConduitT ByteString ByteString m ()
ungzipConduit = ungzip

-- | Pass bytes through unchanged.
passThrough :: (Monad m) => ConduitT ByteString ByteString m ()
passThrough = awaitForever yield

{- | Stream a handle in chunks of up to @size@ bytes.

Short reads are passed through as they arrive, and an empty read ends the
stream. A non-positive @size@ is treated as one byte.
-}
sourceHandleChunked :: Int -> Handle -> ConduitT i ByteString (ResourceT IO) ()
sourceHandleChunked size handle = go
 where
  chunkSize :: Int
  chunkSize = max 1 size
  go :: ConduitT i ByteString (ResourceT IO) ()
  go = do
    chunk <- liftIO (BS.hGetSome handle chunkSize)
    if BS.null chunk
      then pure ()
      else yield chunk >> go

-- | Increment a counter for each chunk and pass the chunk through.
countBytes :: IORef Int64 -> ConduitT ByteString ByteString (ResourceT IO) ()
countBytes ref = awaitForever $ \chunk -> do
  liftIO $ modifyIORef' ref (+ fromIntegral (B8.length chunk))
  yield chunk

-- | Thrown when an upload exceeds the configured size limit.
newtype UploadTooLarge = UploadTooLarge Int64
  deriving (Show)

instance Exception UploadTooLarge

{- | Count bytes and abort as soon as the count exceeds @limit@. A limit of
zero or less means unlimited.
-}
countBytesLimited :: Int64 -> IORef Int64 -> ConduitT ByteString ByteString (ResourceT IO) ()
countBytesLimited limit ref = awaitForever $ \chunk -> do
  total <- liftIO $ do
    modifyIORef' ref (+ fromIntegral (B8.length chunk))
    readIORef ref
  when (limit > 0 && total > limit) $ throwM (UploadTooLarge total)
  yield chunk

-- | What the client is willing to receive.
data AcceptEncoding
  = AcceptGzip
  | AcceptIdentity
  | NotAcceptable
  deriving (Eq, Show)

{- | Parse an @Accept-Encoding@ header, including q-values and the @*@
wildcard. Malformed entries are ignored. An absent or empty header means
identity. An entry without a @q@ parameter counts as @1@, and a malformed
@q@ drops that entry.
-}
parseAcceptEncoding :: ByteString -> AcceptEncoding
parseAcceptEncoding raw
  | B8.all (`elem` (" \t" :: String)) raw = AcceptIdentity
  | otherwise =
      let entries = mapMaybe parseEntry (B8.split ',' raw)
          lookupQ :: ByteString -> Maybe Double
          lookupQ name = lookup name entries
          gzipQ = fromMaybe 0 (lookupQ "gzip" `orElse` lookupQ "*")
          identityQ = fromMaybe 1 (lookupQ "identity" `orElse` lookupQ "*")
       in if gzipQ > 0
            then AcceptGzip
            else
              if identityQ > 0
                then AcceptIdentity
                else NotAcceptable
 where
  orElse :: Maybe a -> Maybe a -> Maybe a
  orElse (Just x) _ = Just x
  orElse Nothing y = y

  parseEntry :: ByteString -> Maybe (ByteString, Double)
  parseEntry part =
    case B8.split ';' (B8.map lowerAsciiChar part) of
      [] -> Nothing
      (name : params) ->
        let trimmedName = B8.strip name
         in if B8.null trimmedName
              then Nothing
              else (,) trimmedName <$> parseQ params

  parseQ :: [ByteString] -> Maybe Double
  parseQ params =
    case [v | p <- params, let (k, v) = B8.break (== '=') (B8.strip p), k == "q"] of
      [] -> Just 1
      (v : _) ->
        let value = B8.unpack (B8.dropWhile (== '=') v)
         in case reads value :: [(Double, String)] of
              [(q, "")] | q >= 0 && q <= 1 -> Just q
              _ -> Nothing
