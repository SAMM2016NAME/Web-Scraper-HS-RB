{-# LANGUAGE OverloadedStrings #-}

module WebScraper.ConfigSpec (spec) where

import Test.Hspec

import WebScraper.Config (parseConfig)
import WebScraper.Types

spec :: Spec
spec = describe "WebScraper.Config" $ do

  it "parses name, rate_limit, retries and a urls block" $ do
    let raw = unlines
          [ "name: My Job"
          , "rate_limit: 3.5"
          , "retries: 5"
          , "urls:"
          , "  - https://example.com"
          , "  - https://example.org/about"
          ]
    case parseConfig raw of
      Left err -> expectationFailure err
      Right cfg -> do
        cfgName cfg `shouldBe` "My Job"
        cfgRateLimit cfg `shouldBe` Just 3.5
        cfgRetries cfg `shouldBe` Just 5
        cfgUrls cfg `shouldBe` ["https://example.com", "https://example.org/about"]

  it "ignores comments and blank lines" $ do
    let raw = unlines
          [ "# a comment"
          , ""
          , "urls:"
          , "  - https://example.com"
          , ""
          , "  - https://example.org"
          ]
    case parseConfig raw of
      Left err -> expectationFailure err
      Right cfg -> cfgUrls cfg `shouldBe` ["https://example.com", "https://example.org"]

  it "defaults name when not given" $ do
    let raw = "urls:\n  - https://example.com\n"
    case parseConfig raw of
      Left err -> expectationFailure err
      Right cfg -> cfgName cfg `shouldBe` "WebScraper job"

  it "fails when there are no URLs" $ do
    let raw = "name: Empty Job\n"
    parseConfig raw `shouldSatisfy` isLeft

  where
    isLeft (Left _) = True
    isLeft _        = False
