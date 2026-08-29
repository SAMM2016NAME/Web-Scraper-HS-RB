{-# LANGUAGE OverloadedStrings #-}

-- | The Haskell-side processing pipeline: clean text, extract\/validate
-- structured fields, deduplicate entries, and enrich each record with a
-- timestamp and a URL-derived slug. This is the 70% of WebScraper that
-- turns "whatever HTML happened to say" into a typed, trustworthy row.
module WebScraper.Processing
  ( cleanText
  , slugify
  , normalizeUrl
  , isValidPage
  , enrich
  , processAll
  , computeStats
  ) where

import Data.Char (isAlphaNum)
import Data.List (foldl')
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, defaultTimeLocale, formatTime)

import WebScraper.Types

-- | Collapse runs of whitespace to a single space and trim the ends. Also
-- strips stray control characters that sometimes leak through from
-- malformed HTML entities.
cleanText :: Text -> Text
cleanText = T.strip . T.unwords . T.words . T.filter (not . isControlChar)
  where
    isControlChar c = c < ' ' && c /= '\t'

-- | Turn arbitrary text (typically a title or URL) into a URL-safe,
-- lowercase, hyphen-separated slug: @"Hello, World!"  ->  "hello-world"@.
slugify :: Text -> Text
slugify =
  squeeze . T.map toSlugChar . T.toLower
  where
    toSlugChar c
      | isAlphaNum c = c
      | otherwise    = '-'
    squeeze =
      T.dropAround (== '-') . T.intercalate "-" . filter (not . T.null) . T.split (== '-')

-- | Normalize a URL for deduplication purposes: lowercase the scheme and
-- host, drop a trailing slash, and drop any fragment. This is intentionally
-- conservative -- it does not touch query strings, since @?page=2@ usually
-- denotes genuinely different content.
normalizeUrl :: Text -> Text
normalizeUrl url =
  let noFragment  = T.takeWhile (/= '#') url
      dropTrailing t
        | "/" `T.isSuffixOf` t && T.length t > 1 = T.dropEnd 1 t
        | otherwise                                = t
  in case T.breakOn "://" noFragment of
       (scheme, rest) | not (T.null rest) ->
         let afterScheme = T.drop 3 rest
             (host, path) = T.breakOn "/" afterScheme
         in T.toLower scheme <> "://" <> T.toLower host <> dropTrailing path
       _ -> dropTrailing noFragment

-- | A page is considered valid if it was actually fetched successfully
-- (2xx status), came back with no scraper-reported error, and has a
-- non-empty title -- our minimal bar for "usable data".
isValidPage :: ScrapedPage -> Bool
isValidPage sp =
  maybe False in2xx (spStatusCode sp)
    && isNothing (spError sp)
    && maybe False (not . T.null . cleanText) (spTitle sp)
  where
    in2xx code = code >= 200 && code < 300

-- | Enrich one raw scraped page into a processed, DB-ready record: clean
-- its text fields, validate it, and stamp it with a slug id and a
-- processing timestamp.
enrich :: UTCTime -> ScrapedPage -> ProcessedPage
enrich now sp =
  let normalized = normalizeUrl (spUrl sp)
      title       = maybe "" cleanText (spTitle sp)
      baseSlug    = if T.null title then normalized else title
  in ProcessedPage
       { ppId              = slugify baseSlug <> "-" <> shortHash normalized
       , ppUrl             = spUrl sp
       , ppNormalizedUrl   = normalized
       , ppTitle           = title
       , ppMetaDescription = maybe "" cleanText (spMetaDescription sp)
       , ppHeadings        = map cleanText (spHeadings sp)
       , ppWordCount       = fromMaybe 0 (spWordCount sp)
       , ppContentLength   = fromMaybe 0 (spContentLength sp)
       , ppStatusCode      = fromMaybe 0 (spStatusCode sp)
       , ppIsValid         = isValidPage sp
       , ppScrapedAt       = spScrapedAt sp
       , ppProcessedAt     = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" now)
       , ppError           = spError sp
       }

-- | A short, stable, non-cryptographic hash used only to keep slugs unique
-- when two different URLs happen to clean down to the same title. Good
-- enough for a primary-key disambiguator; not intended as a security hash.
shortHash :: Text -> Text
shortHash t =
  let h = foldl' (\acc c -> (acc * 31 + fromEnum c) `mod` 0xFFFFFF) (5381 :: Int) (T.unpack t)
  in T.pack (pad6 (toHex h))
  where
    toHex 0 = "0"
    toHex n = go n ""
    go 0 acc = acc
    go n acc = go (n `div` 16) (hexDigit (n `mod` 16) : acc)
    hexDigit d
      | d < 10    = toEnum (fromEnum '0' + d)
      | otherwise = toEnum (fromEnum 'a' + d - 10)
    pad6 s = replicate (max 0 (6 - length s)) '0' ++ s

-- | Deduplicate by normalized URL, keeping the most recently processed
-- (i.e. last in the input list) copy of each page.
dedupeByUrl :: [ProcessedPage] -> [ProcessedPage]
dedupeByUrl pages =
  Map.elems (foldl' (\m p -> Map.insert (ppNormalizedUrl p) p m) Map.empty pages)

-- | Run the full processing pipeline: enrich every scraped page, then
-- deduplicate by normalized URL.
processAll :: UTCTime -> [ScrapedPage] -> [ProcessedPage]
processAll now = dedupeByUrl . map (enrich now)

-- | Compute summary statistics for a completed run. @rawCount@ is the
-- number of scraped pages *before* deduplication, so 'rsDuplicates' can
-- report how many were dropped.
computeStats :: Int -> Double -> [ProcessedPage] -> RunStats
computeStats rawCount durationSecs processed =
  RunStats
    { rsTotal        = length processed
    , rsValid        = length valid
    , rsInvalid      = length processed - length valid
    , rsDuplicates   = max 0 (rawCount - length processed)
    , rsErrors       = length (filter (not . isNothing) (map ppError processed))
    , rsAvgWordCount = if null processed then 0 else avg
    , rsDurationSecs = durationSecs
    }
  where
    valid = filter ppIsValid processed
    avg = fromIntegral (sum (map ppWordCount processed)) / fromIntegral (length processed)
