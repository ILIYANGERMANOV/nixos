{- | Who answers a question (#351 section 4, "Ifc - who answers"). A question
is judged by the asking role's own row of 'authority', then by each parent's
row, and reaches the user when no role below may answer it. Each role is a
handler: it rules on the question or forwards it, and handlers compose
(laws Forward is identity and Chain).

The 'Cond' cells are judged by the LLM: no code can tell whether a Design
answer passes the rule test. The kernel checks structure only: 'triage'
refuses a ruling where the row forwards, a forward where the row answers, a
'Security' ruling with no 'Basis', and never re-tags a question away from
'Security' (law Ceiling).

'Principal' and 'Op', the run's environment, live here and not beside the
flows: a flow does not branch on who runs it (law Principal-blind), so the
flow modules never import this module.
-}
module State.Ask (
    Kind (..),
    kindName,
    parseKind,
    Role (..),
    Cond (..),
    Rule (..),
    authority,
    raise,
    QId (..),
    qidText,
    parseQId,
    Question (..),
    Reading (..),
    Choice (..),
    Proposal (..),
    Basis (..),
    Ruling,
    Verdict (..),
    Refusal (..),
    triage,
    Handler,
    forwardAll,
    andThen,
    Principal (..),
    Op (..),
    Delivery (..),
    ask,
    deliver,
    needsDecision,
) where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Read (decimal)
import GHC.Records (HasField (..))
import Numeric.Natural (Natural)
import State.Id (EventId, RunId, parseRunId, runIdText)
import State.Mode (parseByName)

{- | What a question is about, which decides who may answer it. 'Security' is
above every other kind and the rest are not ordered, so no 'Ord': only
'raise' moves a kind, and only up to 'Security'.
-}
data Kind = Fact | Pick | Design | Scope | Confirm | Security | Stuck
    deriving stock (Eq, Show, Enum, Bounded)

-- | The wire name, as a hand-back's @NEEDS_DECISION <Kind>@ spells it.
kindName :: Kind -> Text
kindName = \case
    Fact -> "Fact"
    Pick -> "Pick"
    Design -> "Design"
    Scope -> "Scope"
    Confirm -> "Confirm"
    Security -> "Security"
    Stuck -> "Stuck"

parseKind :: Text -> Maybe Kind
parseKind = parseByName kindName

-- | A rung of the chain a question climbs; the user is the top.
data Role = Worker | Engineer | TenX | User
    deriving stock (Eq, Show, Enum, Bounded)

-- | What the LLM judges before a role may answer under 'AnswersIf'.
data Cond
    = -- | The answer is lower-impact, mostly obvious and reversible.
      RuleTest
    | -- | The task plan fits the confirmed breakdown.
      FitsBreakdown
    | -- | The user already answered it, or the answer is obvious.
      ObviousOrAnswered
    | -- | No retry was spent on it yet.
      OneRetry
    | -- | The task is @Size: Trivial@.
      TrivialSize
    deriving stock (Eq, Show, Enum, Bounded)

data Rule
    = {- | The role answers and may not forward: else a 'Fact' could climb to
      the user, who is never asked one (law Total).
      -}
      Answers
    | -- | The role answers when the LLM judges the condition holds, else forwards.
      AnswersIf Cond
    | Forwards
    | -- | The question never reaches this role.
      NeverAsked
    deriving stock (Eq, Show)

-- | #351's table of who answers, row for row as #360 writes it.
authority :: Role -> Kind -> Rule
authority = \case
    -- A worker never answers: it hands every question to its engineer.
    Worker -> const Forwards
    Engineer -> \case
        Fact -> Answers
        Pick -> Answers
        Design -> Forwards
        Scope -> Forwards
        Confirm -> AnswersIf TrivialSize
        Security -> Forwards
        Stuck -> Forwards
    TenX -> \case
        Fact -> Answers
        Pick -> Answers
        Design -> AnswersIf RuleTest
        Scope -> AnswersIf RuleTest
        Confirm -> AnswersIf FitsBreakdown
        Security -> AnswersIf ObviousOrAnswered
        Stuck -> AnswersIf OneRetry
    User -> \case
        Fact -> NeverAsked
        Pick -> Answers
        Design -> Answers
        Scope -> Answers
        Confirm -> Answers
        Security -> Answers
        Stuck -> Answers

-- | The kind a reader gives a question: 'Security' if either is, else the reading.
raise :: Kind -> Kind -> Kind
raise asked reading = case asked of
    Security -> Security
    Fact -> reading
    Pick -> reading
    Design -> reading
    Scope -> reading
    Confirm -> reading
    Stuck -> reading

{- | @<asking run>:<n>@. A question keeps it as it climbs, so a parent's and a
child's logs join on it.
-}
data QId = QId RunId Natural
    deriving stock (Eq, Ord, Show)

qidText :: QId -> Text
qidText (QId run n) = runIdText run <> ":" <> Text.pack (show n)

-- | A run id holds no @:@, so the first one splits the run from the number.
parseQId :: Text -> Maybe QId
parseQId raw = case Text.breakOn ":" raw of
    (run, rest) -> QId <$> parseRunId run <*> (Text.stripPrefix ":" rest >>= number)
  where
    number digits = case decimal digits of
        Right (n, "") -> Just n
        Right _ -> Nothing
        Left _ -> Nothing

data Question = Question {qid :: QId, kind :: Kind, text :: Text}
    deriving stock (Eq, Show)

-- | What a role made of a question: the kind it reads it as, and its choice.
data Reading = Reading {kind :: Kind, choice :: Choice}
    deriving stock (Eq, Show)

data Choice = RuleOn Proposal | PassOn
    deriving stock (Eq, Show)

-- | A role's answer, before 'triage' checks the role may give it.
data Proposal = Proposal {answer :: Text, why :: Text, cost :: Text, basis :: Maybe Basis}
    deriving stock (Eq, Show)

-- | Why a ruling on a 'Security' question may stand without the user.
data Basis
    = -- | The user's earlier answer.
      AnsweredBy EventId
    | -- | Why the answer is obvious.
      Obvious Text
    deriving stock (Eq, Show)

{- | A proposal 'triage' accepted, on the kind it ruled as. Only 'triage'
builds one, so a 'Security' ruling always names its basis; read it through
the fields @qid@, @kind@ and @proposal@.
-}
data Ruling = Accepted QId Kind Proposal
    deriving stock (Eq, Show)

instance HasField "qid" Ruling QId where
    getField (Accepted qid _ _) = qid

instance HasField "kind" Ruling Kind where
    getField (Accepted _ kind _) = kind

instance HasField "proposal" Ruling Proposal where
    getField (Accepted _ _ proposal) = proposal

-- | A forwarded question carries the kind it was raised to.
data Verdict = Ruled Ruling | Forward Question
    deriving stock (Eq, Show)

-- | A choice the role's row does not allow.
data Refusal
    = -- | The row forwards this kind.
      MayNotRule Role Kind
    | -- | The row answers this kind.
      MustAnswer Role Kind
    | -- | The row says this kind never reaches the role.
      NeverAskedOf Role Kind
    | -- | A ruling on a 'Security' question names no basis.
      NoBasis QId
    deriving stock (Eq, Show)

-- | A role's handling of a question, on the kind it is raised to.
triage :: Role -> Reading -> Question -> Either Refusal Verdict
triage role reading question = case authority role kind of
    NeverAsked -> Left (NeverAskedOf role kind)
    Forwards -> case reading.choice of
        RuleOn _ -> Left (MayNotRule role kind)
        PassOn -> Right (Forward raised)
    Answers -> answerOr (Left (MustAnswer role kind))
    AnswersIf _ -> answerOr (Right (Forward raised))
  where
    kind = raise question.kind reading.kind
    raised = Question question.qid kind question.text
    answerOr passed = case reading.choice of
        RuleOn proposal -> Ruled <$> accept raised proposal
        PassOn -> passed

accept :: Question -> Proposal -> Either Refusal Ruling
accept question proposal
    | Security <- question.kind, Nothing <- proposal.basis = Left (NoBasis question.qid)
    | otherwise = Right (Accepted question.qid question.kind proposal)

{- | One rung's handling of a question: a Kleisli arrow, so rungs compose
with 'andThen' and 'forwardAll' is the identity.
-}
type Handler = Question -> Either Refusal Verdict

-- | The handler that passes every question on as it came.
forwardAll :: Handler
forwardAll = Right . Forward

-- | The first rung, then the next one on what it forwards.
andThen :: Handler -> Handler -> Handler
andThen first next question =
    first question >>= \case
        Ruled ruling -> Right (Ruled ruling)
        Forward forwarded -> next forwarded

-- | Who started the run: the user, or a parent run, by its id and log path.
data Principal = ByUser | ByRole RunId FilePath
    deriving stock (Eq, Show)

-- | What the run's interface can do: a subagent cannot ask the user or wait.
data Op = AskUser | Await | Notify | Hooks | Background
    deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Where a question goes next.
data Delivery
    = -- | The asking role's own row may answer it: rule, or forward it.
      AnswerSelf
    | -- | Ask the user, who started this run.
      ToUser
    | -- | Hand back with 'needsDecision', to the parent run.
      ToParent
    deriving stock (Eq, Show)

-- | Where a role's own question goes: its own row first, then its principal.
ask :: Principal -> Role -> Kind -> Delivery
ask principal role kind = case authority role kind of
    Answers -> AnswerSelf
    AnswersIf _ -> AnswerSelf
    Forwards -> deliver principal
    -- Only the user's Fact cell, and the user runs no flow that asks.
    NeverAsked -> AnswerSelf

-- | Where a forwarded question goes: up to whoever started the run.
deliver :: Principal -> Delivery
deliver = \case
    ByUser -> ToUser
    ByRole _ _ -> ToParent

-- | The hand-back's first line for a forwarded question (#360's wire format).
needsDecision :: Question -> Text
needsDecision question =
    "NEEDS_DECISION " <> kindName question.kind <> " " <> qidText question.qid <> ": " <> question.text
