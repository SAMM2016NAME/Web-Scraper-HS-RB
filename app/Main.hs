{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (SomeException, try)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Time (UTCTime, defaultTimeLocale, diffUTCTime, formatTime, getCurrentTime)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Text.Printf (printf)

import WebScraper.CLI
import WebScraper.Config (loadConfig)
import WebScraper.Database (insertPages, recordRun, withDatabase)
import WebScraper.Export (exportPages)
import WebScraper.Logging
import WebScraper.Processing (computeStats, processAll)
import WebScraper.Scraper
import WebScraper.Shutdown
import WebScraper.Types

banner :: String
banner = unlines
  [ "╭──────────────────────────────────────────────────────────╮"
  , "│                    web-scraper-hs-rb                     │"
  , "│                                                          │"
  , "│  haskell orchestrates · ruby scrapes · sqlite remembers  │"
  , "╰──────────────────────────────────────────────────────────╯"
  ]

main :: IO ()
main = do
  putStr banner
  opts <- parseOptions
  logger <- newLogger
  shutdown <- newShutdownFlag
  installShutdownHandler shutdown $
    logWarn logger "received interrupt signal -- finishing in-flight work and shutting down gracefully (press Ctrl+C again to force-quit)"

  configResult <- loadConfig (optConfigPath opts)
  case configResult of
    Left err -> do
      logError logger ("failed to load config: " <> T.pack err)
      exitFailure
    Right cfg -> run opts logger shutdown cfg

run :: Options -> Logger -> ShutdownFlag -> AppConfig -> IO ()
run opts logger shutdown cfg = do
  let maxConcurrent = fromMaybe 4 (optMaxConcurrent opts)
      rateLimit     = fromMaybe (fromMaybe 2.0 (cfgRateLimit cfg)) (optRateLimit opts)
      retries       = fromMaybe (fromMaybe 3 (cfgRetries cfg)) (optRetries opts)
      settings      = ScraperSettings
        { ssMaxConcurrent = maxConcurrent
        , ssRateLimit     = rateLimit
        , ssRetries       = retries
        , ssRubyScript    = optRubyScript opts
        }

  logInfo logger $ "job: " <> cfgName cfg <> " (" <> T.pack (show (length (cfgUrls cfg))) <> " URLs, "
                 <> "max-concurrent=" <> T.pack (show maxConcurrent) <> ", "
                 <> "rate-limit=" <> T.pack (show rateLimit) <> " req/s, "
                 <> "retries=" <> T.pack (show retries) <> ")"

  startTime <- getCurrentTime
  scrapedResult <- try (runScrapers logger shutdown settings (cfgUrls cfg)) :: IO (Either SomeException [ScrapedPage])

  case scrapedResult of
    Left ex -> do
      logError logger ("scraping failed: " <> T.pack (show ex))
      exitFailure
    Right scraped -> do
      now <- getCurrentTime
      let processed = processAll now scraped
          durationSecs = realToFrac (diffUTCTime now startTime) :: Double
          stats = computeStats (length scraped) durationSecs processed

      logInfo logger $ "processed " <> T.pack (show (length processed)) <> " unique page(s); "
                     <> "writing to " <> T.pack (optDbPath opts)
      withDatabase (optDbPath opts) $ \conn -> do
        insertPages conn processed
        recordRun conn (fmtTime startTime) (fmtTime now) stats

      exportPages (optFormat opts) (optOutputPath opts) processed

      hPutStrLn stderr (renderStats stats)
      logInfo logger "done"

fmtTime :: UTCTime -> T.Text
fmtTime = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ"

renderStats :: RunStats -> String
renderStats stats = unlines
  [ "----------------------------------------"
  , "  summary"
  , "----------------------------------------"
  , printf "  total pages       : %d" (rsTotal stats)
  , printf "  valid             : %d" (rsValid stats)
  , printf "  invalid           : %d" (rsInvalid stats)
  , printf "  duplicates removed: %d" (rsDuplicates stats)
  , printf "  errors            : %d" (rsErrors stats)
  , printf "  avg word count    : %.1f" (rsAvgWordCount stats)
  , printf "  duration          : %.2fs" (rsDurationSecs stats)
  , "----------------------------------------"
  ]
