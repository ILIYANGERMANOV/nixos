-- | Each refusal's code: one per constructor, stable, never @other@.
module State.Cli.CodeSpec (spec) where

import Data.Char (isAsciiLower)
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import State.Category.Graph (Node (..), OpenGraph (..))
import State.Category.Step (EventName (..), OutcomeName (..))
import State.Cli.Command (CommandRefusal (..), refusalCode)
import State.Cli.Query (SqlRefusal (..))
import State.Golden (golden)
import State.Role (Rung (..))
import State.Run.Ask (Above (..), Kind (..), QId (..), Reply (..))
import State.Run.Ask qualified as Ask
import State.Run.Epic qualified as Epic
import State.Run.Event (
    RefusalCode (..),
    RunId,
    SpanId (..),
    StateName (..),
    Stop (..),
    StopReason (..),
    TaskId (..),
    TaskNo (..),
 )
import State.Run.EventGen (absolutePath, epicNamed, oneLine, runId)
import State.Run.Fan qualified as Fan
import State.Run.Fold (Refusal (..))
import State.Run.Gap qualified as Gap
import State.Run.Id (EventRef (..))
import State.Run.RunGen (g)
import State.Step.Artifact (EpicName, Url (..))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "refusalCode" $ do
    it "names each refusal constructor by its code" $
        golden
            "refusal-codes.txt"
            (Text.unlines (map ((.codeText) . refusalCode) samples))

    it "gives no two constructors the same code" $
        let codes = map refusalCode samples in nub codes `shouldBe` codes

    it "never names a refusal other" $
        map refusalCode samples `shouldSatisfy` notElem (RefusalCode "other")

    it "spells every code in snake_case" $
        map ((.codeText) . refusalCode) samples
            `shouldSatisfy` all (Text.all (\c -> isAsciiLower c || c == '_'))

    it "gives a wrapped refusal its inner code" $
        map
            refusalCode
            [ FoldRefused (NotAllowed (Ask.NoBasis qid))
            , FoldRefused (FanRefused (Fan.AtWork task))
            ]
            `shouldBe` [RefusalCode "no_basis", RefusalCode "at_work"]

    it "names a void that breaks the log void_breaks, whatever it breaks" $
        refusalCode (FoldRefused (VoidBreaks 3 (FanRefused (Fan.UnknownTask task))))
            `shouldBe` RefusalCode "void_breaks"

{- | One refusal per constructor, in declaration order. A constructor added
without a sample here goes unchecked for a distinct code: the no-@_@ case of
'refusalCode' proves only that it has one.
-}
samples :: [CommandRefusal]
samples =
    map FoldRefused folds
        <> [ FileUnreadable (absolutePath "/work/gone.md")
           , UnknownEvent (EventRef run 9)
           , OutsideRunTree (EventRef run 10) (runId "a1b2")
           , SqlRefused SqlNotReadOnly
           , SqlRefused SqlNotOneStatement
           , SqlRefused (SqlError "no such table: nope")
           ]
  where
    folds =
        [ NotStarted
        , StartedTwice
        , OtherRun run
        , AfterStop (Stop Blocked "why")
        , NoEdge Out (EventName (StateName "plan") (OutcomeName "done"))
        , NotSkippable "engineer/ready"
        , OutOfBudget cap 3
        , StillOpen 2
        , NothingToExtend
        , TargetOffFuel
        , NoSingleState (StateName "nowhere")
        , AskedTwice qid
        , NotPending qid
        , AlreadyForwarded qid
        , NotForwarded qid
        , IsParked qid
        , AnsweredOtherwise qid (Chose "yes")
        , NotAllowed (Ask.MayNotRule Lead Design)
        , NotAllowed (Ask.MustAnswer Worker Fact)
        , NotAllowed (Ask.NeverAskedOf User Stuck)
        , NotAllowed (Ask.NoBasis qid)
        , NotAbove TheUser
        , FanRefused (Fan.UnknownTask task)
        , FanRefused (Fan.StillRunning task run)
        , FanRefused (Fan.SpawnedTwice run)
        , FanRefused (Fan.UnknownChild run)
        , FanRefused (Fan.ChildOver run)
        , FanRefused (Fan.Unsettled (task :| []))
        , FanRefused (Fan.AtWork task)
        , FanRefused (Fan.StopUntriaged run)
        , FanRefused (Fan.AwaitsUser run)
        , FanRefused (Fan.Busy (task :| []))
        , FanRefused (Fan.Unmerged (task :| []))
        , FanRefused (Fan.NotARound task)
        , FanRefused (Fan.NotItsRound task (Url "https://github.com/o/r/pull/7"))
        , FanRefused (Fan.TaskExists task)
        , FanRefused (Fan.TaskMerged task (Url "https://github.com/o/r/pull/7"))
        , FanRefused (Fan.TaskCycle (task :| []))
        , NotAtFan
        , NotOneHolder task
        , NotVoidable 4
        , VoidBreaks 4 NotStarted
        , NoFocus
        , NotInFocus (TaskNo 1)
        , NotSuspended (TaskNo 1)
        , FocusRecorded (TaskNo 1)
        , UnknownGap 5
        , GapClosed 5 (Gap.WontFix (oneLine "out of scope"))
        , SpanNotOpen (SpanId 6)
        , EpicRefused (Epic.EpicExists epic)
        , EpicRefused (Epic.EpicNotOpen epic)
        , EpicRefused (Epic.EpicNotReady epic)
        , EpicRefused (Epic.UnknownEpic epic)
        , NoActiveInstruction 7
        , NoOpenNeed 8
        ]
    cap = case Map.elems g.caps of
        first : _ -> first
        [] -> error "the engineer's graph has no cap"

run :: RunId
run = runId "r7f2"

qid :: QId
qid = QId run 2

task :: TaskId
task = TaskId "t1"

epic :: EpicName
epic = epicNamed "auth"
