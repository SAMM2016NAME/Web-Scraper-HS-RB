{-# LANGUAGE OverloadedStrings #-}

-- | Command-line interface, built with @optparse-applicative@.
module WebScraper.CLI
  ( Options (..)
  , parseOptions
  ) where

import qualified Data.Text as T
import Options.Applicative

import WebScraper.Types (OutputFormat (..))

data Options = Options
  { optConfigPath    :: !FilePath
  , optFormat        :: !OutputFormat
  , optMaxConcurrent :: !(Maybe Int)
  , optRateLimit     :: !(Maybe Double)
  , optRetries       :: !(Maybe Int)
  , optDbPath        :: !FilePath
  , optOutputPath    :: !(Maybe FilePath)
  , optRubyScript    :: !FilePath
  } deriving (Show, Eq)

parseOptions :: IO Options
parseOptions = execParser $ info (optionsParser <**> helper)
  ( fullDesc
 <> progDesc "Orchestrate Ruby scrapers, clean and validate their output, and load it into SQLite."
 <> header "WebScraper -- a hybrid Haskell/Ruby web scraping pipeline" )

optionsParser :: Parser Options
optionsParser = Options
  <$> strOption
      ( long "config" <> short 'c' <> metavar "PATH" <> value "config/urls.yaml"
     <> showDefault <> help "Path to the YAML config file listing URLs to scrape" )
  <*> formatOption
  <*> optional (option auto
      ( long "max-concurrent" <> short 'j' <> metavar "N"
     <> help "Maximum number of concurrent Ruby scraper processes (default: 4)" ))
  <*> optional (option auto
      ( long "rate-limit" <> short 'r' <> metavar "REQ/S"
     <> help "Aggregate request rate limit across all scrapers, in requests/second (default: 2.0)" ))
  <*> optional (option auto
      ( long "retries" <> metavar "N"
     <> help "Number of retry attempts for failed requests, both inside Ruby and at the Haskell orchestration level (default: 3)" ))
  <*> strOption
      ( long "db" <> metavar "PATH" <> value "web_scraper.sqlite3"
     <> showDefault <> help "Path to the SQLite database file" )
  <*> optional (strOption
      ( long "output" <> short 'o' <> metavar "PATH"
     <> help "Write the export to this file instead of stdout" ))
  <*> strOption
      ( long "ruby-script" <> metavar "PATH" <> value "scraper/scraper.rb"
     <> showDefault <> help "Path to the Ruby scraper entry point" )

formatOption :: Parser OutputFormat
formatOption = option (eitherReader parseFormat)
  ( long "format" <> short 'f' <> metavar "json|csv" <> value FormatJSON
 <> showDefaultWith formatName
 <> help "Output format for the processed data: json or csv" )
  where
    formatName FormatJSON = "json"
    formatName FormatCSV  = "csv"

parseFormat :: String -> Either String OutputFormat
parseFormat s = case T.toLower (T.pack s) of
  "json" -> Right FormatJSON
  "csv"  -> Right FormatCSV
  other  -> Left ("unknown format " <> show (T.unpack other) <> "; expected 'json' or 'csv'")
