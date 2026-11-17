{-# LANGUAGE DerivingStrategies #-}

{- | Benchmarks for the gzip and download streaming paths.

The executable is linked with the release server's RTS profile (@-N -A4m@),
shared with @pigeon-server@ through the @release-server-rts@ common stanza in
@\@pigeon.cabal@. For numbers that match a release build, build at @-O2@ with
@cabal bench --project-file=cabal.project.release@; never compare runs from two
different project files.

Payloads are generated deterministically and forced before 'defaultMain', so
fixture construction never lands inside a measurement.
-}
module Main (main) where

import Control.DeepSeq (NFData, force)
import Control.Monad.Trans.Resource (ResourceT)
import Data.Bits (shiftL, shiftR, xor, (.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Conduit (ConduitT, await, runConduitRes, yield, (.|))
import Data.Conduit.Combinators (sinkList)
import Data.Word (Word64, Word8)
import GHC.Conc (getNumCapabilities)
import GHC.Generics (Generic)
import Test.Tasty (localOption)
import Test.Tasty.Bench (Benchmark, TimeMode (..), bench, bgroup, defaultMain, nfAppIO)

import Pigeon.Streaming (
  coalesceChunks,
  gzipConduit,
  parallelGzipConduitWith,
  ungzipConduit,
 )

-- | Input size for the single-threaded gzip benchmarks.
smallSize :: Int
smallSize = 4 * 1024 * 1024

-- | Input size for the parallel compression and decompression benchmarks.
largeSize :: Int
largeSize = 16 * 1024 * 1024

main :: IO ()
main = do
  capabilities <- getNumCapabilities
  putStrLn $
    "benchmark RTS: "
      <> show capabilities
      <> " capabilities, release-server profile (-N -A4m); override with +RTS"
  payloads <- preparePayloads
  defaultMain [localOption WallTime (benchmarks payloads)]

{- | Payloads and pre-built streams shared by every benchmark.

Compressed inputs are built once so decompression benchmarks measure inflate,
not the compressor setup.
-}
data Payloads = Payloads
  { randomSmall :: !ByteString,
    textSmall :: !ByteString,
    hexSmall :: !ByteString,
    randomLarge :: !ByteString,
    textLarge :: !ByteString,
    hexLarge :: !ByteString,
    randomGzip :: !ByteString,
    textGzip :: !ByteString,
    hexGzip :: !ByteString,
    parallelGzip :: !ByteString,
    chunks16 :: ![ByteString],
    chunks32 :: ![ByteString],
    chunks128 :: ![ByteString]
  }
  deriving stock (Generic)

instance NFData Payloads

preparePayloads :: IO Payloads
preparePayloads = do
  let randomSmallBytes = randomBytes smallSize
      textSmallBytes = textBytes smallSize
      hexSmallBytes = hexBytes smallSize randomSmallBytes
      randomLargeBytes = randomBytes largeSize
      textLargeBytes = textBytes largeSize
      hexLargeBytes = hexBytes largeSize randomLargeBytes
  randomLargeZipped <- gzipBytes randomLargeBytes
  textLargeZipped <- gzipBytes textLargeBytes
  hexLargeZipped <- gzipBytes hexLargeBytes
  parallelLargeZipped <- gzipParallel 8 randomLargeBytes
  let payloads =
        Payloads
          { randomSmall = randomSmallBytes,
            textSmall = textSmallBytes,
            hexSmall = hexSmallBytes,
            randomLarge = randomLargeBytes,
            textLarge = textLargeBytes,
            hexLarge = hexLargeBytes,
            randomGzip = randomLargeZipped,
            textGzip = textLargeZipped,
            hexGzip = hexLargeZipped,
            parallelGzip = parallelLargeZipped,
            chunks16 = splitEvery (16 * 1024) randomLargeBytes,
            chunks32 = splitEvery (32 * 1024) randomLargeBytes,
            chunks128 = splitEvery (128 * 1024) randomLargeBytes
          }
   in force payloads `seq` pure payloads

benchmarks :: Payloads -> Benchmark
benchmarks Payloads{..} =
  bgroup
    "gzip"
    [ bgroup
        "single-thread 4 MiB"
        [ bench "random" (nfAppIO gzipBytes randomSmall),
          bench "hex text" (nfAppIO gzipBytes hexSmall),
          bench "repetitive text" (nfAppIO gzipBytes textSmall)
        ],
      bgroup
        "parallel random 16 MiB"
        [bench (workerLabel workers) (nfAppIO (gzipParallel workers) randomLarge) | workers <- workerCounts],
      bgroup
        "parallel hex text 16 MiB"
        [bench (workerLabel workers) (nfAppIO (gzipParallel workers) hexLarge) | workers <- workerCounts],
      bgroup
        "parallel repetitive text 16 MiB"
        [bench (workerLabel workers) (nfAppIO (gzipParallel workers) textLarge) | workers <- workerCounts],
      bgroup
        "upload-shape random 16 MiB"
        [ bench "8 workers, 16 KiB source chunks" (nfAppIO (gzipChunks 8) chunks16)
        ],
      bgroup
        "ungzip 16 MiB"
        [ bench "random" (nfAppIO gunzipBytes randomGzip),
          bench "text" (nfAppIO gunzipBytes textGzip),
          bench "hex" (nfAppIO gunzipBytes hexGzip),
          bench "block-parallel stream" (nfAppIO gunzipBytes parallelGzip)
        ],
      bgroup
        "coalesce 16 MiB"
        [ bench "32 KiB input, 128 KiB target" (nfAppIO (coalesceBytes downloadChunkSize) chunks32),
          bench "128 KiB input, 128 KiB target" (nfAppIO (coalesceBytes downloadChunkSize) chunks128)
        ]
    ]
 where
  workerCounts :: [Int]
  workerCounts = [1, 2, 4, 8]

  workerLabel :: Int -> String
  workerLabel workers = show workers <> " workers"

-- | The download chunk size, mirroring 'Pigeon.Server.Web.downloadChunkSize'.
downloadChunkSize :: Int
downloadChunkSize = 128 * 1024

{- | Compress a payload with the single-threaded gzip conduit.

The compressed bytes are returned so 'nfIO' forces the whole result.
-}
gzipBytes :: ByteString -> IO ByteString
gzipBytes payload =
  BS.concat <$> runConduitRes (yield payload .| gzipConduit .| sinkList)

-- | Compress a payload with the block-parallel conduit and the given workers.
gzipParallel :: Int -> ByteString -> IO ByteString
gzipParallel workers payload =
  BS.concat
    <$> runConduitRes (yield payload .| parallelGzipConduitWith workers .| sinkList)

-- | Compress a payload that arrives as many small chunks, like a request body.
gzipChunks :: Int -> [ByteString] -> IO Int
gzipChunks workers pieces =
  runConduitRes
    (mapM_ yield pieces .| parallelGzipConduitWith workers .| countSink)

-- | Decompress a stored gzip stream with the validating inflater.
gunzipBytes :: ByteString -> IO ByteString
gunzipBytes compressed =
  BS.concat <$> runConduitRes (yield compressed .| ungzipConduit .| sinkList)

-- | Pass pre-chunked bytes through 'coalesceChunks' and return the output.
coalesceBytes :: Int -> [ByteString] -> IO ByteString
coalesceBytes target pieces =
  BS.concat
    <$> runConduitRes (mapM_ yield pieces .| coalesceChunks target .| sinkList)

{- | Count the bytes of a stream without retaining its chunks.

Retaining them would add allocation that the real download path does not have.
-}
countSink :: ConduitT ByteString o (ResourceT IO) Int
countSink = go 0
 where
  go :: Int -> ConduitT ByteString o (ResourceT IO) Int
  go total =
    await >>= \case
      Nothing -> pure total
      Just chunk -> go (total + BS.length chunk)

{- | Deterministic pseudo-random bytes from a 64-bit xorshift.

A fixed seed keeps payloads identical across runs and builds. The benchmarks
need incompressible data, not cryptographic randomness.
-}
randomBytes :: Int -> ByteString
randomBytes size = fst (BS.unfoldrN size step seed)
 where
  seed :: Word64
  seed = 0x123456789ABCDEF

  step :: Word64 -> Maybe (Word8, Word64)
  step state =
    let next = xorshift state
     in Just (fromIntegral (next `shiftR` 56), next)

  -- | One xorshift64 step.
  xorshift :: Word64 -> Word64
  xorshift value =
    let once = value `xor` (value `shiftL` 13)
        twice = once `xor` (once `shiftR` 7)
     in twice `xor` (twice `shiftL` 17)

{- | A repeated sentence, compressible at roughly the ratio of the analysis text.

The sentence is long enough that deflate finds matches inside the 32 KiB window,
so it exercises the same code as real text rather than long runs of one byte.
-}
textBytes :: Int -> ByteString
textBytes size = BS.take size (BS.concat (replicate copies sentence))
 where
  sentence :: ByteString
  sentence = "The quick brown fox jumps over the lazy dog. 0123456789\n"

  copies :: Int
  copies = size `div` BS.length sentence + 1

{- | Lowercase hex digits of the given size, derived from a random source.

This is the moderately compressible profile: matches exist but the alphabet is
wide, so inflate costs more per output byte than for repeated text.
-}
hexBytes :: Int -> ByteString -> ByteString
hexBytes size source = BS.take size (BS.unfoldr step (0, False))
 where
  step :: (Int, Bool) -> Maybe (Word8, (Int, Bool))
  step (index, high)
    | index >= BS.length source = Nothing
    | otherwise =
        let byte = BS.index source index
            nibble = if high then byte .&. 0x0f else byte `shiftR` 4
         in Just (hexDigit nibble, if high then (index + 1, False) else (index, True))

  hexDigit :: Word8 -> Word8
  hexDigit nibble
    | nibble < 10 = 48 + nibble
    | otherwise = 87 + nibble

-- | Split a bytestring into chunks of at most the given size.
splitEvery :: Int -> ByteString -> [ByteString]
splitEvery size bytes
  | BS.null bytes = []
  | otherwise =
      let (chunk, rest) = BS.splitAt size bytes
       in chunk : splitEvery size rest
