{-# LANGUAGE OverloadedStrings #-}

-- | Writes the processed pages out as JSON or CSV, either to a file or to
-- stdout (when no @--output@ path is given).
module WebScraper.Export
  ( exportPages
  , toCsv
  ) where

import Data.Aeson (encode)
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.IO (IOMode (WriteMode), withFile)

import WebScraper.Types

-- | Export @pages@ in the requested format. @Nothing@ means "write to
-- stdout"; @Just path@ writes to that file.
exportPages :: OutputFormat -> Maybe FilePath -> [ProcessedPage] -> IO ()
exportPages FormatJSON destination pages =
  case destination of
    Nothing   -> BLC.putStrLn (encode pages)
    Just path -> BL.writeFile path (encode pages)
exportPages FormatCSV destination pages =
  case destination of
    Nothing   -> TIO.putStr (toCsv pages)
    Just path -> withFile path WriteMode (`TIO.hPutStr` toCsv pages)

-- | Render pages as RFC 4180-ish CSV: a header row followed by one row per
-- page, with headings joined by @"; "@ and every field quote-escaped.
toCsv :: [ProcessedPage] -> Text
toCsv pages = T.unlines (header : map row pages)
  where
    header = T.intercalate ","
      [ "id", "url", "normalized_url", "title", "meta_description"
      , "headings", "word_count", "content_length", "status_code"
      , "is_valid", "scraped_at", "processed_at", "error"
      ]
    row p = T.intercalate ","
      [ csvField (ppId p)
      , csvField (ppUrl p)
      , csvField (ppNormalizedUrl p)
      , csvField (ppTitle p)
      , csvField (ppMetaDescription p)
      , csvField (T.intercalate "; " (ppHeadings p))
      , csvField (T.pack (show (ppWordCount p)))
      , csvField (T.pack (show (ppContentLength p)))
      , csvField (T.pack (show (ppStatusCode p)))
      , csvField (T.pack (show (ppIsValid p)))
      , csvField (ppScrapedAt p)
      , csvField (ppProcessedAt p)
      , csvField (maybe "" id (ppError p))
      ]

-- | Quote a CSV field and double up any embedded quotes, per RFC 4180.
csvField :: Text -> Text
csvField t = "\"" <> T.replace "\"" "\"\"" t <> "\""
