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
    OneLine,
    oneLineText,
    parseOneLine,
    Question (..),
    Reading (..),
    Choice (..),
    Proposal (..),
    Basis (..),
    Ruling,
    Verdict (..),
    Refusal (..),
    triage,
    rule,
    pass,
    Handler,
    forwardAll,
    andThen,
    Principal (..),
    Op (..),
    Delivery (..),
    Above (..),
    ask,
    deliver,
    needsDecision,
    handback,
) where

import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Records (HasField (..))
import Numeric.Natural (Natural)
import State.Id (EventId, RunId, breaksLine, eventIdText, numberedText, parseNumbered, runIdText)
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
    = -- | The role answers; see 'pass' for when it may still forward.
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
qidText (QId run n) = numberedText run n

parseQId :: Text -> Maybe QId
parseQId = fmap (uncurry QId) . parseNumbered

{- | Text with no line break, so a hand-back line that quotes it stays one
line (#360's wire format). Only 'parseOneLine' builds one.
-}
newtype OneLine = OneLine Text
    deriving stock (Eq, Show)

oneLineText :: OneLine -> Text
oneLineText (OneLine raw) = raw

parseOneLine :: Text -> Maybe OneLine
parseOneLine raw
    | Text.any breaksLine raw = Nothing
    | otherwise = Just (OneLine raw)

data Question = Question {qid :: QId, kind :: Kind, text :: OneLine}
    deriving stock (Eq, Show)

-- | What a role made of a question: the kind it reads it as, and its choice.
data Reading = Reading {kind :: Kind, choice :: Choice}
    deriving stock (Eq, Show)

data Choice = RuleOn Proposal | PassOn
    deriving stock (Eq, Show)

-- | A role's answer, before 'triage' checks the role may give it.
data Proposal = Proposal {answer :: OneLine, why :: OneLine, cost :: OneLine, basis :: Maybe Basis}
    deriving stock (Eq, Show)

-- | Why a ruling on a 'Security' question may stand without the user.
data Basis
    = -- | The user's earlier answer.
      AnsweredBy EventId
    | -- | Why the answer is obvious.
      Obvious OneLine
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
    | {- | The row answers this kind and may not forward it: a 'Fact' below the
      user, or any kind at the user, who has no one to forward to.
      -}
      MustAnswer Role Kind
    | -- | The row says this kind never reaches the role.
      NeverAskedOf Role Kind
    | -- | A ruling on a 'Security' question names no basis.
      NoBasis QId
    deriving stock (Eq, Show)

-- | A role's handling of a question, on the kind it is raised to.
triage :: Role -> Reading -> Question -> Either Refusal Verdict
triage role reading question = case reading.choice of
    RuleOn proposal -> Ruled <$> rule role reading.kind question proposal
    PassOn -> Forward <$> pass role reading.kind question

-- | A role's ruling on a question, read as this kind.
rule :: Role -> Kind -> Question -> Proposal -> Either Refusal Ruling
rule role reading question proposal = case authority role raised.kind of
    NeverAsked -> Left (NeverAskedOf role raised.kind)
    Forwards -> Left (MayNotRule role raised.kind)
    Answers -> accept raised proposal
    AnswersIf _ -> accept raised proposal
  where
    raised = raiseTo reading question

-- | A role passing a question, read as this kind, on to its parent.
pass :: Role -> Kind -> Question -> Either Refusal Question
pass role reading question = case authority role raised.kind of
    NeverAsked -> Left (NeverAskedOf role raised.kind)
    Forwards -> Right raised
    Answers -> forwardAnswered role raised
    AnswersIf _ -> Right raised
  where
    raised = raiseTo reading question

{- | A forward from a row that answers. The user is the top of the chain, so
it forwards nothing. Below it only a 'Fact' is refused: the user's 'Fact' cell
is 'NeverAsked', so one forwarded could climb to no one (law Total). Every
other kind reaches a user cell that answers it, so a question needing the
user's attention may climb (#351's user "may" cell for 'Pick').
-}
forwardAnswered :: Role -> Question -> Either Refusal Question
forwardAnswered role question = case role of
    User -> Left (MustAnswer User question.kind)
    Worker -> belowUser
    Engineer -> belowUser
    TenX -> belowUser
  where
    belowUser = case question.kind of
        Fact -> Left (MustAnswer role Fact)
        Pick -> Right question
        Design -> Right question
        Scope -> Right question
        Confirm -> Right question
        Security -> Right question
        Stuck -> Right question

raiseTo :: Kind -> Question -> Question
raiseTo reading question = Question question.qid (raise question.kind reading) question.text

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
    | -- | Up to whoever started the run.
      Up Above
    deriving stock (Eq, Show)

-- | Whoever started a run: where its questions go and its answers come from.
data Above
    = -- | Ask the user.
      TheUser
    | -- | Hand back with 'needsDecision' to the parent run.
      ParentRun RunId
    deriving stock (Eq, Show)

-- | Where a role's own question goes: its own row first, then its principal.
ask :: Principal -> Role -> Kind -> Delivery
ask principal role kind = case authority role kind of
    Answers -> AnswerSelf
    AnswersIf _ -> AnswerSelf
    Forwards -> Up (deliver principal)
    -- Only the user's Fact cell, and the user runs no flow that asks.
    NeverAsked -> AnswerSelf

-- | Where a forwarded question goes: up to whoever started the run.
deliver :: Principal -> Above
deliver = \case
    ByUser -> TheUser
    ByRole run _ -> ParentRun run

-- | The hand-back's first line for a forwarded question (#360's wire format).
needsDecision :: Question -> Text
needsDecision question =
    "NEEDS_DECISION " <> kindName question.kind <> " " <> qidText question.qid <> ": " <> oneLineText question.text

{- | A flow role's hand-back: its first line (#360's wire format), its run,
then a line per ruling it made, so the reader sees each one (law Audit).
-}
handback :: Text -> RunId -> [Ruling] -> Text
handback first run rulings = Text.unlines (first : ("Run: " <> runIdText run) : map rulingLine rulings)

-- | As the 10x ledger writes one: what, why, and what it costs if wrong.
rulingLine :: Ruling -> Text
rulingLine ruling =
    "Ruling "
        <> qidText ruling.qid
        <> " "
        <> kindName ruling.kind
        <> ": "
        <> Text.intercalate " - " (map oneLineText [proposal.answer, proposal.why, proposal.cost])
        <> foldMap ((" - basis: " <>) . basisText) proposal.basis
  where
    proposal = ruling.proposal

basisText :: Basis -> Text
basisText = \case
    AnsweredBy event -> eventIdText event
    Obvious why -> "obvious: " <> oneLineText why
