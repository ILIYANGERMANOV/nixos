-- | Generators of log lines, and builders of a run's log for the fold's specs.
module State.EventGen (
    genEnvelope,
    genOutcomeNamed,
    outcomeNames,
    genPicks,
    genRunId,
    genQId,
    genQuestion,
    genReading,
    genProposal,
    runId,
    run,
    started,
    line,
    hookLine,
    logOf,
) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime (..), addUTCTime, picosecondsToDiffTime)
import Data.Time.Calendar (Day (..))
import Hedgehog (Gen)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Numeric.Natural (Natural)
import State.Ask (Basis (..), Choice (..), Proposal (..), QId (..), Question (..), Reading (..))
import State.Cap (EventName)
import State.Event

genEnvelope :: Gen Envelope
genEnvelope =
    Envelope
        <$> Gen.choice [pure Cli, Hook <$> genDigest]
        <*> Gen.integral (Range.linear 0 100000)
        <*> genTime
        <*> genRunId
        <*> Gen.maybe genSha
        <*> Gen.maybe (SessionId <$> genText)
        <*> genEvent

genEvent :: Gen Event
genEvent =
    Gen.choice
        [ Started <$> genStart
        , QualitySet <$> Gen.enumBounded
        , SizeSet <$> Gen.enumBounded
        , Grew <$> genText
        , Took <$> (Gen.element templates >>= like)
        , Stopped <$> (Stop <$> Gen.enumBounded <*> genText)
        , Overridden . StateName <$> genText <*> genText
        , Refused <$> (Note <$> genText <*> genText)
        ]

genStart :: Gen Start
genStart =
    Start
        <$> Gen.enumBounded
        <*> Gen.string (Range.linear 1 30) Gen.unicode
        <*> Gen.choice [pure ByUser, ByRole <$> genRunId <*> Gen.string (Range.linear 1 30) Gen.unicode]
        <*> genSet Gen.enumBounded
        <*> genText

-- | An outcome taking this edge, if the edge is one of the engineer flow's.
genOutcomeNamed :: EventName -> Maybe (Gen Outcome)
genOutcomeNamed name = case filter ((== name) . outcomeEvent) templates of
    [] -> Nothing
    named -> Just (Gen.element named >>= like)

-- | The edge every outcome takes.
outcomeNames :: Set EventName
outcomeNames = Set.fromList (map outcomeEvent templates)

-- | One of each outcome; 'like' fills in its data.
templates :: [Outcome]
templates =
    [ ResearchDone 0
    , ResearchSkipped
    , InterviewEnough
    , InterviewMore
    , PlanDone ""
    , SimplifyPlanDone
    , SimplifyPlanSkipped
    , AlternativeDone
    , AlternativeSkipped
    , ConfirmConfirmed
    , ConfirmAdjusted
    , DraftDone (DraftPr (Url "") (Branch "") (Branch ""))
    , ImplementDone (Commit (Sha "") Set.empty)
    , RefactorDone (Sha "")
    , RefactorSkipped ""
    , ReviewClean (Sha "")
    , ReviewRows (Sha "")
    , PickFinal (Picks Set.empty Map.empty)
    , PickLoop (Picks Set.empty Map.empty)
    , FixDone (Commit (Sha "") Set.empty)
    , DescribeDone (Sha "")
    , SimplifyPrDone (Sha "")
    , SimplifyPrSkipped (Sha "")
    , AwaitCiGreen (Sha "")
    , AwaitCiRed (Sha "") (Check "" :| [])
    , FixPrDone (Sha "")
    , ReadyDone (Url "")
    , ReadySkipped (Url "")
    ]

-- | The same outcome, with generated data.
like :: Outcome -> Gen Outcome
like = \case
    ResearchDone _ -> ResearchDone <$> Gen.integral (Range.linear 0 6)
    ResearchSkipped -> pure ResearchSkipped
    InterviewEnough -> pure InterviewEnough
    InterviewMore -> pure InterviewMore
    PlanDone _ -> PlanDone <$> Gen.string (Range.linear 1 30) Gen.unicode
    SimplifyPlanDone -> pure SimplifyPlanDone
    SimplifyPlanSkipped -> pure SimplifyPlanSkipped
    AlternativeDone -> pure AlternativeDone
    AlternativeSkipped -> pure AlternativeSkipped
    ConfirmConfirmed -> pure ConfirmConfirmed
    ConfirmAdjusted -> pure ConfirmAdjusted
    DraftDone _ -> DraftDone <$> (DraftPr . Url <$> genText <*> (Branch <$> genText) <*> (Branch <$> genText))
    ImplementDone _ -> ImplementDone <$> genCommit
    RefactorDone _ -> RefactorDone <$> genSha
    RefactorSkipped _ -> RefactorSkipped <$> genText
    ReviewClean _ -> ReviewClean <$> genSha
    ReviewRows _ -> ReviewRows <$> genSha
    PickFinal _ -> PickFinal <$> genPicks
    PickLoop _ -> PickLoop <$> genPicks
    FixDone _ -> FixDone <$> genCommit
    DescribeDone _ -> DescribeDone <$> genSha
    SimplifyPrDone _ -> SimplifyPrDone <$> genSha
    SimplifyPrSkipped _ -> SimplifyPrSkipped <$> genSha
    AwaitCiGreen _ -> AwaitCiGreen <$> genSha
    AwaitCiRed _ _ -> AwaitCiRed <$> genSha <*> Gen.nonEmpty (Range.linear 1 3) (Check <$> Gen.element ["lint", "test", "build"])
    FixPrDone _ -> FixPrDone <$> genSha
    ReadyDone _ -> ReadyDone . Url <$> genText
    ReadySkipped _ -> ReadySkipped . Url <$> genText

-- | Few labels and requirements, so rounds share them often.
genPicks :: Gen Picks
genPicks =
    Picks
        <$> genSet (Label <$> Gen.element ["A", "B", "C"])
        <*> (Map.fromList <$> Gen.list (Range.linear 0 2) ((,) . Requirement <$> Gen.element ["R1", "R2"] <*> Gen.enumBounded))

genCommit :: Gen Commit
genCommit = Commit <$> genSha <*> genSet Gen.enumBounded

genSha :: Gen Sha
genSha = Sha <$> Gen.text (Range.linear 7 40) Gen.hexit

genDigest :: Gen Digest
genDigest = Digest <$> Gen.text (Range.singleton 64) Gen.hexit

genText :: Gen Text
genText = Gen.text (Range.linear 0 20) Gen.unicode

genSet :: (Ord a) => Gen a -> Gen (Set a)
genSet = fmap Set.fromList . Gen.list (Range.linear 0 4)

-- | Any instant, to the picosecond.
genTime :: Gen UTCTime
genTime =
    UTCTime . ModifiedJulianDay
        <$> Gen.integral (Range.linear 40000 80000)
        <*> (picosecondsToDiffTime <$> Gen.integral (Range.linear 0 (86400 * 1000000000000 - 1)))

-- | Any run id the kernel accepts.
genRunId :: Gen RunId
genRunId = Gen.mapMaybe parseRunId (Gen.text (Range.linear 1 8) Gen.unicode)

genQId :: Gen QId
genQId = QId <$> genRunId <*> Gen.integral (Range.linear 0 1000)

genQuestion :: Gen Question
genQuestion = Question <$> genQId <*> Gen.enumBounded <*> genText

-- | Any reading: a kind, often the question's own, and a choice.
genReading :: Gen Reading
genReading = Reading <$> Gen.enumBounded <*> Gen.choice [RuleOn <$> genProposal, pure PassOn]

genProposal :: Gen Proposal
genProposal = Proposal <$> genText <*> genText <*> genText <*> Gen.maybe genBasis

genBasis :: Gen Basis
genBasis = Gen.choice [AnsweredBy <$> genEventId, Obvious <$> genText]

genEventId :: Gen EventId
genEventId = Gen.choice [Numbered <$> genRunId <*> Gen.integral (Range.linear 0 1000), Hashed <$> genDigest]

-- | A run id the test spells, which must be one the kernel accepts.
runId :: Text -> RunId
runId raw = fromMaybe (error ("not a run id: " <> show raw)) (parseRunId raw)

run :: RunId
run = runId "r7f2"

started :: Event
started = Started (Start EngineerFlow "notes" ByUser (Set.fromList [AskUser, Hooks]) "a task")

-- | A CLI line of 'run', at its seq.
line :: Natural -> Event -> Envelope
line n = Envelope Cli n (addUTCTime (fromIntegral n) epoch) run Nothing Nothing
  where
    epoch = UTCTime (ModifiedJulianDay 61000) 0

-- | A hook's line: its id is the digest, whatever its seq.
hookLine :: Text -> Natural -> Event -> Envelope
hookLine digest n event = (line n event) {source = Hook (Digest digest)}

-- | A log of these events, numbered from 0.
logOf :: NonEmpty Event -> NonEmpty Envelope
logOf = NonEmpty.zipWith line (0 :| [1 ..])
