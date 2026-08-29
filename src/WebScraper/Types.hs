{-# LANGUAGE OverloadedStrings #-}

-- | Core, type-safe data definitions shared across the WebScraper pipeline.
--
-- 'ScrapedPage' mirrors the JSON emitted by the Ruby scraper (one line of
-- NDJSON per page). 'ProcessedPage' is the enriched, validated record that
-- gets written to SQLite and exported as JSON\/CSV. Keeping these as two
-- distinct types (rather than one mutable record) makes the "raw input" vs
-- "cleaned output" boundary explicit and lets the compiler catch any place
-- that accidentally treats unvalidated scraper output as trusted data.
module WebScraper.Types
  ( ScrapedPage (..)
  , ProcessedPage (..)
  , OutputFormat (..)
  , RunStats (..)
  , AppConfig (..)
  ) where

import Data.Aeson
import Data.Text (Text)

-- | One record of raw scraper output, as produced by @scraper/scraper.rb@.
-- Every field except 'spUrl' and 'spScrapedAt' is optional because a failed
-- fetch still produces a well-formed JSON line (with @error@ set and the
-- content fields absent).
data ScrapedPage = ScrapedPage
  { spUrl             :: !Text
  , spStatusCode      :: !(Maybe Int)
  , spTitle           :: !(Maybe Text)
  , spMetaDescription :: !(Maybe Text)
  , spHeadings        :: ![Text]
  , spWordCount       :: !(Maybe Int)
  , spContentLength   :: !(Maybe Int)
  , spScrapedAt       :: !Text
  , spRetries         :: !Int
  , spError           :: !(Maybe Text)
  } deriving (Show, Eq)

instance FromJSON ScrapedPage where
  parseJSON = withObject "ScrapedPage" $ \o ->
    ScrapedPage
      <$> o .:  "url"
      <*> o .:? "status_code"
      <*> o .:? "title"
      <*> o .:? "meta_description"
      <*> o .:? "headings" .!= []
      <*> o .:? "word_count"
      <*> o .:? "content_length"
      <*> o .:  "scraped_at"
      <*> o .:? "retries" .!= 0
      <*> o .:? "error"

instance ToJSON ScrapedPage where
  toJSON sp = object
    [ "url"               .= spUrl sp
    , "status_code"       .= spStatusCode sp
    , "title"             .= spTitle sp
    , "meta_description"  .= spMetaDescription sp
    , "headings"          .= spHeadings sp
    , "word_count"        .= spWordCount sp
    , "content_length"    .= spContentLength sp
    , "scraped_at"        .= spScrapedAt sp
    , "retries"           .= spRetries sp
    , "error"             .= spError sp
    ]

-- | Cleaned, validated, deduplicated, enriched record. This is the shape
-- that is written to the @pages@ table in SQLite and to JSON\/CSV exports.
data ProcessedPage = ProcessedPage
  { ppId              :: !Text -- ^ slug derived from the normalized URL; primary key
  , ppUrl             :: !Text
  , ppNormalizedUrl   :: !Text
  , ppTitle           :: !Text
  , ppMetaDescription :: !Text
  , ppHeadings        :: ![Text]
  , ppWordCount       :: !Int
  , ppContentLength   :: !Int
  , ppStatusCode      :: !Int
  , ppIsValid         :: !Bool
  , ppScrapedAt       :: !Text
  , ppProcessedAt     :: !Text
  , ppError           :: !(Maybe Text)
  } deriving (Show, Eq)

instance ToJSON ProcessedPage where
  toJSON pp = object
    [ "id"                .= ppId pp
    , "url"                .= ppUrl pp
    , "normalized_url"     .= ppNormalizedUrl pp
    , "title"              .= ppTitle pp
    , "meta_description"   .= ppMetaDescription pp
    , "headings"           .= ppHeadings pp
    , "word_count"         .= ppWordCount pp
    , "content_length"     .= ppContentLength pp
    , "status_code"        .= ppStatusCode pp
    , "is_valid"           .= ppIsValid pp
    , "scraped_at"         .= ppScrapedAt pp
    , "processed_at"       .= ppProcessedAt pp
    , "error"              .= ppError pp
    ]

-- | Output format selected on the command line.
data OutputFormat = FormatJSON | FormatCSV
  deriving (Show, Eq)

-- | Summary statistics printed at the end of a run.
data RunStats = RunStats
  { rsTotal         :: !Int
  , rsValid         :: !Int
  , rsInvalid       :: !Int
  , rsDuplicates    :: !Int
  , rsErrors        :: !Int
  , rsAvgWordCount  :: !Double
  , rsDurationSecs  :: !Double
  } deriving (Show, Eq)

instance ToJSON RunStats where
  toJSON rs = object
    [ "total_pages"       .= rsTotal rs
    , "valid_pages"       .= rsValid rs
    , "invalid_pages"     .= rsInvalid rs
    , "duplicates_removed" .= rsDuplicates rs
    , "errors"            .= rsErrors rs
    , "avg_word_count"    .= rsAvgWordCount rs
    , "duration_seconds"  .= rsDurationSecs rs
    ]

-- | Parsed contents of @config/urls.yaml@.
data AppConfig = AppConfig
  { cfgName      :: !Text
  , cfgUrls      :: ![Text]
  , cfgRateLimit :: !(Maybe Double)
  , cfgRetries   :: !(Maybe Int)
  } deriving (Show, Eq)
