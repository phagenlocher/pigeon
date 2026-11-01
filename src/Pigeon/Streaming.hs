{-# LANGUAGE ForeignFunctionInterface #-}

-- | Streaming helpers: gzip, counting, and @Accept-Encoding@ negotiation.
module Pigeon.Streaming (
  sourceHandleChunked,
  gzipConduit,
  parallelGzipConduit,
  parallelGzipConduitWith,
  gzipBlockSize,
  maxGzipWorkers,
  ungzipConduit,
  passThrough,
  countBytes,
  countBytesLimited,
  UploadTooLarge (..),
  AcceptEncoding (..),
  parseAcceptEncoding,
)
where

import Control.Concurrent (getNumCapabilities)
import Control.Concurrent.Async (mapConcurrently)
import Control.Monad (foldM, when)
import Control.Monad.Catch (Exception, MonadThrow, throwM)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Primitive (PrimMonad)
import Control.Monad.Trans.Resource (ResourceT)
import Data.Bits (shiftR)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as B8
import Data.ByteString.Unsafe (unsafeUseAsCStringLen)
import Data.Conduit
import Data.Conduit.Combinators (chunksOfE)
import Data.Conduit.Zlib (gzip, ungzip)
import Data.IORef
import Data.Int (Int64)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Streaming.Zlib (
  Deflate,
  Popper,
  PopperRes (..),
  WindowBits (..),
  feedDeflate,
  finishDeflate,
  fullFlushDeflate,
  initDeflate,
 )
import Data.Word (Word32, Word8)
import Foreign.C.Types (CUInt (..), CULong (..))
import Foreign.Ptr (Ptr, castPtr)
import System.IO (Handle)

import Pigeon.Types (lowerAsciiChar)

-- | Gzip compression conduit (level 6, the zlib default).
gzipConduit :: (MonadThrow m, PrimMonad m) => ConduitT ByteString ByteString m ()
gzipConduit = gzip

{- | Size of each independently compressed block, in bytes.

Block boundaries reset the deflate window, so the compression-ratio loss is
bounded by the 32 KiB window and is negligible at this size. The blocks are
stitched into one gzip stream, so the wire format stays a single member.
-}
gzipBlockSize :: Int
gzipBlockSize = 1024 * 1024

-- | Upper bound on compression workers, regardless of the capability count.
maxGzipWorkers :: Int
maxGzipWorkers = 8

{- | Block-parallel gzip: compress independent blocks concurrently and emit one
standard gzip stream.

Workers are bounded by 'maxGzipWorkers' and the capability count. With a
single capability the stream falls back to 'gzipConduit', so small files are
not delayed by block buffering. An empty input still produces a valid empty
gzip stream, matching the streaming compressor.

Memory is bounded by @2 * workers * 'gzipBlockSize'@ per active stream. An
exception in one worker cancels the others and propagates to the caller.
-}
parallelGzipConduit :: ConduitT ByteString ByteString (ResourceT IO) ()
parallelGzipConduit = do
  capabilities <- liftIO getNumCapabilities
  parallelGzipConduitWith (max 1 (min maxGzipWorkers capabilities))

{- | Block-parallel gzip with an explicit worker count.

A count of one or less uses 'gzipConduit', preserving the streaming behaviour.
A greater count compresses blocks concurrently and stitches the raw deflate
segments into a single gzip member with one header, one trailer, and a final
empty block. Callers that already bound concurrency, and tests, pass an
explicit value instead of using the capability-derived default.
-}
parallelGzipConduitWith :: Int -> ConduitT ByteString ByteString (ResourceT IO) ()
parallelGzipConduitWith workers
  | workers <= 1 = gzipConduit
  | otherwise = do
      yield gzipHeader
      chunksOfE gzipBlockSize .| compressBatches
 where
  compressBatches :: ConduitT ByteString ByteString (ResourceT IO) ()
  compressBatches = go 0 0
   where
    go :: Word32 -> Word32 -> ConduitT ByteString ByteString (ResourceT IO) ()
    go crc total = do
      blocks <- collectBlocks workers
      case blocks of
        [] -> do
          terminator <- liftIO finishEmptyBlock
          yield terminator
          yield (gzipTrailer crc total)
        _ -> do
          crc' <- liftIO (foldM crc32Chunk crc blocks)
          let total' :: Word32
              total' = total + fromIntegral (sum (map BS.length blocks))
          compressed <- liftIO (mapConcurrently compressBlockRaw blocks)
          mapM_ yield compressed
          total' `seq` go crc' total'

  collectBlocks :: Int -> ConduitT ByteString ByteString (ResourceT IO) [ByteString]
  collectBlocks 0 = pure []
  collectBlocks n =
    await >>= \case
      Nothing -> pure []
      Just block -> (block :) <$> collectBlocks (n - 1)

{- | Update a CRC-32 with one chunk.

zlib's @crc32@ starts from zero and performs its own pre- and post-conditioning,
so the result is the standard IEEE CRC-32 used by gzip. A zero initial value
therefore produces the correct gzip trailer value.
-}
crc32Chunk :: Word32 -> ByteString -> IO Word32
crc32Chunk crc chunk =
  unsafeUseAsCStringLen chunk $ \(pointer, byteCount) ->
    fromIntegral
      <$> c_crc32
        (fromIntegral crc)
        (castPtr pointer)
        (fromIntegral byteCount)

-- | zlib's incremental CRC-32, used to build the single gzip trailer.
foreign import ccall unsafe "crc32"
  c_crc32 :: CULong -> Ptr Word8 -> CUInt -> IO CULong

-- | The fixed 10-byte gzip header: no name, no modification time, unknown OS.
gzipHeader :: ByteString
gzipHeader = BS.pack [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff]

-- | Encode a 32-bit word little-endian, as the gzip trailer requires.
word32LE :: Word32 -> ByteString
word32LE word =
  BS.pack
    [ fromIntegral word,
      fromIntegral (word `shiftR` 8),
      fromIntegral (word `shiftR` 16),
      fromIntegral (word `shiftR` 24)
    ]

-- | The 8-byte gzip trailer: CRC-32 and ISIZE, both little-endian.
gzipTrailer :: Word32 -> Word32 -> ByteString
gzipTrailer crc size = word32LE crc <> word32LE size

-- | Drain a zlib popper into a list of chunks, propagating zlib errors.
drainPopper :: Popper -> IO [ByteString]
drainPopper popper = go
 where
  go :: IO [ByteString]
  go =
    popper >>= \case
      PRDone -> pure []
      PRNext chunk -> (chunk :) <$> go
      PRError err -> throwM err

{- | Compress one block as a raw deflate segment ending with a full flush.

@Z_FULL_FLUSH@ resets the dictionary and ends on a byte boundary, so segments
compressed by different workers can be concatenated into one deflate stream.
-}
compressBlockRaw :: ByteString -> IO ByteString
compressBlockRaw block = do
  deflater <- newDeflater
  fed <- drainPopper =<< feedDeflate deflater block
  flushed <- drainPopper (fullFlushDeflate deflater)
  pure (BS.concat (fed <> flushed))

-- | The empty final deflate block that terminates a stitched stream.
finishEmptyBlock :: IO ByteString
finishEmptyBlock = do
  deflater <- newDeflater
  BS.concat <$> drainPopper (finishDeflate deflater)

-- | A raw deflate stream (no zlib or gzip wrapper) at the default level.
newDeflater :: IO Deflate
newDeflater = initDeflate 6 (WindowBits (-15))

-- | Streaming gzip decompression of one member.
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
