module State.Run.EpicSpec (spec) where

import Control.Monad (foldM)
import Data.Foldable (for_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Hedgehog (cover, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Run.Epic
import State.Run.EventGen (epicNamed, genEpicMove)
import State.Step.Artifact (
    Base (..),
    Branch (..),
    EpicName,
    Repo (..),
    TaskId (..),
    Url (..),
 )
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Run.Epic" $ do
    {- Appendix B's epic table, every cell: from no epic, open, ready or
    merged, each move gives its stage or its refusal. -}
    describe "takes the epic table's edges and refuses every other move" $
        for_ table $ \(from, move, expected) ->
            it (show (stageName <$> from) <> " then " <> show move) $
                (stageName <$> (moved limits move (at from) >>= found))
                    `shouldBe` expected

    it "takes no move but a listed edge, over any sequence of moves" $ hedgehog $ do
        moves <-
            forAll
                ( Gen.list
                    (Range.linear 0 20)
                    ((,) <$> Gen.element [limits, epicNamed "auth"] <*> genEpicMove)
                )
        final <-
            foldM
                ( \epics (name, move) -> case moved name move epics of
                    Right after -> do
                        -- One epic moved, along its listed edge.
                        Map.delete name after === Map.delete name epics
                        (stageName <$> Map.lookup name after)
                            === Just (listed (stageName <$> Map.lookup name epics) move)
                        pure after
                    Left _ -> pure epics
                )
                Map.empty
                moves
        -- The last edge was taken, so the property is not passed by refusals alone.
        cover 5 "an epic merged" ("merged" `elem` map stageName (Map.elems final))

    describe "names only an opened epic in a base" $ do
        it "takes an epic opened at any stage" $
            opened (at (Just merged')) (OnEpic limits) `shouldBe` Right ()
        it "refuses an epic never opened" $
            opened Map.empty (OnEpic limits) `shouldBe` Left (UnknownEpic limits)
        it "takes the default branch and a task's" $
            traverse (opened Map.empty) [OnDefault, OnTask (TaskId "t1")]
                `shouldBe` Right [(), ()]
  where
    found = maybe (Left (UnknownEpic limits)) Right . Map.lookup limits

limits :: EpicName
limits = epicNamed "limits"

repo :: Repo
repo = Repo "o" "r"

branch :: Branch
branch = Branch "epic/limits"

pr :: Url
pr = Url "https://github.com/o/r/pull/40"

open', ready', merged' :: Epic
open' = Open (OpenEpic repo branch)
ready' = Ready (ready (OpenEpic repo branch) pr)
merged' = Merged (merge (ready (OpenEpic repo branch) pr))

-- | The run's epics: @limits@ at this stage, or none.
at :: Maybe Epic -> Map EpicName Epic
at = maybe Map.empty (Map.singleton limits)

-- | Each cell: the stage before, the move, and the stage after or the refusal.
table :: [(Maybe Epic, EpicMove, Either Refusal Text)]
table =
    [ (Nothing, Opens repo branch, Right "open")
    , (Nothing, Readies pr, Left (UnknownEpic limits))
    , (Nothing, Merges, Left (UnknownEpic limits))
    , (Just open', Opens repo branch, Left (EpicExists limits))
    , (Just open', Readies pr, Right "ready_for_review")
    , (Just open', Merges, Left (EpicNotReady limits))
    , (Just ready', Opens repo branch, Left (EpicExists limits))
    , (Just ready', Readies pr, Left (EpicNotOpen limits))
    , (Just ready', Merges, Right "merged")
    , (Just merged', Opens repo branch, Left (EpicExists limits))
    , (Just merged', Readies pr, Left (EpicNotOpen limits))
    , (Just merged', Merges, Left (EpicNotReady limits))
    ]

-- | The stage a listed edge leads to, from the stage before it.
listed :: Maybe Text -> EpicMove -> Text
listed from move = case (from, move) of
    (Nothing, Opens _ _) -> "open"
    (Just "open", Readies _) -> "ready_for_review"
    (Just "ready_for_review", Merges) -> "merged"
    _ -> "no listed edge"
