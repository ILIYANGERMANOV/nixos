{- | One line of a run's log: what happened, and the envelope that names and
places it. A step's outcome is an 'Outcome', named by the step it ends
('outcomeEvent'), so a log is read off the flow's graph. A question is an
'Asking' and the events on its id that close it; the 10x's fan-out events
(PR 6) join as more constructors.
-}
module State.Event (
    Envelope (..),
    Source (..),
    EventId (..),
    eventId,
    RunId,
    parseRunId,
    runIdText,
    SessionId (..),
    Digest (..),
    Event (..),
    Start (..),
    FlowName (..),
    Principal (..),
    Op (..),
    Asking (..),
    Asker (..),
    AgentRole (..),
    roleText,
    Stop (..),
    StopReason (..),
    Note (..),
    Outcome (..),
    outcomeEvent,
    DraftPr (..),
    Commit (..),
    Picks (..),
    Judgement (..),
    Sha (..),
    Url (..),
    Branch (..),
    Label (..),
    Requirement (..),
    Check (..),
    StateName (..),
) where

import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Text (Text)
import Data.Time (UTCTime)
import Numeric.Natural (Natural)
import State.Ask (Above, Op (..), Principal (..), Proposal, QId, Question)
import State.Cap (EventName, StateName (..), Step (..), continueEvent, exitEvent, skipEvent)
import State.Id (Digest (..), EventId (..), RunId, parseRunId, runIdText)
import State.Mode (Area, Quality, Size)

{- | The id is not stored: a CLI record's is its run and seq, so only a hook
record carries one of its own.
-}
data Envelope = Envelope
    { source :: Source
    , seq :: Natural
    , ts :: UTCTime
    , run :: RunId
    , head :: Maybe Sha
    , session :: Maybe SessionId
    , event :: Event
    }
    deriving stock (Eq, Show)

{- | Who wrote the line. A hook can fire twice for one message, so its record
is keyed on a hash of the run, agent and message, and the second is a no-op.
-}
data Source = Cli | Hook Digest
    deriving stock (Eq, Show)

eventId :: Envelope -> EventId
eventId envelope = case envelope.source of
    Cli -> Numbered envelope.run envelope.seq
    Hook digest -> Hashed digest

newtype SessionId = SessionId Text
    deriving stock (Eq, Show)

data Event
    = Started Start
    | -- | Set once.
      QualitySet Quality
    | -- | Set once; only 'Grew' changes it.
      SizeSet Size
    | -- | A Trivial task found bigger: the size is Normal from here.
      Grew Text
    | -- | A step's outcome, or a mode's skip: the one event that moves the run.
      Took Outcome
    | -- | Terminal: it ends every question still pending too.
      Stopped Stop
    | {- | A question for this run to rule on or forward: its own, or one handed
      up to it, under the id it was first asked by.
      -}
      Asked Asking
    | {- | The question is 'State.Ask.Security' from here on. The event names no
      kind, so none re-tags a question away from it (law Ceiling).
      -}
      RetaggedSecurity QId
    | -- | This run ruled on the question (law Audit).
      RuledOn QId Proposal
    | -- | This run passed the question up, to whoever started it.
      Forwarded QId Above
    | -- | The answer that came down, and who gave it.
      Answered QId Text Above
    | -- | The escape edge, outside the graph: to the named state, and why.
      Overridden StateName Text
    | -- | An event the run refused, logged so the next read can warn of it.
      Refused Note
    deriving stock (Eq, Show)

{- | The run's environment is data here, read by whoever delivers advice, never
by the flow: a flow does not branch on who runs it (law Principal-blind).
-}
data Start = Start
    { flow :: FlowName
    , notes :: FilePath
    , principal :: Principal
    , interface :: Set Op
    , task :: Text
    }
    deriving stock (Eq, Show)

data FlowName = EngineerFlow | TenXFlow
    deriving stock (Eq, Show, Enum, Bounded)

-- | A question as it reached this run, and the step the run was at.
data Asking = Asking {question :: Question, step :: StateName, from :: Asker}
    deriving stock (Eq, Show)

-- | Who put the question to this run.
data Asker = Itself | Subagent AgentRole | ChildRun RunId
    deriving stock (Eq, Show)

-- | A subagent's role, as @state handback <role>@ names it: @implementer@.
newtype AgentRole = AgentRole Text
    deriving stock (Eq, Show)

roleText :: AgentRole -> Text
roleText (AgentRole role) = role

data Stop = Stop {reason :: StopReason, why :: Text}
    deriving stock (Eq, Show)

-- | @replan@ ends this run; a new run starts at @Ctx@.
data StopReason = Blocked | Failed | Replan | Fuel | Outgrown
    deriving stock (Eq, Show, Enum, Bounded)

-- | A refusal as the reader saw it: what was wrong, and the fix.
data Note = Note {message :: Text, fix :: Text}
    deriving stock (Eq, Show)

{- | One per edge of the engineer flow, carrying what that outcome reports.
A skip is its own outcome: a skipped step stays in the path (#351).
-}
data Outcome
    = -- | The number of researchers.
      ResearchDone Natural
    | ResearchSkipped
    | InterviewEnough
    | InterviewMore
    | -- | The plan file.
      PlanDone FilePath
    | SimplifyPlanDone
    | SimplifyPlanSkipped
    | AlternativeDone
    | AlternativeSkipped
    | ConfirmConfirmed
    | ConfirmAdjusted
    | DraftDone DraftPr
    | ImplementDone Commit
    | RefactorDone Sha
    | -- | Why it was skipped.
      RefactorSkipped Text
    | ReviewClean Sha
    | ReviewRows Sha
    | PickFinal Picks
    | PickLoop Picks
    | FixDone Commit
    | DescribeDone Sha
    | SimplifyPrDone Sha
    | SimplifyPrSkipped Sha
    | AwaitCiGreen Sha
    | -- | Red has a failing check by definition.
      AwaitCiRed Sha (NonEmpty Check)
    | FixPrDone Sha
    | ReadyDone Url
    | -- | POC keeps a draft: the PR it left.
      ReadySkipped Url
    deriving stock (Eq, Show)

-- | The graph's name for the edge an outcome takes, from "State.Cap"'s names.
outcomeEvent :: Outcome -> EventName
outcomeEvent = \case
    ResearchDone _ -> continueEvent Research
    ResearchSkipped -> skipEvent Research
    InterviewEnough -> exitEvent Interview
    InterviewMore -> continueEvent Interview
    PlanDone _ -> continueEvent PlanS
    SimplifyPlanDone -> continueEvent SimplifyP
    SimplifyPlanSkipped -> skipEvent SimplifyP
    AlternativeDone -> continueEvent Alternative
    AlternativeSkipped -> skipEvent Alternative
    ConfirmConfirmed -> exitEvent Confirm
    ConfirmAdjusted -> continueEvent Confirm
    DraftDone _ -> continueEvent Draft
    ImplementDone _ -> continueEvent Implement
    RefactorDone _ -> continueEvent Refactor
    RefactorSkipped _ -> skipEvent Refactor
    ReviewClean _ -> exitEvent Review
    ReviewRows _ -> continueEvent Review
    PickFinal _ -> exitEvent Pick
    PickLoop _ -> continueEvent Pick
    FixDone _ -> continueEvent Fix
    DescribeDone _ -> continueEvent Describe
    SimplifyPrDone _ -> continueEvent SimplifyPR
    SimplifyPrSkipped _ -> skipEvent SimplifyPR
    AwaitCiGreen _ -> exitEvent AwaitCi
    AwaitCiRed _ _ -> continueEvent AwaitCi
    FixPrDone _ -> continueEvent FixPR
    ReadyDone _ -> continueEvent Ready
    ReadySkipped _ -> skipEvent Ready

-- | The draft PR, synced from GitHub.
data DraftPr = DraftPr {url :: Url, base :: Branch, branch :: Branch}
    deriving stock (Eq, Show)

-- | A commit and the areas it touches, which decide a fix's full review.
data Commit = Commit {head :: Sha, touches :: Set Area}
    deriving stock (Eq, Show)

{- | The rows to fix, labelled so one finding keeps its label across rounds,
and the verdict on each requirement.
-}
data Picks = Picks {rows :: Set Label, verdicts :: Map Requirement Judgement}
    deriving stock (Eq, Show)

data Judgement = Met | NotMet | Unverified
    deriving stock (Eq, Show, Enum, Bounded)

newtype Sha = Sha Text
    deriving stock (Eq, Show)

newtype Url = Url Text
    deriving stock (Eq, Show)

newtype Branch = Branch Text
    deriving stock (Eq, Show)

newtype Label = Label Text
    deriving stock (Eq, Ord, Show)

newtype Requirement = Requirement Text
    deriving stock (Eq, Ord, Show)

-- | A CI check, by name.
newtype Check = Check Text
    deriving stock (Eq, Ord, Show)
