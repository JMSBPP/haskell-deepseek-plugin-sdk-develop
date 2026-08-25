{-# LANGUAGE DeriveAnyClass #-}

{- |
The four property families named in the phase context, written now as
signatures whose bodies cannot hold and filled in by the phase that owns
each one. Every property is wrapped in 'expectFailBecause', so the phase
that implements it must also delete the wrapper.
-}
module Conformance.Properties (tests) where

import Data.Kind (Type)
import GHC.Generics (Generic)

import Hedgehog
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.ExpectedFailure (expectFailBecause)
import Test.Tasty.Hedgehog (testProperty)

-- | The property families, all red until their owning phase lands.
tests :: TestTree
tests =
    testGroup
        "properties"
        [ codecRoundTrip
        , hostileFrameTotality
        , schemaSubsetClosure
        , cancellationOrdering
        ]

{- | Phase 2 and Phase 5: @decode . encode == id@ for every envelope and
manifest type.
-}
codecRoundTrip :: TestTree
codecRoundTrip =
    expectFailBecause "Phase 2/5 own codec round-trips" $
        testProperty "decode . encode == id" . property $ do
            n <- forAll (Gen.int (Range.linear 0 100))
            n === n + 1

{- | Phase 2: any ByteString line yields a frame or a @-32700@ error frame, and
never an exception.
-}
hostileFrameTotality :: TestTree
hostileFrameTotality =
    expectFailBecause "Phase 2 owns hostile-frame totality" $
        testProperty "any line yields a frame or -32700" . property $ do
            line <- forAll (Gen.string (Range.linear 0 64) Gen.unicode)
            assert (length line < 0)

{- | Phase 4: every derived @DshSchema@ passes the Haskell port of the
harness's @assertSupportedJsonSchema@.
-}
schemaSubsetClosure :: TestTree
schemaSubsetClosure =
    expectFailBecause "Phase 4 owns schema subset closure"
        $ testProperty "every DshSchema passes assertSupportedJsonSchema" . property
        $ assert False

{- | Phase 3: a state machine over request \/ @$\/cancel@ \/ response
interleavings. Phase 3 replaces the model and the command, not the plumbing.
-}
cancellationOrdering :: TestTree
cancellationOrdering =
    expectFailBecause "Phase 3 owns cancellation ordering" $
        testProperty "no leaked waiters; late cancels are no-ops" . property $ do
            actions <- forAll (Gen.sequential (Range.linear 1 10) (ModelState 0) [issueCommand])
            executeSequential (ModelState 0) actions

{- | Placeholder model state. The @v@ parameter must stay phantom so the state
can be passed to 'Gen.sequential' at @forall v. state v@.
-}
newtype ModelState (v :: Type -> Type) = ModelState Int

{- | Placeholder command input. @hedgehog >= 1.5@ requires 'FunctorB' and
'TraversableB' from @barbies@ here; the @HTraversable@ class every older
tutorial uses is deprecated and does not satisfy 'Command'.
-}
data Issue (v :: Type -> Type) = Issue
    deriving (Eq, Show, Generic)
    deriving anyclass (FunctorB, TraversableB)

issueCommand :: Command Gen (PropertyT IO) ModelState
issueCommand =
    Command
        (const (Just (pure Issue)))
        (\Issue -> pure ())
        [ Update (\(ModelState n) _ _ -> ModelState (n + 1))
        , Ensure (\_ (ModelState n) _ () -> footnote "Phase 3 owns this model" >> assert (n < 0))
        ]
