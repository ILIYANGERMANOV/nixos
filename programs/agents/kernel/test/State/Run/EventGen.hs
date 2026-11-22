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
    genReply,
    genText,
    genOneLine,
    genTasks,
    genTaskAt,
    genTaskId,
    genSaid,
    genTaskState,
    tasksOf,
    oneLine,
    runId,
    run,
    start,
    started,
    fuelSet,
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
import State.Category.FlowGen (genScopePath)
import State.Category.Fuel (Fuel (..))
import State.Category.Step (EventName, Outcome, SomeOutcome (..))
import State.Flow.Drawn (drawnOutcomes)
import State.Run.Ask (
    Above (..),
    Basis (..),
    Decision (..),
    OneLine,
    Proposal (..),
    QId (..),
    Question (..),
    Reading (..),
    parseOneLine,
 )
import State.Run.Event
import State.Run.Id (breaksLine, parseEventId)
import State.Step.Artifact (ShellPath, shellPath)
import State.Step.Build (Outcome (..))
import State.Step.Catalog (AnyOutcome (..), Layer (..), outcome, outcomeEvent)
import State.Step.Fan (Outcome (..), fanOuts)
import State.Step.Fuel (Outcome (..))
import State.Step.Gather (Outcome (..))
import State.Step.Pick qualified as Pick
import State.Step.Plan (Outcome (..))
import State.Step.Request (Outcome (..))
import State.Step.Review (Outcome (..))
import State.Step.Ship (Outcome (..))
import State.Step.Ticket (Outcome (..))

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
        , Targeted <$> genTarget
        , Extended <$> genText
        , Gapped <$> genText
        , Took <$> genScopePath <*> (Gen.element templates >>= like)
        , Stopped <$> (Stop <$> Gen.enumBounded <*> genText)
        , Overridden . StateName <$> genText <*> genText
        , Refused <$> (Note <$> genText <*> genText)
        , Asked <$> (Asking <$> genQuestion <*> (StateName <$> genText) <*> genAsker)
        , RetaggedSecurity <$> genQId
        , RuledOn <$> genQId <*> genProposal
        , Forwarded <$> genQId <*> genAbove
        , Answered <$> genQId <*> genReply <*> genAbove
        , QuestionParked <$> genQId <*> genOneLine
        , Spawning <$> genTaskId
        , Spawned
            <$> ( Child
                    <$> genRunId
                    <*> Gen.choice [Tasked <$> genTaskId, pure Untasked]
                    <*> genPath
                )
        , Resumed <$> genRunId
        , HandedBack <$> genRunId <*> genSaid
        , TaskMoved <$> genTaskId <*> genTaskState
        , Held <$> genTaskId <*> (Url <$> genText)
        , ActedOn <$> genTaskId <*> (Url <$> genText)
        , TaskAdded <$> (Gen.int (Range.linear 1 6) >>= genTaskAt)
        , pure Restarted
        , WorkerHandedBack . AgentRole <$> genText <*> genOneLine
        , WorkerSpawned . AgentRole <$> genText <*> (AgentId <$> genText)
        , WorkerReturned . AgentRole <$> genText <*> Gen.maybe (AgentId <$> genText)
        , AgentEnded . AgentId <$> genText
        , Suspended <$> genTaskNo <*> genOneLine
        , Focused <$> genTaskNo
        , Voided <$> Gen.integral (Range.linear 0 100000) <*> genText
        ]

genPath :: Gen FilePath
genPath = Gen.string (Range.linear 1 30) Gen.unicode

genSaid :: Gen Said
genSaid =
    Gen.choice
        [ Finished <$> genOneLine
        , AsksUp <$> genQId
        , Awaits <$> Gen.enumBounded <*> genOneLine
        , Ended <$> (Stop <$> Gen.enumBounded <*> genText)
        ]

genTaskState :: Gen TaskState
genTaskState =
    Gen.choice
        [ InCi . Url <$> genText
        , InReview . Url <$> genText
        , Merged . Url <$> genText
        , Kept . Url <$> genText
        , Round . Url <$> genText
        , Parked <$> genText <*> Gen.maybe (Url <$> genText)
        ]

-- | Few ids, so tasks, children and moves name the same ones often.
genTaskNo :: Gen TaskNo
genTaskNo = TaskNo <$> Gen.integral (Range.linear 1 50)

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

-- | The task @ti@, depending on some of @t1@ to the one before it.
genTaskAt :: Int -> Gen Task
genTaskAt i =
    Task (taskNamed i)
        <$> Gen.subsequence (map taskNamed [1 .. i - 1])
        <*> (Branch <$> genText)
        <*> (Branch <$> genText)
        <*> Gen.enumBounded
        <*> Gen.bool
        <*> Gen.bool
        <*> genSet Gen.enumBounded
        <*> genShape
        <*> Gen.enumBounded
        <*> Gen.maybe genRepo
        <*> Gen.maybe genWorktree
        <*> Gen.enumBounded
  where
    taskNamed n = TaskId ("t" <> Text.pack (show n))

-- | An @OWNER/REPO@, each side a word.
genRepo :: Gen Repo
genRepo = Repo <$> part <*> part
  where
    part = Gen.text (Range.linear 1 10) (Gen.element ['a', 'Z', '0', '-', '.', '_'])

-- | An absolute path of the characters a shell reads as none of its syntax.
genWorktree :: Gen ShellPath
genWorktree =
    Gen.mapMaybe
        (shellPath . ('/' :))
        (Gen.string (Range.linear 0 20) (Gen.element ("aZ09._/@+-" :: String)))

genShape :: Gen Shape
genShape = Gen.choice [pure OwnPr, RoundOn . Url <$> genText]

genTarget :: Gen Target
genTarget =
    Gen.choice
        [ OnPr . Url <$> genText
        , OnBranch . Branch <$> genText
        , OnTicket . Url <$> genText
        ]

-- | A breakdown the test spells, which must be one 'breakdown' accepts.
tasksOf :: NonEmpty Task -> Tasks
tasksOf = either (error . show) id . breakdown

genAsker :: Gen Asker
genAsker =
    Gen.choice
        [pure Itself, Subagent . AgentRole <$> genText, ChildRun <$> genRunId]

genAbove :: Gen Above
genAbove = Gen.choice [pure TheUser, ParentRun <$> genRunId, pure TheCaller]

genStart :: Gen Start
genStart =
    Start
        <$> Gen.enumBounded
        <*> Gen.string (Range.linear 1 30) Gen.unicode
        <*> Gen.choice
            [ ByUser <$> genShape
            , ByRole
                <$> ( Parent
                        <$> genRunId
                        <*> Gen.choice
                            [InFan <$> Gen.choice [Tasked <$> genTaskId, pure Untasked], pure Direct]
                    )
                <*> genShape
                <*> Gen.enumBounded
            , ByCaller <$> genShape
            ]
        <*> genSet Gen.enumBounded

-- | An outcome taking this edge, if the edge is one of the engineer flow's.
genOutcomeNamed :: EventName -> Maybe (Gen AnyOutcome)
genOutcomeNamed name = case filter ((== name) . outcomeEvent) templates of
    [] -> Nothing
    named -> Just (Gen.element named >>= like)

-- | The edge every outcome takes.
outcomeNames :: Set EventName
outcomeNames = Set.fromList (map outcomeEvent templates)

-- | One of each outcome; 'like' fills in its data.
templates :: [AnyOutcome]
templates =
    [ outcome (LevelSet Balanced)
    , outcome ResearchSpawned
    , outcome ResearchHandedBack
    , outcome InterviewAsked
    , outcome DiscussAsked
    , outcome NotesDone
    , outcome (PlanDone "")
    , outcome SimplifyPlanDone
    , outcome ConfirmConfirmed
    , outcome ConfirmAdjusted
    , outcome (DraftDone (DraftPr (Url "") (Branch "") (Branch "")))
    , outcome (ImplementDone (Commit (Sha "") Set.empty))
    , outcome (RefactorDone (Sha ""))
    , outcome (ReviewClean (Sha ""))
    , outcome (ReviewRows (Sha ""))
    , outcome (PickFinal (Picks Set.empty Map.empty))
    , outcome (PickLoop (Picks Set.empty Map.empty))
    , outcome (FixDone (Commit (Sha "") Set.empty))
    , outcome (ReReviewClean (Sha ""))
    , outcome (ReReviewRows (Sha ""))
    , outcome (DescribeDone (Sha ""))
    , outcome (SimplifyPrDone (Sha ""))
    , outcome (AwaitCiGreen (Sha ""))
    , outcome (AwaitCiRed (Sha "") (Check "" :| []))
    , outcome (FixPrDone (Sha ""))
    , outcome (ReadyDone (Url ""))
    , outcome (ReadySkipped (Url ""))
    , outcome (TicketWritten (Url ""))
    , outcome (OpenPlanDone (Url ""))
    , outcome (OpenBranchDone (Branch ""))
    , outcome (OpenPrDone (Url ""))
    , outcome (DirectDone "")
    , outcome NextDone
    , outcome NextRequest
    ]
        <> concat
            [ [ outcome
                    ( BreakdownDone
                        fan
                        ( tasksOf
                            ( Task
                                (TaskId "t1")
                                []
                                (Branch "")
                                (Branch "")
                                Balanced
                                False
                                False
                                Set.empty
                                OwnPr
                                ChildConfirms
                                Nothing
                                Nothing
                                EngineerFlow
                                :| []
                            )
                        )
                    )
              , outcome (MergeDone fan (Url ""))
              , outcome (MergeNextRound fan)
              ]
            | fan <- fanOuts
            ]
        <> drawnOutcomes

-- | The same outcome, with generated data: of the same step, by the same leg.
like :: AnyOutcome -> Gen AnyOutcome
like (AnyOutcome layer (SomeOutcome s leg o)) = AnyOutcome layer . SomeOutcome s leg <$> likeIn layer o

likeIn :: Layer k -> Outcome (s :: k) l -> Gen (Outcome s l)
likeIn = \case
    GatherLayer -> \case
        ResearchSpawned -> pure ResearchSpawned
        ResearchHandedBack -> pure ResearchHandedBack
        InterviewAsked -> pure InterviewAsked
        DiscussAsked -> pure DiscussAsked
        NotesDone -> pure NotesDone
    PlanLayer -> \case
        PlanDone _ -> PlanDone <$> Gen.string (Range.linear 1 30) Gen.unicode
        SimplifyPlanDone -> pure SimplifyPlanDone
        ConfirmConfirmed -> pure ConfirmConfirmed
        ConfirmAdjusted -> pure ConfirmAdjusted
    BuildLayer -> \case
        DraftDone _ ->
            DraftDone
                <$> (DraftPr . Url <$> genText <*> (Branch <$> genText) <*> (Branch <$> genText))
        ImplementDone _ -> ImplementDone <$> genCommit
        RefactorDone _ -> RefactorDone <$> genSha
    ReviewLayer -> \case
        ReviewClean _ -> ReviewClean <$> genSha
        ReviewRows _ -> ReviewRows <$> genSha
        PickFinal _ -> PickFinal <$> genPicks
        PickLoop _ -> PickLoop <$> genPicks
        FixDone _ -> FixDone <$> genCommit
        ReReviewClean _ -> ReReviewClean <$> genSha
        ReReviewRows _ -> ReReviewRows <$> genSha
    ShipLayer -> \case
        DescribeDone _ -> DescribeDone <$> genSha
        SimplifyPrDone _ -> SimplifyPrDone <$> genSha
        AwaitCiGreen _ -> AwaitCiGreen <$> genSha
        AwaitCiRed _ _ ->
            AwaitCiRed
                <$> genSha
                <*> Gen.nonEmpty
                    (Range.linear 1 3)
                    (Check <$> Gen.element ["lint", "test", "build"])
        FixPrDone _ -> FixPrDone <$> genSha
        ReadyDone _ -> ReadyDone . Url <$> genText
        ReadySkipped _ -> ReadySkipped . Url <$> genText
    TicketLayer -> \case
        TicketWritten _ -> TicketWritten . Url <$> genText
    RequestLayer -> \case
        OpenPlanDone _ -> OpenPlanDone . Url <$> genText
        OpenBranchDone _ -> OpenBranchDone . Branch <$> genText
        OpenPrDone _ -> OpenPrDone . Url <$> genText
        DirectDone _ -> DirectDone <$> genText
        NextDone -> pure NextDone
        NextRequest -> pure NextRequest
    FanLayer -> \case
        BreakdownDone fan _ -> BreakdownDone fan <$> genTasks
        MergeDone fan _ -> MergeDone fan . Url <$> genText
        MergeNextRound fan -> pure (MergeNextRound fan)
    PickLayer -> \case
        o@(Pick.Picked _) -> pure o
    FuelLayer -> \case
        LevelSet _ -> LevelSet <$> Gen.enumBounded
        o@(Skipping _) -> pure o
        o@(Running _) -> pure o

-- | Few labels and requirements, so rounds share them often.
genPicks :: Gen Picks
genPicks =
    Picks
        <$> genSet (Label <$> Gen.element ["A", "B", "C"])
        <*> ( Map.fromList
                <$> Gen.list
                    (Range.linear 0 2)
                    ((,) . Requirement <$> Gen.element ["R1", "R2"] <*> Gen.enumBounded)
            )

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
        <*> ( picosecondsToDiffTime
                <$> Gen.integral (Range.linear 0 (86400 * 1000000000000 - 1))
            )

-- | Any run id the kernel accepts.
genRunId :: Gen RunId
genRunId = Gen.mapMaybe parseRunId genIdText

{- | Raw id text, often with a line break, so a property sees whether the id
parsers refuse one: 'Gen.unicode' alone almost never draws one.
-}
genIdText :: Gen Text
genIdText =
    Gen.text
        (Range.linear 1 8)
        (Gen.frequency [(9, Gen.unicode), (1, Gen.element lineBreaks)])

lineBreaks :: [Char]
lineBreaks = filter breaksLine [minBound .. maxBound]

genQId :: Gen QId
genQId = QId <$> genRunId <*> Gen.integral (Range.linear 0 1000)

genQuestion :: Gen Question
genQuestion = Question <$> genQId <*> Gen.enumBounded <*> genOneLine

-- | Any reading: a kind and a choice.
genReading :: Gen Reading
genReading =
    Reading <$> Gen.enumBounded <*> Gen.choice [RuleOn <$> genProposal, pure PassOn]

genProposal :: Gen Proposal
genProposal = Proposal <$> genOneLine <*> genOneLine <*> genOneLine <*> Gen.maybe genBasis

genBasis :: Gen Basis
genBasis = Gen.choice [AnsweredBy <$> genEventId, Obvious <$> genOneLine]

genReply :: Gen Reply
genReply = Gen.choice [Chose <$> genText, Other <$> genText]

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
start = Start EngineerFlow "notes" (ByUser OwnPr) (Set.fromList [AskUser, Hooks])

started :: Event
started = Started start

-- | A Fuel step's event, as a root's or a request's records it: the run's level from here on.
fuelSet :: Fuel -> Event
fuelSet level = Took mempty (outcome (LevelSet level))

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
