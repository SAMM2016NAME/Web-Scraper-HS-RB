-- | A dependency-free terminal progress bar. Renders in place using a
-- carriage return, so it plays nicely with a terminal even while multiple
-- scraper processes are completing pages concurrently -- callers just need
-- to serialize calls to 'renderProgress' (the STM counter in
-- "WebScraper.Scraper" already does this for them).
module WebScraper.Progress
  ( renderProgress
  , finishProgress
  ) where

import System.IO (hFlush, stdout)
import Text.Printf (printf)

barWidth :: Int
barWidth = 30

-- | Render (or re-render) a progress bar for @done@ out of @total@ items.
-- Safe to call repeatedly; each call overwrites the previous line.
renderProgress :: Int -> Int -> IO ()
renderProgress done total = do
  let total'   = max 1 total
      frac     = fromIntegral (min done total') / fromIntegral total' :: Double
      filled   = round (frac * fromIntegral barWidth)
      bar      = replicate filled '#' ++ replicate (barWidth - filled) '-'
      pct      = frac * 100 :: Double
  printf "\r[%s] %5.1f%%  (%d/%d) " bar pct done total
  hFlush stdout

-- | Print a trailing newline once a run's progress bar is done, so
-- subsequent log lines don't overwrite it.
finishProgress :: IO ()
finishProgress = putStrLn ""
