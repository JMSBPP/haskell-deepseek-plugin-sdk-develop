{- |
Placeholder entry point for the @conformance@ suite so the test-suite stanza
compiles before the corpus tree exists. Plan 04 replaces this with the real
tasty entry point that builds one test per @corpus/\<scenario\>@ directory.
-}
module Main (main) where

import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = defaultMain (testGroup "conformance" [])
