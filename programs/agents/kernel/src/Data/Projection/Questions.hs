{- | The questions projection (#552 Appendix A and c3): each question a run
has to settle (@questions@), its rulings (@rulings@), the answers that came
down (@answers@), and what the user has yet to do by hand (@user_needs@,
@user_need_blocks@). A question, ruling and answer is each born of one line
of the trace, and keyed by that line's seq.
-}
module Data.Projection.Questions (
    projection,
    rows,
    QuestionRow (..),
    Standing (..),
    RulingRow (..),
    RulingBasis (..),
    AnswerRow (..),
    UserNeedRow (..),
    UserNeedBlockRow (..),
    questionInsert,
    rulingInsert,
    answerInsert,
    userNeedInsert,
    userNeedBlockInsert,
) where

import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Payload.Event (questionKindName)
import Data.Projection (
    Insert (..),
    Projection (..),
    Table,
    Value (..),
    integer,
    nullable,
    spellings,
    strictTable,
 )
import Data.Set qualified as Set
import Data.Text (Text)
import Numeric.Natural (Natural)
import State.Artifact (uriText)
import State.Category.Step (stateNameText)
import State.Role (roleText)
import State.Run.Ask (
    Above (..),
    Basis (..),
    Kind,
    OneLine,
    Proposal (..),
    QId (..),
    Question (..),
    Reply (..),
    oneLineText,
 )
import State.Run.Event (
    Asker (..),
    Asking (..),
    Envelope (..),
    Event (..),
    Need (..),
    RunId,
    Source (..),
    TaskRef (..),
    runIdText,
 )
import State.Run.Fold (Pending (..), RunState (..), Waits (..))
import State.Run.Id (Digest, EventId (..), EventRef (..))
import State.Step.Artifact (nonBlankText, taskIdText)

projection :: Projection
projection =
    Projection
        { name = "questions"
        , version = 1
        , tables = questions :| [rulings, answers, userNeeds, userNeedBlocks]
        }

-- | The run's rows in every table of this projection, from its trace.
rows :: NonEmpty (Envelope, RunState) -> [Insert]
rows trace =
    map questionInsert (questionRows trace)
        <> map rulingInsert (rulingRows asked trace)
        <> map answerInsert (answerRows asked trace)
        <> [userNeedInsert (UserNeedRow final.run seq' need) | (seq', need) <- needs]
        <> [ userNeedBlockInsert (UserNeedBlockRow final.run seq' task)
           | (seq', need) <- needs
           , task <- Set.toList need.blocks
           ]
  where
    final = snd (NonEmpty.last trace)
    needs = Map.toList final.needs
    asked = askedAt trace

-- | The seq of each question's @asked@ line in this run: its row's id.
askedAt :: NonEmpty (Envelope, RunState) -> Map QId Natural
askedAt trace =
    Map.fromList
        [ (asking.question.qid, e.seq) | (e, _) <- toList trace, Asked asking <- [e.event]
        ]

{- | A question as it reached the run, by the seq of its @asked@ line: the
kind it stands at, which a retag raises, and where it stands.
-}
data QuestionRow = QuestionRow
    { runId :: RunId
    , id :: Natural
    , asking :: Asking
    , kind :: Kind
    , standing :: Standing
    }
    deriving stock (Eq, Show)

{- | Pending, and how; or ruled here, or answered from above. A question a
stop ended, or a parked task's child's question the run dropped, is pending
no more yet neither ruled nor answered: it keeps the way it last waited
(#552 s9, D5).
-}
data Standing = Waiting Waits | Ruled | Answered'
    deriving stock (Eq, Show)

-- | A question's status as its row spells it: 'Standing' with the park's reason dropped.
data QuestionStatus
    = InTriage
    | AwaitingAnswer
    | ParkedStatus
    | RuledStatus
    | AnsweredStatus
    deriving stock (Eq, Show, Enum, Bounded)

questionStatusName :: QuestionStatus -> Text
questionStatusName = \case
    InTriage -> "in_triage"
    AwaitingAnswer -> "awaiting_answer"
    ParkedStatus -> "parked"
    RuledStatus -> "ruled"
    AnsweredStatus -> "answered"

questionStatus :: Standing -> QuestionStatus
questionStatus = \case
    Waiting ForTriage -> InTriage
    Waiting ForAnswer -> AwaitingAnswer
    Waiting (ForLater _) -> ParkedStatus
    Ruled -> RuledStatus
    Answered' -> AnsweredStatus

{- | Each question asked in the run. Its kind and the way it waits are the
last state's of the trace that held it pending: the state its @asked@ line
left holds it, so that state stands in when no later one does.
-}
questionRows :: NonEmpty (Envelope, RunState) -> [QuestionRow]
questionRows trace =
    [ QuestionRow
        e.run
        e.seq
        asking
        last'.asking.question.kind
        (standing qid last'.waits)
    | (e, _) <- toList trace
    , Asked asking <- [e.event]
    , let qid = asking.question.qid
          last' = Map.findWithDefault (Pending asking ForTriage) qid pending
    ]
  where
    pending =
        Map.fromList
            [ (p.asking.question.qid, p)
            | (_, state) <- toList trace
            , p <- state.pending
            ]
    ruled = Set.fromList [qid | (e, _) <- toList trace, RuledOn qid _ <- [e.event]]
    answered = Set.fromList [qid | (e, _) <- toList trace, Answered qid _ _ <- [e.event]]
    standing qid waits
        | Set.member qid ruled = Ruled
        | Set.member qid answered = Answered'
        | otherwise = Waiting waits

-- | What an asker is, as its row spells it.
data AskerKind = SelfAsker | SubagentAsker | ChildRunAsker
    deriving stock (Eq, Show, Enum, Bounded)

askerKindName :: AskerKind -> Text
askerKindName = \case
    SelfAsker -> "self"
    SubagentAsker -> "subagent"
    ChildRunAsker -> "child_run"

-- | A ruling the run made on its question, and what it rests on.
data RulingRow = RulingRow
    { runId :: RunId
    , questionId :: Natural
    , answer :: OneLine
    , why :: OneLine
    , cost :: OneLine
    , basis :: RulingBasis
    }
    deriving stock (Eq, Show)

{- | What a ruling rests on: nothing, an event, or a stated reason. A hook's
event, named by its digest, is the line of the run that holds it; none
when no line does, as the ruling's command never refused one (#552 s9, D6).
-}
data RulingBasis = NoBasis | OnEvent (Maybe EventRef) | ObviousFor OneLine
    deriving stock (Eq, Show)

data BasisKind = NoneBasis | EventBasis | ObviousBasis
    deriving stock (Eq, Show, Enum, Bounded)

basisKindName :: BasisKind -> Text
basisKindName = \case
    NoneBasis -> "none"
    EventBasis -> "event"
    ObviousBasis -> "obvious"

-- | Each @ruled@ line of the trace, on the question its @asked@ line names.
rulingRows :: Map QId Natural -> NonEmpty (Envelope, RunState) -> [RulingRow]
rulingRows asked trace =
    [ RulingRow
        e.run
        question
        proposal.answer
        proposal.why
        proposal.cost
        (basisOf proposal.basis)
    | (e, _) <- toList trace
    , RuledOn qid proposal <- [e.event]
    , Just question <- [Map.lookup qid asked]
    ]
  where
    hooked :: Map Digest Natural
    hooked =
        Map.fromList
            [(digest, e.seq) | (e, _) <- toList trace, Hook digest <- [e.source]]
    run = (snd (NonEmpty.head trace)).run
    basisOf = \case
        Nothing -> NoBasis
        Just (AnsweredBy (Numbered on seq')) -> OnEvent (Just (EventRef on seq'))
        Just (AnsweredBy (Hashed digest)) -> OnEvent (EventRef run <$> Map.lookup digest hooked)
        Just (Obvious why) -> ObviousFor why

-- | The answer that came down to a forwarded question, and who gave it.
data AnswerRow = AnswerRow {runId :: RunId, questionId :: Natural, reply :: Reply, by :: Above}
    deriving stock (Eq, Show)

data ReplyKind = ChoseReply | OtherReply
    deriving stock (Eq, Show, Enum, Bounded)

replyKindName :: ReplyKind -> Text
replyKindName = \case
    ChoseReply -> "chose"
    OtherReply -> "other"

data AnswererKind = UserAnswerer | ParentRunAnswerer | CallerAnswerer
    deriving stock (Eq, Show, Enum, Bounded)

answererKindName :: AnswererKind -> Text
answererKindName = \case
    UserAnswerer -> "user"
    ParentRunAnswerer -> "parent_run"
    CallerAnswerer -> "caller"

{- | Each @answered@ line of the trace: the fold takes one per question, and
the trace drops a repeat.
-}
answerRows :: Map QId Natural -> NonEmpty (Envelope, RunState) -> [AnswerRow]
answerRows asked trace =
    [ AnswerRow e.run question reply by
    | (e, _) <- toList trace
    , Answered qid reply by <- [e.event]
    , Just question <- [Map.lookup qid asked]
    ]

-- | What the user has yet to do by hand, by the seq of its @user_needed@ line.
data UserNeedRow = UserNeedRow {runId :: RunId, id :: Natural, need :: Need}
    deriving stock (Eq, Show)

-- | A task an open need holds up.
data UserNeedBlockRow = UserNeedBlockRow {runId :: RunId, need :: Natural, task :: TaskRef}
    deriving stock (Eq, Show)

questionInsert :: QuestionRow -> Insert
questionInsert row =
    Insert
        "questions"
        ( ("run_id", SqlText (runIdText row.runId))
            :| [ ("id", integer row.id)
               , ("origin_run_id", SqlText (runIdText origin))
               , ("origin_question_id", integer originSeq)
               , ("kind", SqlText (questionKindName row.kind))
               , ("text", SqlText (oneLineText row.asking.question.text))
               , ("step", SqlText (stateNameText row.asking.step))
               , ("asker_kind", SqlText (askerKindName askerKind))
               , ("asker_role", nullable (SqlText . roleText) role)
               , ("asker_run_id", nullable (SqlText . runIdText) child)
               , ("status", SqlText (questionStatusName (questionStatus row.standing)))
               , ("parked_reason", nullable (SqlText . oneLineText) parked)
               ]
        )
  where
    QId origin originSeq = row.asking.question.qid
    (askerKind, role, child) = case row.asking.from of
        Itself -> (SelfAsker, Nothing, Nothing)
        Subagent agent -> (SubagentAsker, Just agent, Nothing)
        ChildRun run -> (ChildRunAsker, Nothing, Just run)
    parked = case row.standing of
        Waiting (ForLater why) -> Just why
        Waiting ForTriage -> Nothing
        Waiting ForAnswer -> Nothing
        Ruled -> Nothing
        Answered' -> Nothing

rulingInsert :: RulingRow -> Insert
rulingInsert row =
    Insert
        "rulings"
        ( ("run_id", SqlText (runIdText row.runId))
            :| [ ("question_id", integer row.questionId)
               , ("answer", SqlText (oneLineText row.answer))
               , ("reason", SqlText (oneLineText row.why))
               , ("cost", SqlText (oneLineText row.cost))
               , ("basis_kind", SqlText (basisKindName kind))
               , ("basis_event_run_id", nullable (SqlText . runIdText . (.run)) event)
               , ("basis_event_seq", nullable (integer . (.seq)) event)
               , ("basis_reason", nullable (SqlText . oneLineText) reason)
               ]
        )
  where
    (kind, event, reason) = case row.basis of
        NoBasis -> (NoneBasis, Nothing, Nothing)
        OnEvent ref -> (EventBasis, ref, Nothing)
        ObviousFor why -> (ObviousBasis, Nothing, Just why)

answerInsert :: AnswerRow -> Insert
answerInsert row =
    Insert
        "answers"
        ( ("run_id", SqlText (runIdText row.runId))
            :| [ ("question_id", integer row.questionId)
               , ("answer", SqlText answer)
               , ("reply_kind", SqlText (replyKindName replyKind))
               , ("answerer_kind", SqlText (answererKindName answerer))
               , ("answerer_run_id", nullable (SqlText . runIdText) parent)
               ]
        )
  where
    (replyKind, answer) = case row.reply of
        Chose text -> (ChoseReply, text)
        Other text -> (OtherReply, text)
    (answerer, parent) = case row.by of
        TheUser -> (UserAnswerer, Nothing)
        ParentRun run -> (ParentRunAnswerer, Just run)
        TheCaller -> (CallerAnswerer, Nothing)

userNeedInsert :: UserNeedRow -> Insert
userNeedInsert row =
    Insert
        "user_needs"
        ( ("run_id", SqlText (runIdText row.runId))
            :| [ ("id", integer row.id)
               , ("text", SqlText (nonBlankText row.need.text))
               , ("url", nullable (SqlText . uriText) row.need.url)
               ]
        )

userNeedBlockInsert :: UserNeedBlockRow -> Insert
userNeedBlockInsert row =
    Insert
        "user_need_blocks"
        ( ("run_id", SqlText (runIdText row.runId))
            :| [ ("user_need_id", integer row.need)
               , ("breakdown_id", integer row.task.breakdown)
               , ("task_id", SqlText (taskIdText row.task.task))
               ]
        )

questions :: Table
questions =
    strictTable
        "questions"
        [ "  -- One row per question a run has to settle: its own, or one a child run handed up."
        , ""
        , "  -- The run that holds the question."
        , "  run_id             TEXT    NOT NULL REFERENCES runs (id),"
        , "  -- The seq of this run's asked event."
        , "  id                 INTEGER NOT NULL,"
        , "  -- The run that first asked the question. This run, for its own question."
        , "  origin_run_id      TEXT    NOT NULL,"
        , "  -- The seq of the first asked event, in origin_run_id's log."
        , "  -- The question's one identity, printed as <origin_run_id>:<origin_question_id>."
        , "  origin_question_id INTEGER NOT NULL,"
        , "  -- What sort of decision it is. It decides who may answer."
        , "  kind               TEXT    NOT NULL"
        , "                     CONSTRAINT questions_kind_enum CHECK ("
        , "                       kind IN " <> spellings questionKindName <> "),"
        , "  -- The question, one line."
        , "  text               TEXT    NOT NULL,"
        , "  -- The flow state the run was at when the question was asked."
        , "  step               TEXT    NOT NULL,"
        , "  -- Who put the question to this run. self: its lead. subagent: a worker. child_run: a child run."
        , "  asker_kind         TEXT    NOT NULL"
        , "                     CONSTRAINT questions_asker_kind_enum CHECK (asker_kind IN "
            <> spellings askerKindName
            <> "),"
        , "  -- The worker's role. Set only when subagent."
        , "  asker_role         TEXT,"
        , "  -- The child run that handed the question up. Set only when child_run."
        , "  asker_run_id       TEXT    REFERENCES runs (id),"
        , "  -- in_triage: the run must rule or forward. awaiting_answer: forwarded up, no answer yet."
        , "  -- parked: waits for a later answer. ruled: this run ruled. answered: an answer came down."
        , "  -- A question a stop ended keeps the status it last had."
        , "  status             TEXT    NOT NULL"
        , "                     CONSTRAINT questions_status_enum CHECK ("
        , "                       status IN " <> spellings questionStatusName <> "),"
        , "  -- Why the question is parked. Set only when parked."
        , "  parked_reason      TEXT,"
        , "  PRIMARY KEY (run_id, id),"
        , "  FOREIGN KEY (run_id, id) REFERENCES events (run_id, seq),"
        , "  FOREIGN KEY (origin_run_id, origin_question_id) REFERENCES events (run_id, seq),"
        , "  CONSTRAINT questions_asker_role_iff_subagent CHECK ((asker_role IS NOT NULL) = (asker_kind = 'subagent')),"
        , "  CONSTRAINT questions_asker_run_id_iff_child_run CHECK ((asker_run_id IS NOT NULL) = (asker_kind = 'child_run')),"
        , "  CONSTRAINT questions_parked_reason_iff_parked CHECK ((parked_reason IS NOT NULL) = (status = 'parked'))"
        ]

rulings :: Table
rulings =
    strictTable
        "rulings"
        [ "  -- A run's own decision on a question. At most one per question."
        , ""
        , "  -- The run that ruled."
        , "  run_id          TEXT    NOT NULL REFERENCES runs (id),"
        , "  -- The question: questions.id."
        , "  question_id     INTEGER NOT NULL,"
        , "  -- What was decided, one line."
        , "  answer          TEXT    NOT NULL,"
        , "  -- Why, one line."
        , "  reason          TEXT    NOT NULL,"
        , "  -- What the decision costs, one line."
        , "  cost            TEXT    NOT NULL,"
        , "  -- What the ruling rests on. none: nothing named. event: an earlier event. obvious: a stated reason."
        , "  basis_kind      TEXT    NOT NULL"
        , "                  CONSTRAINT rulings_basis_kind_enum CHECK (basis_kind IN "
            <> spellings basisKindName
            <> "),"
        , "  -- The run of the event the ruling rests on. Set only when event."
        , "  -- No foreign key: the lead typed the reference, and the command checks it."
        , "  -- NULL with event: a hook's event no line of the run holds."
        , "  basis_event_run_id TEXT,"
        , "  -- The seq of that event. Set only when event."
        , "  basis_event_seq INTEGER,"
        , "  -- Why the answer is obvious. Set only when obvious."
        , "  basis_reason    TEXT,"
        , "  PRIMARY KEY (run_id, question_id),"
        , "  FOREIGN KEY (run_id, question_id) REFERENCES questions (run_id, id),"
        , "  CONSTRAINT rulings_basis_event_run_id_only_event CHECK (basis_event_run_id IS NULL OR basis_kind = 'event'),"
        , "  CONSTRAINT rulings_basis_event_seq_only_event CHECK (basis_event_seq IS NULL OR basis_kind = 'event'),"
        , "  CONSTRAINT rulings_basis_reason_iff_obvious CHECK ((basis_reason IS NOT NULL) = (basis_kind = 'obvious'))"
        ]

answers :: Table
answers =
    strictTable
        "answers"
        [ "  -- The answer that came down to a forwarded question. At most one per question."
        , ""
        , "  -- The run that got the answer."
        , "  run_id          TEXT    NOT NULL REFERENCES runs (id),"
        , "  -- The question: questions.id."
        , "  question_id     INTEGER NOT NULL,"
        , "  -- The answer's text."
        , "  answer          TEXT    NOT NULL,"
        , "  -- chose: one of the offered options. other: the answerer's own words."
        , "  reply_kind      TEXT    NOT NULL"
        , "                  CONSTRAINT answers_reply_kind_enum CHECK (reply_kind IN "
            <> spellings replyKindName
            <> "),"
        , "  -- Who answered. user: the person. parent_run: the run above. caller: the agent that spawned this lead."
        , "  answerer_kind   TEXT    NOT NULL"
        , "                  CONSTRAINT answers_answerer_kind_enum CHECK (answerer_kind IN "
            <> spellings answererKindName
            <> "),"
        , "  -- The run that answered. Set only when parent_run."
        , "  answerer_run_id TEXT    REFERENCES runs (id),"
        , "  PRIMARY KEY (run_id, question_id),"
        , "  FOREIGN KEY (run_id, question_id) REFERENCES questions (run_id, id),"
        , "  CONSTRAINT answers_answerer_run_id_iff_parent_run CHECK ((answerer_run_id IS NOT NULL) = (answerer_kind = 'parent_run'))"
        ]

userNeeds :: Table
userNeeds =
    strictTable
        "user_needs"
        [ "  -- What the user must still do by hand for a run: an admin console, a secret value, infrastructure."
        , "  -- A need marked done leaves the table; the run's log keeps both events."
        , ""
        , "  -- The run."
        , "  run_id TEXT    NOT NULL REFERENCES runs (id),"
        , "  -- The seq of the user_needed event."
        , "  id     INTEGER NOT NULL,"
        , "  -- What the user must do, one line."
        , "  text   TEXT    NOT NULL,"
        , "  -- Where to do it: an absolute URI. Optional: a need may name none."
        , "  url    TEXT,"
        , "  PRIMARY KEY (run_id, id),"
        , "  FOREIGN KEY (run_id, id) REFERENCES events (run_id, seq)"
        ]

userNeedBlocks :: Table
userNeedBlocks =
    strictTable
        "user_need_blocks"
        [ "  -- A task an open user need holds up."
        , ""
        , "  -- The run."
        , "  run_id       TEXT    NOT NULL REFERENCES runs (id),"
        , "  -- The need: user_needs.id."
        , "  user_need_id INTEGER NOT NULL,"
        , "  -- The breakdown of the task."
        , "  breakdown_id INTEGER NOT NULL,"
        , "  -- The task the need holds up."
        , "  task_id      TEXT    NOT NULL,"
        , "  PRIMARY KEY (run_id, user_need_id, breakdown_id, task_id),"
        , "  FOREIGN KEY (run_id, user_need_id) REFERENCES user_needs (run_id, id),"
        , "  FOREIGN KEY (run_id, breakdown_id, task_id) REFERENCES tasks (run_id, breakdown_id, id)"
        ]
