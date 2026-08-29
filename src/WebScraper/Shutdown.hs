-- | Graceful Ctrl+C handling.
--
-- We install a SIGINT handler that flips a shared 'TVar' rather than
-- letting the default handler kill the process outright. The scraper
-- orchestration loop (see "WebScraper.Scraper") polls this flag between
-- URLs and between chunks: on the first Ctrl+C it stops launching new work,
-- terminates in-flight Ruby child processes, and lets 'Main' write whatever
-- results have already been collected to SQLite before exiting. A second
-- Ctrl+C falls through to the OS default (immediate kill), so a genuinely
-- stuck process can still be interrupted.
module WebScraper.Shutdown
  ( ShutdownFlag
  , newShutdownFlag
  , installShutdownHandler
  , isShuttingDown
  ) where

import Control.Concurrent.STM
import Control.Monad (void)
import System.Posix.Signals

newtype ShutdownFlag = ShutdownFlag (TVar Bool)

newShutdownFlag :: IO ShutdownFlag
newShutdownFlag = ShutdownFlag <$> newTVarIO False

isShuttingDown :: ShutdownFlag -> IO Bool
isShuttingDown (ShutdownFlag tv) = readTVarIO tv

-- | Install the SIGINT handler. The supplied callback runs once, the first
-- time Ctrl+C is pressed, so 'Main' can log a "shutting down..." message.
-- The second SIGINT restores the OS default (immediate termination).
installShutdownHandler :: ShutdownFlag -> IO () -> IO ()
installShutdownHandler (ShutdownFlag tv) onFirstInterrupt =
  void $ installHandler sigINT (Catch handler) Nothing
  where
    handler = do
      already <- atomically $ do
        was <- readTVar tv
        writeTVar tv True
        pure was
      if already
        then void $ installHandler sigINT Default Nothing
        else onFirstInterrupt
