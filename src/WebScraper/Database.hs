{-# LANGUAGE OverloadedStrings #-}

-- | SQLite persistence via @sqlite-simple@. The schema created here mirrors
-- @db\/schema.sql@ exactly -- that file is the checked-in reference copy;
-- this module is what actually runs at startup so a fresh checkout never
-- needs a separate migration step.
module WebScraper.Database
  ( withDatabase
  , initSchema
  , insertPages
  , recordRun
  ) where

import Data.Text (Text)
import Database.SQLite.Simple
import Database.SQLite.Simple.ToField (toField)

import WebScraper.Types

-- | 13 columns is past the arity that sqlite-simple's built-in tuple
-- 'ToRow' instances cover, so 'ProcessedPage' gets its own instance
-- rather than being marshalled through an intermediate tuple.
instance ToRow ProcessedPage where
  toRow p =
    [ toField (ppId p)
    , toField (ppUrl p)
    , toField (ppNormalizedUrl p)
    , toField (ppTitle p)
    , toField (ppMetaDescription p)
    , toField (encodeHeadings (ppHeadings p))
    , toField (ppWordCount p)
    , toField (ppContentLength p)
    , toField (ppStatusCode p)
    , toField (ppIsValid p)
    , toField (ppScrapedAt p)
    , toField (ppProcessedAt p)
    , toField (ppError p)
    ]

-- | Open (creating if necessary) the SQLite database at @path@, run it
-- through @action@, and always close it afterwards -- including on an
-- exception, so a Ctrl+C mid-run doesn't leave the file locked.
withDatabase :: FilePath -> (Connection -> IO a) -> IO a
withDatabase path action = withConnection path $ \conn -> do
  initSchema conn
  action conn

-- | Create the @pages@ and @runs@ tables (and their indexes) if they don't
-- already exist. Safe to call on every startup.
initSchema :: Connection -> IO ()
initSchema conn = do
  execute_ conn "PRAGMA journal_mode = WAL;"
  execute_ conn "PRAGMA foreign_keys = ON;"
  execute_ conn
    "CREATE TABLE IF NOT EXISTS pages (\
    \  id TEXT PRIMARY KEY,\
    \  url TEXT NOT NULL,\
    \  normalized_url TEXT NOT NULL,\
    \  title TEXT,\
    \  meta_description TEXT,\
    \  headings TEXT,\
    \  word_count INTEGER,\
    \  content_length INTEGER,\
    \  status_code INTEGER,\
    \  is_valid INTEGER NOT NULL,\
    \  scraped_at TEXT NOT NULL,\
    \  processed_at TEXT NOT NULL,\
    \  error TEXT\
    \);"
  execute_ conn
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_pages_normalized_url ON pages(normalized_url);"
  execute_ conn
    "CREATE INDEX IF NOT EXISTS idx_pages_status_code ON pages(status_code);"
  execute_ conn
    "CREATE TABLE IF NOT EXISTS runs (\
    \  id INTEGER PRIMARY KEY AUTOINCREMENT,\
    \  started_at TEXT NOT NULL,\
    \  finished_at TEXT NOT NULL,\
    \  total_urls INTEGER NOT NULL,\
    \  successful INTEGER NOT NULL,\
    \  failed INTEGER NOT NULL,\
    \  duration_seconds REAL NOT NULL\
    \);"

-- | Upsert every processed page. Re-running WebScraper against the same
-- URLs updates existing rows (matched by the URL-derived @id@) rather than
-- duplicating them.
insertPages :: Connection -> [ProcessedPage] -> IO ()
insertPages conn pages =
  withTransaction conn $
    mapM_
      (\p -> execute conn
        "INSERT INTO pages \
        \  (id, url, normalized_url, title, meta_description, headings, \
        \   word_count, content_length, status_code, is_valid, scraped_at, \
        \   processed_at, error) \
        \VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
        \ON CONFLICT(id) DO UPDATE SET \
        \  title = excluded.title, \
        \  meta_description = excluded.meta_description, \
        \  headings = excluded.headings, \
        \  word_count = excluded.word_count, \
        \  content_length = excluded.content_length, \
        \  status_code = excluded.status_code, \
        \  is_valid = excluded.is_valid, \
        \  scraped_at = excluded.scraped_at, \
        \  processed_at = excluded.processed_at, \
        \  error = excluded.error"
        p)
      pages

-- | Headings are stored as a simple newline-joined blob rather than a JSON
-- array column -- SQLite has no native array type, and keeping this human
-- readable (@sqlite3 db.sqlite3 "select headings from pages"@) is more
-- useful for a scraping tool than a JSON string would be.
encodeHeadings :: [Text] -> Text
encodeHeadings = mconcat . map (<> "\n")

-- | Record one row in the @runs@ table summarizing a completed invocation.
recordRun :: Connection -> Text -> Text -> RunStats -> IO ()
recordRun conn startedAt finishedAt stats =
  execute conn
    "INSERT INTO runs (started_at, finished_at, total_urls, successful, failed, duration_seconds) \
    \VALUES (?, ?, ?, ?, ?, ?)"
    (startedAt, finishedAt, rsTotal stats, rsValid stats, rsInvalid stats, rsDurationSecs stats)
