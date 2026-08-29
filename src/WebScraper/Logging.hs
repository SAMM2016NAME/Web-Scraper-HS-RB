{-# LANGUAGE OverloadedStrings #-}

-- | Timestamped structured logging. Every log line goes to stderr (so it
-- never interleaves with a JSON export written to stdout) and is mirrored
-- to @logs\/web_scraper.log@ for later inspection.
module WebScraper.Logging
  ( Logger
  , newLogger
  , logInfo
  , logWarn
  , logError
  ) where

import Control.Concurrent.MVar
import Control.Exception (SomeException, try)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time (getCurrentTime, defaultTimeLocale, formatTime)
import System.Directory (createDirectoryIfMissing)
import System.IO (Handle, IOMode (AppendMode), hPutStrLn, hSetBuffering, BufferMode (LineBuffering), openFile, stderr)

-- | A logger owns a shared handle to the log file, guarded by an 'MVar' so
-- that concurrent scraper threads don't interleave partial lines.
newtype Logger = Logger (MVar Handle)

data Level = Info | Warn | Error

levelTag :: Level -> Text
levelTag Info  = "INFO "
levelTag Warn  = "WARN "
levelTag Error = "ERROR"

-- | Create a logger, ensuring @logs\/@ exists and opening @logs\/web_scraper.log@
-- for appending.
newLogger :: IO Logger
newLogger = do
  createDirectoryIfMissing True "logs"
  h <- openFile "logs/web_scraper.log" AppendMode
  hSetBuffering h LineBuffering
  Logger <$> newMVar h

writeLine :: Logger -> Level -> Text -> IO ()
writeLine (Logger mh) lvl msg = do
  now <- getCurrentTime
  let ts = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" now)
      line = "[" <> ts <> "] " <> levelTag lvl <> " " <> msg
  TIO.hPutStrLn stderr line
  withMVar mh $ \h -> do
    result <- try (TIO.hPutStrLn h line) :: IO (Either SomeException ())
    either (\_ -> hPutStrLn stderr "warning: failed writing to log file") (const (pure ())) result

logInfo, logWarn, logError :: Logger -> Text -> IO ()
logInfo l  = writeLine l Info
logWarn l  = writeLine l Warn
logError l = writeLine l Error
