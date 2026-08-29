{-# LANGUAGE OverloadedStrings #-}

-- | Process orchestration: splits the URL list across a pool of Ruby
-- @scraper.rb@ child processes, talks to each over stdin\/stdout pipes,
-- and merges their results using STM so that concurrent completions never
-- race on shared state (the results list, the progress counter, the retry
-- queue). This module is the "Haskell handles multiple Ruby processes"
-- half of the architecture.
module WebScraper.Scraper
  ( ScraperSettings (..)
  , runScrapers
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Exception (SomeException, try, finally)
import Data.Aeson (eitherDecodeStrict)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import System.IO
import System.Process

import WebScraper.Logging
import WebScraper.Progress (renderProgress, finishProgress)
import WebScraper.Shutdown
import WebScraper.Types (ScrapedPage (..))

data ScraperSettings = ScraperSettings
  { ssMaxConcurrent :: !Int
  , ssRateLimit     :: !Double -- ^ aggregate requests/second budget across all workers
  , ssRetries       :: !Int
  , ssRubyScript    :: !FilePath
  } deriving (Show, Eq)

-- | Run the whole scrape: partition @urls@ across up to 'ssMaxConcurrent'
-- Ruby worker processes, collect their NDJSON output via STM, then
-- re-attempt (once, against a single fresh worker) any URL that failed.
-- Returns every 'ScrapedPage' collected, successes and still-failing
-- entries alike -- filtering into "valid" vs "invalid" is the processing
-- stage's job, not the orchestrator's.
runScrapers :: Logger -> ShutdownFlag -> ScraperSettings -> [Text] -> IO [ScrapedPage]
runScrapers logger shutdown settings urls = do
  let numUrls    = length urls
      numWorkers = max 1 (min (ssMaxConcurrent settings) (max 1 numUrls))
      chunks     = chunkEvenly numWorkers urls
      perWorkerRate = ssRateLimit settings / fromIntegral (max 1 numWorkers)

  logInfo logger $ "dispatching " <> T.pack (show numUrls) <> " URL(s) across "
                  <> T.pack (show numWorkers) <> " worker process(es), "
                  <> T.pack (show perWorkerRate) <> " req/s each"

  doneCounter <- newTVarIO (0 :: Int)
  resultsVar  <- newTVarIO ([] :: [ScrapedPage])
  remaining   <- newTVarIO (length (filter (not . null) chunks))

  mapM_ (forkIO . runWorkerChunk logger shutdown settings perWorkerRate doneCounter resultsVar remaining numUrls)
        (filter (not . null) chunks)

  -- STM barrier: block until every worker thread has signalled completion.
  atomically $ do
    n <- readTVar remaining
    if n <= 0 then pure () else retry

  finishProgress
  firstPass <- readTVarIO resultsVar

  let failed = [ spUrl sp | sp <- firstPass, isFailure sp ]
  if null failed || ssRetries settings <= 0
    then pure firstPass
    else do
      logWarn logger $ T.pack (show (length failed)) <> " URL(s) failed on the first pass; retrying once"
      retried <- runOneShotRetry logger shutdown settings failed
      let succeededUrls = map spUrl retried
          keep sp = spUrl sp `notElem` succeededUrls
      pure (filter keep firstPass ++ retried)

isFailure :: ScrapedPage -> Bool
isFailure sp = spError sp /= Nothing || maybe True (\c -> c < 200 || c >= 300) (spStatusCode sp)

-- | A single, non-concurrent retry pass over the URLs that failed the
-- first time around, using a fresh Ruby process.
runOneShotRetry :: Logger -> ShutdownFlag -> ScraperSettings -> [Text] -> IO [ScrapedPage]
runOneShotRetry logger shutdown settings failedUrls = do
  doneCounter <- newTVarIO (0 :: Int)
  resultsVar  <- newTVarIO ([] :: [ScrapedPage])
  remaining   <- newTVarIO (1 :: Int)
  runWorkerChunk logger shutdown settings (ssRateLimit settings) doneCounter resultsVar remaining
                 (length failedUrls) failedUrls
  finishProgress
  readTVarIO resultsVar

-- | Split @xs@ into (up to) @n@ roughly-equal contiguous chunks.
chunkEvenly :: Int -> [a] -> [[a]]
chunkEvenly n xs
  | n <= 1    = [xs]
  | otherwise =
      let len  = length xs
          base = len `div` n
          extra = len `mod` n
          sizes = [ base + (if i < extra then 1 else 0) | i <- [0 .. n - 1] ]
      in go sizes xs
  where
    go [] _ = []
    go (s:ss) ys = let (h, t) = splitAt s ys in h : go ss t

-- | Spawn one Ruby worker for @chunk@, feed it URLs over stdin (one per
-- line), and stream-parse its NDJSON stdout, one 'ScrapedPage' at a time,
-- pushing each into the shared 'TVar' as soon as it arrives so the
-- progress bar and downstream processing can start as early as possible.
runWorkerChunk
  :: Logger -> ShutdownFlag -> ScraperSettings -> Double
  -> TVar Int -> TVar [ScrapedPage] -> TVar Int -> Int -> [Text] -> IO ()
runWorkerChunk logger shutdown settings rate doneCounter resultsVar remaining totalUrls chunk =
  (`finally` atomically (modifyTVar' remaining (subtract 1))) $ do
    stopping <- isShuttingDown shutdown
    if stopping
      then pure ()
      else do
        let args = [ "--rate-limit", show rate
                   , "--retries", show (ssRetries settings)
                   ]
        (Just hin, Just hout, _, ph) <- createProcess (proc "ruby" (ssRubyScript settings : args))
          { std_in = CreatePipe, std_out = CreatePipe, std_err = Inherit }
        hSetBuffering hin LineBuffering
        hSetBuffering hout LineBuffering
        hSetEncoding hin utf8
        hSetEncoding hout utf8

        mapM_ (TIO.hPutStrLn hin) chunk
        hClose hin

        readLinesUntilEOF hout $ \line -> do
          stillGoing <- not <$> isShuttingDown shutdown
          if not stillGoing
            then terminateProcess ph
            else case eitherDecodeStrict (TE.encodeUtf8 line) of
              Right sp -> do
                atomically $ do
                  modifyTVar' resultsVar (sp :)
                  modifyTVar' doneCounter (+ 1)
                n <- readTVarIO doneCounter
                renderProgress n totalUrls
              Left err ->
                logError logger $ "failed to parse scraper output line: " <> T.pack err

        _ <- waitForProcess ph
        pure ()

-- | Read lines from a handle until EOF, calling @f@ on each. Tolerant of
-- the handle closing mid-read (e.g. the child process crashed).
readLinesUntilEOF :: Handle -> (Text -> IO ()) -> IO ()
readLinesUntilEOF h f = loop
  where
    loop = do
      eof <- try (hIsEOF h) :: IO (Either SomeException Bool)
      case eof of
        Left _      -> pure ()
        Right True  -> pure ()
        Right False -> do
          lineResult <- try (TIO.hGetLine h) :: IO (Either SomeException Text)
          case lineResult of
            Left _     -> pure ()
            Right line
              | T.null (T.strip line) -> loop
              | otherwise             -> f line >> loop
