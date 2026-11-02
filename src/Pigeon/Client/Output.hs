-- | CLI output formatting: sizes, times, tables, and command results.
module Pigeon.Client.Output (
  formatSize,
  transferRate,
  estimateEta,
  formatEta,
  formatRate,
  formatUploadUrl,
  formatFileTable,
  truncateName,
  deleteResultJson,
) where

import Data.Aeson (Value, object, (.=))
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, diffUTCTime)
import Data.Time.Format qualified as Time

import Pigeon.Duration (humanizeRemaining)
import Pigeon.Types (FileId (..), FileInfo (..))

-- | Format bytes using binary units and one decimal place.
formatSize :: Int64 -> Text
formatSize bytes
  | bytes < 1024 = T.pack (show bytes) <> " B"
  | bytes < 1024 * 1024 = oneDecimal (fromIntegral bytes / 1024) <> " KiB"
  | bytes < 1024 * 1024 * 1024 = oneDecimal (fromIntegral bytes / (1024 * 1024)) <> " MiB"
  | otherwise = oneDecimal (fromIntegral bytes / (1024 * 1024 * 1024)) <> " GiB"
 where
  oneDecimal :: Double -> Text
  oneDecimal value =
    let rounded = fromIntegral (round (value * 10) :: Int) / 10 :: Double
     in T.pack (show rounded)

{- | Minimum elapsed seconds before a throughput or ETA is considered stable
enough to show.

The first redraws of a fast local upload would otherwise extrapolate from a
tiny sample and display a wildly wrong estimate.
-}
minimumEtaElapsedSeconds :: Double
minimumEtaElapsedSeconds = 0.5

{- | Average throughput in bytes per second since the transfer started.

Returns 'Nothing' while no estimate is possible: no bytes have been counted or
less than 'minimumEtaElapsedSeconds' has elapsed.
-}
transferRate :: Int64 -> Double -> Maybe Double
transferRate current elapsedSeconds
  | current <= 0 = Nothing
  | elapsedSeconds < minimumEtaElapsedSeconds = Nothing
  | otherwise = Just (fromIntegral current / elapsedSeconds)

{- | Estimate the remaining upload time in seconds from the average throughput
since the transfer started.

Returns 'Nothing' while no estimate is possible: no bytes have been counted,
the size is unknown, or less than 'minimumEtaElapsedSeconds' has elapsed.
Returns @Just 0@ once every byte has been counted.
-}
estimateEta :: Int64 -> Int64 -> Double -> Maybe Int64
estimateEta total current elapsedSeconds
  | total <= 0 = Nothing
  | current <= 0 = Nothing
  | current >= total = Just 0
  | otherwise =
      case transferRate current elapsedSeconds of
        Nothing -> Nothing
        Just rate ->
          let remaining :: Double
              remaining = fromIntegral (total - current)
           in Just (max 0 (ceiling (remaining / rate)))

-- | Format a remaining-time estimate: @45s@, @1m 05s@, or @1h 05m@.
formatEta :: Int64 -> Text
formatEta seconds
  | seconds < 60 = T.pack (show (max 0 seconds)) <> "s"
  | seconds < 3600 =
      let (minutes, rest) = seconds `divMod` 60
       in T.pack (show minutes) <> "m " <> twoDigits rest <> "s"
  | otherwise =
      let (hours, rest) = seconds `divMod` 3600
          minutes = rest `div` 60
       in T.pack (show hours) <> "h " <> twoDigits minutes <> "m"
 where
  twoDigits :: Int64 -> Text
  twoDigits value =
    (if value < 10 then "0" else "") <> T.pack (show value)

-- | Format a throughput in bytes per second: @0 B/s@, @512 B\/s@, or @4.2 MiB\/s@.
formatRate :: Double -> Text
formatRate rate = formatSize (round rate) <> "/s"

{- | Default upload result: the public URL followed by a newline.

The URL is printed exactly as returned by the server and is the only thing
written to stdout for a successful upload.
-}
formatUploadUrl :: FileInfo -> Text
formatUploadUrl info = fiUrl info <> "\n"

-- | Human-readable list table. Preserves the input order.
formatFileTable :: UTCTime -> [FileInfo] -> Text
formatFileTable _now [] = "No files.\n"
formatFileTable now files =
  T.unlines (header : map renderRow files)
 where
  header :: Text
  header =
    padRight 16 "ID"
      <> "  "
      <> padRight 40 "NAME"
      <> "  "
      <> padLeft 9 "SIZE"
      <> "  "
      <> padRight 19 "EXPIRES (UTC)"
      <> "  "
      <> padRight 8 "LEFT"
      <> "  "
      <> "PW"

  renderRow :: FileInfo -> Text
  renderRow FileInfo{..} =
    padRight 16 (showFileId fiId)
      <> "  "
      <> padRight 40 (truncateName fiFilename)
      <> "  "
      <> padLeft 9 (formatSize fiSize)
      <> "  "
      <> padRight 19 (T.pack (Time.formatTime Time.defaultTimeLocale "%Y-%m-%d %H:%M:%S" fiExpiresAt))
      <> "  "
      <> padRight 8 (remainingUntil now fiExpiresAt)
      <> "  "
      <> (if fiHasPassword then "yes" else "no")

-- | Remaining time until @expiresAt@, clamped at zero and humanized.
remainingUntil :: UTCTime -> UTCTime -> Text
remainingUntil now expiresAt =
  let seconds = max 0 (floor (diffUTCTime expiresAt now) :: Int64)
   in humanizeRemaining seconds

padRight :: Int -> Text -> Text
padRight width value = value <> T.replicate (max 0 (width - T.length value)) " "

padLeft :: Int -> Text -> Text
padLeft width value = T.replicate (max 0 (width - T.length value)) " " <> value

-- | Truncate a display name to 40 characters, using @...@ when shortened.
truncateName :: Text -> Text
truncateName name
  | T.length name <= 40 = name
  | otherwise = T.take 37 name <> "..."

showFileId :: FileId -> Text
showFileId = unFileId

-- | JSON for a delete run, as documented in the client spec.
deleteResultJson :: [Text] -> [(Text, Text, Text)] -> Value
deleteResultJson deleted failed =
  object
    [ "deleted" .= deleted,
      "failed"
        .= [ object ["id" .= fileId, "code" .= code, "message" .= message]
           | (fileId, code, message) <- failed
           ]
    ]
