{-# LANGUAGE OverloadedStrings #-}

{- |
Corpus scenario enumeration and the meta-tests that keep the corpus honest.

A scenario is wrapped in 'expectFailBecause' if and only if
@corpus\/\<scenario\>\/EXPECTED.md@ exists, so the manifest of known-red
scenarios is the filesystem itself and cannot drift from a parallel list.
'Test.Tasty.ExpectedFailure.expectFailBecause' reports an unexpected pass as
a suite failure, which is what forces the owning phase to delete the file.
-}
module Conformance.Corpus (
    Scenario (..),
    corpusRoot,
    requiredScenarios,
    listScenarios,
    tests,
) where

import Control.Monad (filterM, unless)
import Data.Aeson (Key, Value (..), decodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Char8 qualified as BS
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Foldable (toList)
import Data.List (sort, (\\))
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.ExpectedFailure (expectFailBecause)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

{- | A corpus scenario directory and the first line of its @EXPECTED.md@ when
one exists.
-}
data Scenario = Scenario
    { scenarioName :: FilePath
    , scenarioExpected :: Maybe String
    }
    deriving (Eq, Show)

{- | @stack test@ runs the test binary with the package root as its working
directory, so the corpus resolves relatively.
-}
corpusRoot :: FilePath
corpusRoot = "corpus"

{- | Scenarios PROTO-02 requires. A directory missing from disk fails
'requiredScenariosPresent' rather than silently shrinking the tree.
-}
requiredScenarios :: [FilePath]
requiredScenarios =
    [ "cancel-inflight"
    , "cancel-late"
    , "cancel-unknown"
    , "guard-allow"
    , "guard-ask"
    , "guard-deny"
    , "handshake"
    , "malformed-junk-line"
    , "malformed-oversize"
    , "malformed-shape"
    , "section-changed"
    , "shutdown"
    , "subagent-run"
    , "tool-call"
    , "tool-failure"
    , "tool-unknown"
    , "version-mismatch"
    ]

-- | Scenarios whose @host.jsonl@ deliberately contains a non-JSON line.
parseExempt :: [FilePath]
parseExempt = ["malformed-junk-line"]

-- | Every directory under 'corpusRoot', sorted, paired with its expectation.
listScenarios :: IO [Scenario]
listScenarios = do
    entries <- listDirectory corpusRoot
    names <- sort <$> filterM (doesDirectoryExist . (corpusRoot </>)) entries
    traverse (\n -> Scenario n <$> readExpected n) names

readExpected :: FilePath -> IO (Maybe String)
readExpected name = do
    let path = corpusRoot </> name </> "EXPECTED.md"
    present <- doesFileExist path
    if present
        then Just . takeWhile (/= '\n') <$> readFile path
        else pure Nothing

-- | The corpus test group: one test per scenario plus the meta-tests.
tests :: [Scenario] -> TestTree
tests scenarios =
    testGroup
        "corpus"
        [ testGroup "scenarios" (map scenarioTest scenarios)
        , testGroup
            "meta"
            [ requiredScenariosPresent scenarios
            , everyLineIsOneJsonValue scenarios
            , everyExpectedNamesAPhase scenarios
            , manifestDeclaresEveryContribution
            , manifestToolNamesAreWellFormed
            ]
        ]

scenarioTest :: Scenario -> TestTree
scenarioTest (Scenario name expected) =
    maybe id expectFailBecause expected (testCase name (replayScenario name))

{- | Phase 2 replaces the 'assertFailure' with a real replay through the
in-memory transport pair. Until then this body MUST fail: a stub that passes
under 'expectFailBecause' is reported as an unexpected success and fails the
suite.
-}
replayScenario :: FilePath -> IO ()
replayScenario name = do
    host <- BS.readFile (corpusRoot </> name </> "host.jsonl")
    BS.null host @?= False
    assertFailure ("replay not implemented: " <> name)

requiredScenariosPresent :: [Scenario] -> TestTree
requiredScenariosPresent scenarios =
    testCase "every required scenario directory exists" $
        case sort requiredScenarios \\ sort (map scenarioName scenarios) of
            [] -> pure ()
            missing -> assertFailure ("missing corpus scenarios: " <> show missing)

everyLineIsOneJsonValue :: [Scenario] -> TestTree
everyLineIsOneJsonValue scenarios =
    testCase "every corpus line is one JSON value" $
        mapM_ checkScenario [s | s <- scenarios, scenarioName s `notElem` parseExempt]
  where
    checkScenario s = mapM_ (checkFile (scenarioName s)) ["host.jsonl", "plugin.jsonl"]
    checkFile name file = do
        contents <- BS.readFile (corpusRoot </> name </> file)
        mapM_ (checkLine name file) (zip [1 :: Int ..] (nonEmptyLines contents))
    checkLine name file (lineNo, line) =
        unless (isJsonValue line) $
            assertFailure (corpusRoot </> name </> file <> ":" <> show lineNo <> " is not one JSON value")
    isJsonValue line = case decodeStrict line :: Maybe Value of
        Just _ -> True
        Nothing -> False

everyExpectedNamesAPhase :: [Scenario] -> TestTree
everyExpectedNamesAPhase scenarios =
    testCase "every EXPECTED.md names an owning phase" $
        case [scenarioName s | s <- scenarios, not (namesAPhase (scenarioExpected s))] of
            [] -> pure ()
            bad -> assertFailure ("EXPECTED.md without an owning phase: " <> show bad)
  where
    namesAPhase Nothing = True
    namesAPhase (Just headline) =
        "Phase" `elem` ws && any (`elem` map show [2 :: Int .. 7]) ws
      where
        ws = words headline

manifestDeclaresEveryContribution :: TestTree
manifestDeclaresEveryContribution =
    testCase "handshake manifest declares tools, guards, sections, subagents" $ do
        manifest <- readManifest
        case filter (\k -> not (KM.member k manifest)) contributionKeys of
            [] -> pure ()
            missing -> assertFailure ("manifest is missing keys: " <> show missing)
  where
    contributionKeys :: [Key]
    contributionKeys = ["tools", "guards", "sections", "subagents"]

{- | PROTOCOL.md section 4 freezes tool names to @\/^[A-Za-z0-9_-]{1,64}$\/@.
This asserts the corpus obeys the rule it documents.
-}
manifestToolNamesAreWellFormed :: TestTree
manifestToolNamesAreWellFormed =
    testCase "every manifest tool name matches the frozen character set" $ do
        manifest <- readManifest
        case KM.lookup "tools" manifest of
            Just (Array tools) ->
                case filter (not . wellFormedToolName) (map toolName (toList tools)) of
                    [] -> pure ()
                    bad -> assertFailure ("malformed tool names: " <> show bad)
            _ -> assertFailure "handshake manifest carries no tools array"
  where
    toolName (Object tool) = case KM.lookup "name" tool of
        Just (String n) -> n
        _ -> ""
    toolName _ = ""

-- | The character set and length bound PROTOCOL.md section 4 freezes.
wellFormedToolName :: Text -> Bool
wellFormedToolName n =
    not (T.null n) && T.length n <= 64 && T.all ok n
  where
    ok c = isAsciiUpper c || isAsciiLower c || isDigit c || c == '_' || c == '-'

-- | The @result@ object of the first frame of @corpus\/handshake\/plugin.jsonl@.
readManifest :: IO (KM.KeyMap Value)
readManifest = do
    contents <- BS.readFile (corpusRoot </> "handshake" </> "plugin.jsonl")
    case nonEmptyLines contents of
        [] -> assertFailure "corpus/handshake/plugin.jsonl has no frames"
        (frame : _) -> case decodeStrict frame :: Maybe Value of
            Just (Object obj) -> case KM.lookup "result" obj of
                Just (Object manifest) -> pure manifest
                _ -> assertFailure "handshake frame carries no object result"
            _ -> assertFailure "handshake frame is not a JSON object"

nonEmptyLines :: BS.ByteString -> [BS.ByteString]
nonEmptyLines = filter (not . BS.null) . BS.lines
