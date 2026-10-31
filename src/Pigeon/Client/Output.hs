-- | CLI output formatting: sizes, times, tables, and human messages.
module Pigeon.Client.Output (
  formatSize,
  formatUtc,
  formatFileInfo,
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

-- | UTC timestamp in CLI form.
formatUtc :: UTCTime -> Text
formatUtc =
  T.pack . Time.formatTime Time.defaultTimeLocale "%Y-%m-%d %H:%M:%S UTC"

-- | Human-readable upload result.
formatFileInfo :: UTCTime -> FileInfo -> Text
formatFileInfo now FileInfo{..} =
  T.unlines
    [ "Uploaded " <> fiFilename <> " (" <> formatSize fiSize <> ")",
      "  id:       " <> showFileId fiId,
      "  expires:  " <> formatUtc fiExpiresAt <> " (" <> remaining fiExpiresAt <> ")",
      "  password: " <> (if fiHasPassword then "yes" else "no"),
      "  url:      " <> fiUrl
    ]
 where
  remaining :: UTCTime -> Text
  remaining expiresAt =
    let seconds = max 0 (floor (diffUTCTime expiresAt now) :: Int64)
     in humanizeRemaining seconds

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
      <> padRight 8 (remaining fiExpiresAt)
      <> "  "
      <> (if fiHasPassword then "yes" else "no")

  remaining :: UTCTime -> Text
  remaining expiresAt =
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
