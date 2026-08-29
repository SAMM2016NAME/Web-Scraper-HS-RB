-- web-scraper-hs-rb SQLite schema.
--
-- This file is the human-readable reference copy of the schema. In
-- practice, WebScraper.Database.initSchema (src/WebScraper/Database.hs)
-- runs these same statements automatically on every startup, so you never
-- need to apply this file by hand -- but it's handy for `sqlite3 db.sqlite3
-- < db/schema.sql` if you want to inspect or recreate the database
-- structure directly.

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- One row per uniquely-scraped page (deduplicated by normalized URL).
CREATE TABLE IF NOT EXISTS pages (
  id                TEXT PRIMARY KEY,   -- slug derived from title/URL + short hash
  url               TEXT NOT NULL,      -- original, as-scraped URL
  normalized_url    TEXT NOT NULL,      -- lowercased host, no trailing slash/fragment
  title             TEXT,
  meta_description  TEXT,
  headings          TEXT,               -- newline-joined h1/h2/h3 text
  word_count        INTEGER,
  content_length    INTEGER,            -- response body size in bytes
  status_code       INTEGER,
  is_valid          INTEGER NOT NULL,   -- 0/1: passed WebScraper.Processing.isValidPage
  scraped_at        TEXT NOT NULL,      -- ISO 8601, set by the Ruby scraper
  processed_at      TEXT NOT NULL,      -- ISO 8601, set by the Haskell processor
  error             TEXT                -- non-null only when the fetch ultimately failed
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_pages_normalized_url ON pages(normalized_url);
CREATE INDEX IF NOT EXISTS idx_pages_status_code ON pages(status_code);

-- One row per pipeline invocation, for tracking runs over time.
CREATE TABLE IF NOT EXISTS runs (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at        TEXT NOT NULL,
  finished_at       TEXT NOT NULL,
  total_urls        INTEGER NOT NULL,
  successful        INTEGER NOT NULL,
  failed            INTEGER NOT NULL,
  duration_seconds  REAL NOT NULL
);
