{-# LANGUAGE ForeignFunctionInterface #-}

-- | Streaming helpers: gzip, counting, and @Accept-Encoding@ negotiation.
module Pigeon.Streaming (
  ResponseChunkWriter (..),
  ResponseBodyFlush (..),
  waiStreamingBody,
  sourceHandleChunked,
  coalesceChunks,
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
  BadGzip (..),
  AcceptEncoding (..),
  parseAcceptEncoding,
)
where

import Control.Concurrent (getNumCapabilities)
import Control.Concurrent.Async (Async, async, cancel, wait)
import Control.Monad (unless, void, when)
import Control.Monad.Catch (Exception, MonadThrow, throwM)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Primitive (PrimMonad)
import Control.Monad.Trans.Resource (ReleaseKey, ResourceT, register, unprotect)
import Data.Bits (shiftR)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder (Builder)
import Data.ByteString.Char8 qualified as B8
import Data.ByteString.Unsafe (unsafeUseAsCStringLen)
import Data.Conduit
import Data.Conduit.Combinators (chunksOfE)
import Data.Conduit.Zlib (gzip)
import Data.Foldable qualified as Foldable
import Data.IORef
import Data.Int (Int64)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Streaming.Zlib (
  Deflate,
  Inflate,
  Popper,
  PopperRes (..),
  WindowBits (..),
  feedDeflate,
  feedInflate,
  finishDeflate,
  finishInflate,
  fullFlushDeflate,
  getUnusedInflate,
  initDeflate,
  initInflate,
  isCompleteInflate,
 )
import Data.Word (Word32, Word8)
import Foreign.C.Types (CLong (..), CUInt (..), CULong (..))
import Foreign.Ptr (Ptr, castPtr)
import Network.Wai (StreamingBody)
import System.IO (Handle)

import Pigeon.Types (lowerAsciiChar)

-- | Writes one chunk of a WAI response body to the client.
newtype ResponseChunkWriter = ResponseChunkWriter
  { writeResponseChunk :: Builder -> IO ()
  }

-- | Flushes buffered data in a WAI response body to the client.
newtype ResponseBodyFlush = ResponseBodyFlush
  { flushResponseBody :: IO ()
  }

{- | Adapt a callback over named response-body actions to WAI's
'StreamingBody'. This is the only place the raw WAI writer and flush actions
are unwrapped.
-}
waiStreamingBody ::
  (ResponseChunkWriter -> ResponseBodyFlush -> IO ()) ->
  StreamingBody
waiStreamingBody body write flush =
  body (ResponseChunkWriter write) (ResponseBodyFlush flush)

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

Reading is pipelined with compression: at most @workers@ blocks are in flight,
and the conductor submits the next block before waiting for the oldest one.
Memory is therefore bounded by about @workers@ blocks plus their compressed
output, and is independent of the stream length. An exception in one worker,
or in the downstream consumer, cancels the other in-flight workers.
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
      chunksOfE gzipBlockSize .| compressPipelined workers

{- | Compress blocks on a bounded pool while the conductor keeps reading.

The window holds at most @workers@ blocks. Each iteration waits for the oldest
result, emits it, and immediately submits the next block, so a read overlaps
with the compression of every other block in the window instead of alternating
with it. Results are emitted in input order. Workers also compute each block's
CRC-32, so the trailer is folded from per-block CRCs rather than from a second
pass over the input.

Every worker is registered with the surrounding 'ResourceT' scope, so an
exception anywhere in the pipeline releases the scope, cancels the remaining
workers, and cannot leave one compressing behind a closed stream.
-}
compressPipelined :: Int -> ConduitT ByteString ByteString (ResourceT IO) ()
compressPipelined workers = do
  window <- fill workers
  drain window 0 0
 where
  fill :: Int -> ConduitT ByteString ByteString (ResourceT IO) [InFlight]
  fill 0 = pure []
  fill n =
    await >>= \case
      Nothing -> pure []
      Just block -> do
        pending <- start block
        rest <- fill (n - 1)
        pure (pending : rest)

  start :: ByteString -> ConduitT ByteString ByteString (ResourceT IO) InFlight
  start block = do
    pending <- liftIO (async (compressBlock block))
    release <- register (cancel pending)
    pure InFlight{ifResult = pending, ifRelease = release}

  drain :: [InFlight] -> Word32 -> Word32 -> ConduitT ByteString ByteString (ResourceT IO) ()
  drain [] crc total = do
    terminator <- liftIO finishEmptyBlock
    yield terminator
    yield (gzipTrailer crc total)
  drain (InFlight{ifResult, ifRelease} : rest) crc total = do
    result <- liftIO (wait ifResult)
    void (unprotect ifRelease)
    yield (cbCompressed result)
    crc' <- liftIO (crc32Combine crc (cbCrc result) (cbOriginalSize result))
    let total' :: Word32
        total' = total + fromIntegral (cbOriginalSize result)
    await >>= \case
      Nothing -> drain rest crc' total'
      Just block -> do
        pending <- start block
        drain (rest <> [pending]) crc' total'

{- | One block compressed on a worker thread.

The CRC-32 covers the block's uncompressed bytes. Strict fields keep a stalled
window from accumulating thunks.
-}
data CompressedBlock = CompressedBlock
  { cbCrc :: !Word32,
    cbOriginalSize :: !Int,
    cbCompressed :: !ByteString
  }

-- | A running worker and the key that cancels it if the stream ends early.
data InFlight = InFlight
  { ifResult :: Async CompressedBlock,
    ifRelease :: ReleaseKey
  }

-- | Compress one block and hash its uncompressed bytes on a worker thread.
compressBlock :: ByteString -> IO CompressedBlock
compressBlock block = do
  crc <- crc32Chunk 0 block
  compressed <- compressBlockRaw block
  pure
    CompressedBlock
      { cbCrc = crc,
        cbOriginalSize = BS.length block,
        cbCompressed = compressed
      }

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

{- | The CRC-32 of two concatenated sequences, given each sequence's CRC-32 and
the second sequence's length.

Workers hash their block as they compress it, so the trailer is assembled from
per-block values instead of hashing the whole input again on the conductor
thread.
-}
crc32Combine :: Word32 -> Word32 -> Int -> IO Word32
crc32Combine first second secondLength =
  fromIntegral
    <$> c_crc32_combine
      (fromIntegral first)
      (fromIntegral second)
      (fromIntegral secondLength)

-- | zlib's @crc32_combine@ for two concatenated sequences.
foreign import ccall unsafe "crc32_combine"
  c_crc32_combine :: CULong -> CULong -> CLong -> IO CULong

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

{- | Why a gzip body is rejected even though part of it decodes.

We accept exactly one complete gzip member. A stream that ends before the
member's trailer would otherwise be stored and later downloaded as a silently
short file, and bytes after the member would not be counted towards the
original size (NET-023, NET-024, SEC-113).
-}
data BadGzip
  = GzipIncomplete
  | GzipTrailingData
  deriving (Eq, Show)

instance Exception BadGzip

{- | Streaming gzip decompression of exactly one complete member.

Unlike @Data.Conduit.Zlib.ungzip@, which stops at the end of the first member
and silently accepts a truncated stream, this rejects both a member that never
reaches its trailer and any bytes that follow the member.
-}
ungzipConduit :: (MonadIO m, MonadThrow m) => ConduitT ByteString ByteString m ()
ungzipConduit = do
  inflater <- liftIO (initInflate (WindowBits 31))
  feedUntilComplete inflater
  complete <- liftIO (isCompleteInflate inflater)
  unless complete $ throwM GzipIncomplete
  finalChunk <- liftIO (finishInflate inflater)
  unless (BS.null finalChunk) $ yield finalChunk
  unused <- liftIO (getUnusedInflate inflater)
  unless (BS.null unused) $ throwM GzipTrailingData
  rejectMoreInput
 where
  feedUntilComplete ::
    (MonadIO m, MonadThrow m) =>
    Inflate ->
    ConduitT ByteString ByteString m ()
  feedUntilComplete inflater = do
    next <- await
    case next of
      Nothing -> pure ()
      Just chunk
        | BS.null chunk -> feedUntilComplete inflater
        | otherwise -> do
            popper <- liftIO (feedInflate inflater chunk)
            drainInflate popper
            complete <- liftIO (isCompleteInflate inflater)
            unless complete (feedUntilComplete inflater)

  drainInflate ::
    (MonadIO m, MonadThrow m) =>
    Popper ->
    ConduitT ByteString ByteString m ()
  drainInflate popper = do
    next <- liftIO popper
    case next of
      PRDone -> pure ()
      PRNext chunk -> yield chunk >> drainInflate popper
      PRError err -> throwM err

  rejectMoreInput ::
    (MonadThrow m) =>
    ConduitT ByteString ByteString m ()
  rejectMoreInput = do
    next <- await
    case next of
      Nothing -> pure ()
      Just chunk
        | BS.null chunk -> rejectMoreInput
        | otherwise -> throwM GzipTrailingData

-- | Pass bytes through unchanged.
passThrough :: (Monad m) => ConduitT ByteString ByteString m ()
passThrough = awaitForever yield

{- | Re-chunk a byte stream so each output chunk holds at least @target@
bytes, except possibly the last.

The inflater emits at most 32 KiB per chunk, so forwarding it directly costs a
response-body write per 32 KiB. Buffering up to @target@ amortises that at a
bounded cost: at most @target@ plus one input chunk is held per stream. A
chunk that already meets the target is yielded without being copied, which
keeps the gzip passthrough path at its read size. Chunks are appended to a
'Seq' so they stay in stream order without reversing them at emit time.
-}
coalesceChunks :: forall m. (Monad m) => Int -> ConduitT ByteString ByteString m ()
coalesceChunks target
  | target <= 1 = passThrough
  | otherwise = go 0 Seq.empty
 where
  go :: Int -> Seq ByteString -> ConduitT ByteString ByteString m ()
  go pending chunks
    | pending >= target = emit chunks >> go 0 Seq.empty
    | otherwise =
        await >>= \case
          Nothing -> emit chunks
          Just chunk
            | BS.null chunk -> go pending chunks
            | otherwise -> go (pending + BS.length chunk) (chunks Seq.|> chunk)

  emit :: Seq ByteString -> ConduitT ByteString ByteString m ()
  emit chunks = case Foldable.toList chunks of
    [] -> pure ()
    [chunk] -> yield chunk
    many -> yield (BS.concat many)

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
