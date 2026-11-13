-- | Generators of log lines, and builders of a run's log for the fold's specs.
module State.Run.EventGen (
    genEnvelope,
    genOutcomeNamed,
    outcomeNames,
    genPicks,
    genRunId,
    genQId,
    genQuestion,
    genReading,
    genProposal,
    genBasis,
    genText,
    genOneLine,
    genTasks,
    genTaskId,
    genSaid,
    genTaskState,
    tasksOf,
    oneLine,
    runId,
    run,
    start,
    started,
    genStart,
    line,
    lineOf,
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
import Data.Text qualified as Text
import Data.Time (UTCTime (..), addUTCTime, picosecondsToDiffTime)
import Data.Time.Calendar (Day (..))
import Hedgehog (Gen)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Numeric.Natural (Natural)
import State.Category.Flow (FanId (..))
import State.Category.Mode (Quality (..), Size (..))
import State.Category.Step (EventName)
import State.Run.Ask (Above (..), Basis (..), Choice (..), OneLine, Proposal (..), QId (..), Question (..), Reading (..), parseOneLine)
import State.Run.Event
import State.Run.Id (breaksLine, parseEventId)

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
        , Asked <$> (Asking <$> genQuestion <*> (StateName <$> genText) <*> genAsker)
        , RetaggedSecurity <$> genQId
        , RuledOn <$> genQId <*> genProposal
        , Forwarded <$> genQId <*> genAbove
        , Answered <$> genQId <*> genText <*> genAbove
        , Spawning <$> genTaskId
        , Spawned <$> (Child <$> genRunId <*> genTaskId <*> genPath <*> genPath)
        , Resumed <$> genRunId
        , HandedBack <$> genRunId <*> genSaid
        , TaskMoved <$> genTaskId <*> genTaskState
        , Held <$> genTaskId <*> (Url <$> genText)
        , ActedOn <$> genTaskId <*> (Url <$> genText)
        , WorkerHandedBack . AgentRole <$> genText <*> genOneLine
        ]

genPath :: Gen FilePath
genPath = Gen.string (Range.linear 1 30) Gen.unicode

genSaid :: Gen Said
genSaid =
    Gen.choice
        [ Finished <$> genOneLine
        , AsksUp <$> genQId
        , AwaitsCi <$> genOneLine
        , Ended <$> (Stop <$> Gen.enumBounded <*> genText)
        ]

genTaskState :: Gen TaskState
genTaskState =
    Gen.choice
        [ InCi . Url <$> genText
        , InReview . Url <$> genText
        , Merged . Url <$> genText
        , Parked <$> genText <*> Gen.maybe (Url <$> genText)
        ]

-- | Few ids, so tasks, children and moves name the same ones often.
genTaskId :: Gen TaskId
genTaskId = TaskId <$> Gen.element ["t1", "t2", "t3", "t4", "t5"]

{- | A breakdown of up to five tasks, @t1@ to @tn@, each depending on some
earlier ones.
-}
genTasks :: Gen Tasks
genTasks = do
    n <- Gen.int (Range.linear 1 5)
    tasks <- traverse genTaskAt [1 .. n]
    pure (tasksOf (NonEmpty.fromList tasks))
  where
    genTaskAt :: Int -> Gen Task
    genTaskAt i =
        Task (taskNamed i)
            <$> Gen.subsequence (map taskNamed [1 .. i - 1])
            <*> (Branch <$> genText)
            <*> (Branch <$> genText)
            <*> Gen.enumBounded
            <*> Gen.enumBounded
            <*> Gen.bool
            <*> Gen.bool
            <*> genSet Gen.enumBounded
    taskNamed i = TaskId ("t" <> Text.pack (show i))

-- | A breakdown the test spells, which must be one 'breakdown' accepts.
tasksOf :: NonEmpty Task -> Tasks
tasksOf = either (error . show) id . breakdown

genAsker :: Gen Asker
genAsker = Gen.choice [pure Itself, Subagent . AgentRole <$> genText, ChildRun <$> genRunId]

genAbove :: Gen Above
genAbove = Gen.choice [pure TheUser, ParentRun <$> genRunId]

genStart :: Gen Start
genStart =
    Start
        <$> Gen.enumBounded
        <*> Gen.string (Range.linear 1 30) Gen.unicode
        <*> Gen.choice [pure ByUser, fmap ByRole $ Parent <$> genRunId <*> Gen.string (Range.linear 1 30) Gen.unicode <*> genTaskId]
        <*> genSet Gen.enumBounded

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
    , BreakdownDone (tasksOf (Task (TaskId "t1") [] (Branch "") (Branch "") Balanced Normal False False Set.empty :| []))
    , FanDone FEngineers
    , MergeDone (Url "")
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
    BreakdownDone _ -> BreakdownDone <$> genTasks
    FanDone fan -> pure (FanDone fan)
    MergeDone _ -> MergeDone . Url <$> genText

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

genOneLine :: Gen OneLine
genOneLine = Gen.mapMaybe parseOneLine genText

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
genRunId = Gen.mapMaybe parseRunId genIdText

{- | Raw id text, often with a line break, so a property sees whether the id
parsers refuse one: 'Gen.unicode' alone almost never draws one.
-}
genIdText :: Gen Text
genIdText = Gen.text (Range.linear 1 8) (Gen.frequency [(9, Gen.unicode), (1, Gen.element lineBreaks)])

lineBreaks :: [Char]
lineBreaks = filter breaksLine [minBound .. maxBound]

genQId :: Gen QId
genQId = QId <$> genRunId <*> Gen.integral (Range.linear 0 1000)

genQuestion :: Gen Question
genQuestion = Question <$> genQId <*> Gen.enumBounded <*> genOneLine

-- | Any reading: a kind and a choice.
genReading :: Gen Reading
genReading = Reading <$> Gen.enumBounded <*> Gen.choice [RuleOn <$> genProposal, pure PassOn]

genProposal :: Gen Proposal
genProposal = Proposal <$> genOneLine <*> genOneLine <*> genOneLine <*> Gen.maybe genBasis

genBasis :: Gen Basis
genBasis = Gen.choice [AnsweredBy <$> genEventId, Obvious <$> genOneLine]

genEventId :: Gen EventId
genEventId =
    Gen.choice
        [ Numbered <$> genRunId <*> Gen.integral (Range.linear 0 1000)
        , Gen.mapMaybe (parseEventId . ("h:" <>)) genIdText
        ]

-- | A line the test spells, which must hold no line break.
oneLine :: Text -> OneLine
oneLine raw = fromMaybe (error ("not one line: " <> show raw)) (parseOneLine raw)

-- | A run id the test spells, which must be one the kernel accepts.
runId :: Text -> RunId
runId raw = fromMaybe (error ("not a run id: " <> show raw)) (parseRunId raw)

run :: RunId
run = runId "r7f2"

-- | A user's engineer run, in a session that can ask the user.
start :: Start
start = Start EngineerFlow "notes" ByUser (Set.fromList [AskUser, Hooks])

started :: Event
started = Started start

-- | A CLI line of 'run', at its seq.
line :: Natural -> Event -> Envelope
line = lineOf run

-- | A CLI line of this run, at its seq.
lineOf :: RunId -> Natural -> Event -> Envelope
lineOf ofRun n = Envelope Cli n (addUTCTime (fromIntegral n) epoch) ofRun Nothing Nothing
  where
    epoch = UTCTime (ModifiedJulianDay 61000) 0

-- | A hook's line: its id is the digest, whatever its seq.
hookLine :: Text -> Natural -> Event -> Envelope
hookLine digest n event = (line n event) {source = Hook (Digest digest)}

-- | A log of these events, numbered from 0.
logOf :: NonEmpty Event -> NonEmpty Envelope
logOf = NonEmpty.zipWith line (0 :| [1 ..])
