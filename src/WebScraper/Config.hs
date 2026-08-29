{-# LANGUAGE OverloadedStrings #-}

-- | Minimal, dependency-free parser for @config/urls.yaml@.
--
-- We deliberately do not pull in a full YAML library: the config format
-- WebScraper needs is a small, fixed subset (a handful of top-level
-- @key: value@ scalars plus one @urls:@ block-sequence), so a ~40-line
-- hand-written parser keeps the dependency list matching the project's
-- required tech stack. If you need richer YAML (anchors, nested maps,
-- multi-document files, ...), swap this module for the @yaml@ package --
-- the rest of the pipeline only depends on 'AppConfig'.
module WebScraper.Config
  ( loadConfig
  , parseConfig
  ) where

import Data.Char (isSpace)
import Data.List (isPrefixOf, stripPrefix)
import qualified Data.Text as T

import WebScraper.Types (AppConfig (..))

-- | Load and parse a config file from disk.
loadConfig :: FilePath -> IO (Either String AppConfig)
loadConfig path = do
  contents <- readFile path
  pure (parseConfig contents)

-- | Parse the contents of a config file. Exposed separately from
-- 'loadConfig' so it can be unit tested without touching the filesystem.
parseConfig :: String -> Either String AppConfig
parseConfig raw =
  let ls = filter (not . isCommentOrBlank) (lines raw)
  in go ls initial
  where
    initial = AppConfig { cfgName = "WebScraper job", cfgUrls = [], cfgRateLimit = Nothing, cfgRetries = Nothing }

    isCommentOrBlank l =
      let t = strip l
      in null t || "#" `isPrefixOf` t

    go [] cfg
      | null (cfgUrls cfg) = Left "config error: no URLs found under a top-level 'urls:' key"
      | otherwise          = Right cfg { cfgUrls = reverse (cfgUrls cfg) }
    go (l:rest) cfg
      | trimmed == "urls:" =
          let (urlLines, rest') = span isListItem rest
              urls = [ T.pack (strip (drop 2 (strip u))) | u <- urlLines ]
          in go rest' cfg { cfgUrls = reverse urls ++ cfgUrls cfg }
      | Just v <- stripKey "name:" trimmed = go rest cfg { cfgName = T.pack (unquote v) }
      | Just v <- stripKey "rate_limit:" trimmed = go rest cfg { cfgRateLimit = readMaybeDouble v }
      | Just v <- stripKey "retries:" trimmed = go rest cfg { cfgRetries = readMaybeInt v }
      | otherwise = go rest cfg -- ignore unknown keys for forward compatibility
      where
        trimmed = strip l

    isListItem l = "- " `isPrefixOf` strip l

    stripKey key l = strip <$> stripPrefix key l

    readMaybeDouble v = case reads v :: [(Double, String)] of
      [(d, "")] -> Just d
      _         -> Nothing

    readMaybeInt v = case reads v :: [(Int, String)] of
      [(n, "")] -> Just n
      _         -> Nothing

    unquote s =
      case s of
        ('"':rest') | not (null rest') && last rest' == '"' -> init rest'
        _                                                     -> s

    strip :: String -> String
    strip = dropWhileEnd isSpace . dropWhile isSpace

    dropWhileEnd p = foldr (\x xs -> if p x && null xs then [] else x : xs) []
