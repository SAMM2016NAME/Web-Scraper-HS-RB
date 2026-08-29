{-# LANGUAGE OverloadedStrings #-}

module WebScraper.ProcessingSpec (spec) where

import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec

import WebScraper.Processing
import WebScraper.Types

fixedNow :: UTCTime
fixedNow = UTCTime (fromGregorian 2026 8 29) (secondsToDiffTime 0)

samplePage :: ScrapedPage
samplePage = ScrapedPage
  { spUrl = "https://Example.com/Blog/Post/"
  , spStatusCode = Just 200
  , spTitle = Just "  Hello,   World!  "
  , spMetaDescription = Just "A test page."
  , spHeadings = ["  Intro  ", "Body"]
  , spWordCount = Just 42
  , spContentLength = Just 1024
  , spScrapedAt = "2026-08-29T00:00:00Z"
  , spRetries = 0
  , spError = Nothing
  }

failedPage :: ScrapedPage
failedPage = samplePage
  { spUrl = "https://example.com/missing"
  , spStatusCode = Nothing
  , spTitle = Nothing
  , spError = Just "Timeout::Error"
  }

spec :: Spec
spec = describe "WebScraper.Processing" $ do

  describe "cleanText" $ do
    it "collapses internal whitespace" $
      cleanText "hello    world" `shouldBe` "hello world"
    it "trims leading and trailing whitespace" $
      cleanText "   hello world   " `shouldBe` "hello world"
    it "handles empty input" $
      cleanText "" `shouldBe` ""

  describe "slugify" $ do
    it "lowercases and hyphenates" $
      slugify "Hello, World!" `shouldBe` "hello-world"
    it "collapses repeated separators" $
      slugify "Hello   ---   World" `shouldBe` "hello-world"
    it "trims leading/trailing hyphens" $
      slugify "--Hello World--" `shouldBe` "hello-world"

  describe "normalizeUrl" $ do
    it "lowercases scheme and host" $
      normalizeUrl "https://Example.COM/Path" `shouldBe` "https://example.com/Path"
    it "drops a trailing slash" $
      normalizeUrl "https://example.com/path/" `shouldBe` "https://example.com/path"
    it "drops fragments" $
      normalizeUrl "https://example.com/path#section" `shouldBe` "https://example.com/path"
    it "leaves the root path alone" $
      normalizeUrl "https://example.com/" `shouldBe` "https://example.com/"

  describe "isValidPage" $ do
    it "accepts a 200 with a title and no error" $
      isValidPage samplePage `shouldBe` True
    it "rejects a page with an error" $
      isValidPage failedPage `shouldBe` False
    it "rejects a page with no status code" $
      isValidPage (samplePage { spStatusCode = Nothing }) `shouldBe` False
    it "rejects a 404" $
      isValidPage (samplePage { spStatusCode = Just 404 }) `shouldBe` False
    it "rejects a blank title" $
      isValidPage (samplePage { spTitle = Just "   " }) `shouldBe` False

  describe "enrich" $ do
    let pp = enrich fixedNow samplePage
    it "cleans the title" $
      ppTitle pp `shouldBe` "Hello, World!"
    it "cleans each heading" $
      ppHeadings pp `shouldBe` ["Intro", "Body"]
    it "stamps a processed_at timestamp" $
      ppProcessedAt pp `shouldNotBe` ""
    it "derives a non-empty slug id" $
      ppId pp `shouldNotBe` ""
    it "marks a clean 200 page valid" $
      ppIsValid pp `shouldBe` True

  describe "processAll" $ do
    it "deduplicates pages with the same normalized URL" $ do
      let dupe = samplePage { spUrl = "https://example.com/Blog/Post" } -- same after normalization
          result = processAll fixedNow [samplePage, dupe]
      length result `shouldBe` 1
    it "keeps distinct URLs separate" $ do
      let result = processAll fixedNow [samplePage, failedPage]
      length result `shouldBe` 2

  describe "computeStats" $ do
    it "counts valid vs invalid and reports duplicates removed" $ do
      let processed = processAll fixedNow [samplePage, failedPage]
          stats = computeStats 3 1.5 processed
      rsTotal stats `shouldBe` 2
      rsValid stats `shouldBe` 1
      rsInvalid stats `shouldBe` 1
      rsDuplicates stats `shouldBe` 1
      rsDurationSecs stats `shouldBe` 1.5
