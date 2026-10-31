-- | Parsing and formatting of compact durations such as @7d@ or @1d12h@.
module Pigeon.Duration (
  parseDuration,
  formatDuration,
  durationSeconds,
  humanizeRemaining,
) where

import Data.Char (isDigit, toLower)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T

{- | Parse a duration into seconds.

Grammar: @unit+@ where each unit is an integer immediately followed by one
of @s@, @m@, @h@, @d@, @w@ (case-insensitive). Whitespace, signs, decimals,
and empty input are rejected. The total must fit in 'Int64'.
-}
parseDuration :: Text -> Either Text Int64
parseDuration input
  | T.null input = Left "duration must not be empty"
  | otherwise = do
      total <- go input 0
      if total <= 0
        then Left "duration must be greater than zero"
        else
          if total > fromIntegral (maxBound :: Int64)
            then Left "duration is too large"
            else Right (fromIntegral total)
 where
  go :: Text -> Integer -> Either Text Integer
  go t acc
    | T.null t = Right acc
    | otherwise = do
        let (digits, rest) = T.span isDigit t
        if T.null digits
          then Left "duration must start with a number"
          else do
            case T.uncons rest of
              Nothing -> Left "duration unit is missing"
              Just (u, after) -> do
                multiplier <- unitSeconds u
                let value = readInteger digits
                go after (acc + value * multiplier)

  readInteger :: Text -> Integer
  readInteger = T.foldl' (\n c -> n * 10 + fromIntegral (fromEnum c - fromEnum '0')) 0

  unitSeconds :: Char -> Either Text Integer
  unitSeconds c = case toLower c of
    's' -> Right 1
    'm' -> Right 60
    'h' -> Right 3600
    'd' -> Right 86400
    'w' -> Right 604800
    _ -> Left ("unknown duration unit: " <> T.singleton c)

{- | Format seconds as a normalized duration using the largest applicable
units. Zero is formatted as @0s@.
-}
formatDuration :: Int64 -> Text
formatDuration seconds
  | seconds <= 0 = "0s"
  | otherwise = T.concat (go seconds)
 where
  go :: Int64 -> [Text]
  go 0 = []
  go remaining =
    let (w, afterW) = remaining `quotRem` 604800
        (d, afterD) = afterW `quotRem` 86400
        (h, afterH) = afterD `quotRem` 3600
        (m, s) = afterH `quotRem` 60
     in component 'w' w
          ++ component 'd' d
          ++ component 'h' h
          ++ component 'm' m
          ++ component 's' s

  component :: Char -> Int64 -> [Text]
  component _ 0 = []
  component unit n = [T.pack (show n) <> T.singleton unit]

-- | Total seconds in a duration, as an 'Int64'.
durationSeconds :: Text -> Either Text Int64
durationSeconds = parseDuration

{- | Humanize a remaining duration for CLI output.

Examples: @6d 23h@, @23h 59m@, @59m@, @<1m@.
-}
humanizeRemaining :: Int64 -> Text
humanizeRemaining seconds
  | seconds <= 0 = "<1m"
  | seconds < 60 = "<1m"
  | seconds < 3600 = T.pack (show (seconds `div` 60)) <> "m"
  | seconds < 86400 =
      let (h, rest) = seconds `divMod` 3600
       in T.pack (show h) <> "h " <> T.pack (show (rest `div` 60)) <> "m"
  | otherwise =
      let (d, rest) = seconds `divMod` 86400
       in T.pack (show d) <> "d " <> T.pack (show (rest `div` 3600)) <> "h"
