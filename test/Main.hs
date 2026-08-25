{- |
Entry point of the @conformance@ suite. The corpus scenario tree is built in
'IO' before 'defaultMain' so that one test exists per @corpus/<scenario>@
directory found on disk.
-}
module Main (main) where

import Test.Tasty (defaultMain, testGroup)

import Conformance.Corpus qualified as Corpus
import Conformance.Properties qualified as Properties

main :: IO ()
main = do
    scenarios <- Corpus.listScenarios
    defaultMain $
        testGroup
            "conformance"
            [ Corpus.tests scenarios
            , Properties.tests
            ]
