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
module State.Run.Ask (
    Kind (..),
    kindName,
    parseKind,
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
    flattened,
    Question (..),
    Reading (..),
    Decision (..),
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
    principalShape,
    principalPlan,
    Parent (..),
    Link (..),
    Op (..),
    Delivery (..),
    Above (..),
    ask,
    Route (..),
    route,
    Reply (..),
    replyText,
    replyNote,
    deliver,
    questionLine,
    handback,
    rulingLine,
) where

import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Records (HasField (..))
import Numeric.Natural (Natural)
import State.Category.Fuel (parseByName)
import State.Role (Rung (..))
import State.Run.Id (EventId, RunId, TaskId, breaksLine, eventIdText, numberedText, parseNumbered, runIdText)
import State.Step.Artifact (PlanCall (..), Shape)

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

-- | #351's table of who answers, row for row as #360 writes it, keyed by rung.
authority :: Rung -> Kind -> Rule
authority = \case
    -- A worker never answers: it hands every question to its engineer.
    Worker -> const Forwards
    Lead -> \case
        Fact -> Answers
        Pick -> Answers
        Design -> Forwards
        Scope -> Forwards
        Confirm -> Forwards
        Security -> Forwards
        Stuck -> Forwards
    Orchestrator -> \case
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

-- | Text the run wrote itself, made one line: each line break a space.
flattened :: Text -> OneLine
flattened = OneLine . Text.map (\c -> if breaksLine c then ' ' else c)

data Question = Question {qid :: QId, kind :: Kind, text :: OneLine}
    deriving stock (Eq, Show)

-- | What a role made of a question: the kind it reads it as, and its choice.
data Reading = Reading {kind :: Kind, choice :: Decision}
    deriving stock (Eq, Show)

data Decision = RuleOn Proposal | PassOn
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
      MayNotRule Rung Kind
    | {- | The row answers this kind and may not forward it: a 'Fact' below the
      user, or any kind at the user, who has no one to forward to.
      -}
      MustAnswer Rung Kind
    | -- | The row says this kind never reaches the role.
      NeverAskedOf Rung Kind
    | -- | A ruling on a 'Security' question names no basis.
      NoBasis QId
    deriving stock (Eq, Show)

-- | A role's handling of a question, on the kind it is raised to.
triage :: Rung -> Reading -> Question -> Either Refusal Verdict
triage role reading question = case reading.choice of
    RuleOn proposal -> Ruled <$> rule role reading.kind question proposal
    PassOn -> Forward <$> pass role reading.kind question

-- | A role's ruling on a question, read as this kind.
rule :: Rung -> Kind -> Question -> Proposal -> Either Refusal Ruling
rule role reading question proposal = case authority role raised.kind of
    NeverAsked -> Left (NeverAskedOf role raised.kind)
    Forwards -> Left (MayNotRule role raised.kind)
    Answers -> accept raised proposal
    AnswersIf _ -> accept raised proposal
  where
    raised = raiseTo reading question

-- | A role passing a question, read as this kind, on to its parent.
pass :: Rung -> Kind -> Question -> Either Refusal Question
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
forwardAnswered :: Rung -> Question -> Either Refusal Question
forwardAnswered role question = case role of
    User -> Left (MustAnswer User question.kind)
    Worker -> belowUser
    Lead -> belowUser
    Orchestrator -> belowUser
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

{- | Who started the run, and the shape of its work: the user, who names a
round's PR at init; a parent run, which gave it a task of this shape and
plan call, read from the parent's breakdown when the run started; or the
agent that spawned this subagent with no run link, which names a round's PR
at init as the user does.
-}
data Principal = ByUser Shape | ByRole Parent Shape PlanCall | ByCaller Shape
    deriving stock (Eq, Show)

-- | What the run does to its PR, whoever started it.
principalShape :: Principal -> Shape
principalShape = \case
    ByUser shape -> shape
    ByRole _ shape _ -> shape
    ByCaller shape -> shape

-- | Who settles the run's plan: the user confirms its own run's.
principalPlan :: Principal -> PlanCall
principalPlan = \case
    ByUser _ -> ChildConfirms
    ByRole _ _ plan -> plan
    ByCaller _ -> ChildConfirms

-- | The parent run, and how it gave this run its work.
data Parent = Parent {run :: RunId, link :: Link}
    deriving stock (Eq, Show)

{- | A child of a fan-out takes a task of its parent's breakdown; a direct
child, of a parent at no fan-out (the chief delegating one engineer), none.
Either way its questions go up to the parent.
-}
data Link = AtFan TaskId | Direct
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
    | -- | Hand back with the question's @NEEDS_DECISION@ line to the parent run.
      ParentRun RunId
    | -- | Hand back with the question's @NEEDS_DECISION@ line to the agent that spawned this one, which holds no run of this one's.
      TheCaller
    deriving stock (Eq, Show)

{- | Where a role's own question goes: its own row first, then its principal.
'FitsBreakdown' never holds for a run's own question: the 10x's own Confirm is of the breakdown
itself, before any is confirmed. The LLM judges every other condition, and may
still forward.
-}
ask :: Principal -> Rung -> Kind -> Delivery
ask principal role kind = case authority role kind of
    Answers -> AnswerSelf
    AnswersIf RuleTest -> AnswerSelf
    AnswersIf FitsBreakdown -> up
    AnswersIf ObviousOrAnswered -> AnswerSelf
    AnswersIf OneRetry -> AnswerSelf
    Forwards -> up
    -- Only the user's Fact cell, and the user runs no flow that asks.
    NeverAsked -> AnswerSelf
  where
    up = Up (deliver principal)

-- | How a run's own question is sent: as its row says, or put to the user at once.
data Route = ByRow | ToUser
    deriving stock (Eq, Show)

{- | Where a run's own question goes on this route. Put to the user, it goes
up from a row that may pass it on ('pass'), and is refused where the row
answers it itself: a 'Fact' below the user.
-}
route :: Route -> Principal -> Rung -> Question -> Either Refusal Delivery
route how principal role question = case how of
    ByRow -> Right (ask principal role question.kind)
    ToUser -> Up (deliver principal) <$ pass role question.kind question

-- | Where a forwarded question goes: up to whoever started the run.
deliver :: Principal -> Above
deliver = \case
    ByUser _ -> TheUser
    ByRole parent _ _ -> ParentRun parent.run
    ByCaller _ -> TheCaller

{- | An answer from above: one of the options the question offered, or a
reply that is none of them, which may be a new request.
-}
data Reply = Chose Text | Other Text
    deriving stock (Eq, Show)

-- | The reply's text, an 'Other' marked as none of the options.
replyText :: Reply -> Text
replyText = \case
    Chose answer -> answer
    Other reply -> reply <> " (" <> replyNote <> ")"

-- | What an 'Other' reply asks of the run that reads it.
replyNote :: Text
replyNote = "none of the options: it may be a new request - re-plan for it, or take it up as one"

-- | A question on one line, @<Kind> <qid>: <question>@, as a hand-back's @NEEDS_DECISION@ carries it (#360's wire format).
questionLine :: Question -> Text
questionLine question = kindName question.kind <> " " <> qidText question.qid <> ": " <> oneLineText question.text

{- | A flow role's hand-back: its first line (#360's wire format), its run,
then a line per ruling it made, so the reader sees each one (law Audit).
-}
handback :: Text -> RunId -> [Ruling] -> Text
handback first run rulings = Text.unlines (first : ("Run: " <> runIdText run) : map rulingLine rulings)

-- | As @state show@ lists one: what, why, and what it costs if wrong.
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
