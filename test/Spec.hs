import Test.Hspec

import qualified WebScraper.ConfigSpec
import qualified WebScraper.ProcessingSpec

main :: IO ()
main = hspec $ do
  WebScraper.ProcessingSpec.spec
  WebScraper.ConfigSpec.spec
