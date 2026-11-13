{- | A worker's hand-back on the wire (#360): a token on line 1, then the
trailer lines the kernel reads anywhere below it; other lines are prose.
'parseHandback' and 'renderHandback' are the two directions of the one
format, and 'typeHandback' turns a parsed hand-back into what the run records.
-}
module State.Handback (
    Handback (..),
    Token (..),
    Need (..),
    Waiting (..),
    parseHandback,
    parseTouches,
    renderHandback,
    tokenLine,
    stopLine,
    readyState,
    Typed (..),
    typeHandback,
) where

import Data.Maybe (catMaybes, fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import State.Ask (Kind (Stuck), OneLine, Question (..), needsDecision, oneLineText, parseKind, parseOneLine, parseQId)
import State.Cap (SomeStep (..), StateName (..), Step, stepName)
import State.Cap qualified as Cap
import State.Codec (areaText, parseStopLine, shaText, stopToken, stopWire)
import State.Event (AgentRole (..), Asker (..), Asking (..), Commit (..), Event (Asked, HandedBack, TaskMoved), Outcome (..), RunId, Said (..), Sha (..), Stop, StopReason (Replan), Task (..), TaskState (..), Url (..), fanRole, parseRunId, runIdText)
import State.Event qualified as Event
import State.Fan (childTask)
import State.Flow (fanNamed)
import State.Fold (RunState (..), askedAt, nextQId)
import State.Graph (Node (..), Place (..), nodeStep)
import State.Mode (Area, Quality (..), parseByName)
import State.Steps (Row (..), Runner (..), Steps, row)

data Handback = Handback
    { token :: Maybe Token
    -- ^ 'Nothing' when line 1 is no token: a review-lead's report opens with its table.
    , run :: Maybe RunId
    -- ^ A flow role's own run.
    , reviewedHead :: Maybe Sha
    , simplified :: Maybe Sha
    , touches :: Maybe (Set Area)
    {- ^ 'Nothing' when no @Touches:@ line came: 'typeHandback' reads it as
    every area from an implementer and none from a fixer, the safe default.
    -}
    }
    deriving stock (Eq, Show)

data Token
    = Ready OneLine
    | -- | With the @GREW@ line below it when the task outgrew Trivial too.
      NeedsDecision Need (Maybe OneLine)
    | -- | What the sender cannot wait on itself, and its ref: the parent waits.
      Await Waiting OneLine
    | Grew OneLine
    | Blocked OneLine
    | Failed OneLine
    deriving stock (Eq, Show)

data Need
    = -- | Asked already by a flow role's @state ask@, under its id.
      Asks Question
    | StuckOn OneLine
    | PlanWrong OneLine
    | -- | No kind given: the reader triages it.
      Untyped OneLine
    deriving stock (Eq, Show)

data Waiting = Ci
    deriving stock (Eq, Show, Enum, Bounded)

parseHandback :: Text -> Either Text Handback
parseHandback message = do
    token <- withGrew (trailer "GREW ") =<< parseToken first
    run <- traverse (\raw -> maybe (Left ("Run: " <> raw <> " is no run id")) Right (parseRunId raw)) (trailer "Run: ")
    reviewedHead <- traverse (sha "Reviewed head:") (trailer "Reviewed head:")
    simplified <- traverse (sha "Simplified:") (trailer "Simplified:")
    touches <- traverse parseTouches (trailer "Touches:")
    Right Handback {token, run, reviewedHead, simplified, touches}
  where
    (first, rest) = case Text.lines message of
        [] -> ("", [])
        -- An agent may paste the line as @state next@ delivered it.
        top : below -> (fromMaybe top (Text.stripPrefix "HANDBACK " top), below)
    -- The last such line wins, as a re-review's report repeats its head.
    trailer prefix = case [value | line <- rest, Just value <- [Text.stripPrefix prefix line]] of
        [] -> Nothing
        values -> Just (last values)
    sha label raw = case Text.strip raw of
        "" -> Left (label <> " names no sha")
        named -> Right (Sha named)

-- | A @GREW@ line below line 1 follows a @NEEDS_DECISION@ only.
withGrew :: Maybe Text -> Maybe Token -> Either Text (Maybe Token)
withGrew below token = case (below, token) of
    (Nothing, _) -> Right token
    (Just why, Just (NeedsDecision need _)) -> Just . NeedsDecision need . Just <$> oneLine why
    (Just _, Just (Ready _)) -> misplaced
    (Just _, Just (Await _ _)) -> misplaced
    (Just _, Just (Grew _)) -> misplaced
    (Just _, Just (Blocked _)) -> misplaced
    (Just _, Just (Failed _)) -> misplaced
    (Just _, Nothing) -> misplaced
  where
    misplaced = Left "a GREW line below line 1 follows NEEDS_DECISION only: put GREW <why> on line 1"

parseToken :: Text -> Either Text (Maybe Token)
parseToken line = case word of
    "READY" -> Just . Ready <$> oneLine payload
    "NEEDS_DECISION" -> Just . (`NeedsDecision` Nothing) <$> parseNeed payload
    "AWAIT" -> case Text.breakOn " " payload of
        ("ci", ref) -> Just . Await Ci <$> oneLine (Text.drop 1 ref)
        (other, _) -> Left ("AWAIT " <> other <> ": only ci is awaited")
    "GREW" -> Just . Grew <$> oneLine payload
    "BLOCKED" -> Just . Blocked <$> oneLine payload
    "FAILED" -> Just . Failed <$> oneLine payload
    _ -> Right Nothing
  where
    (word, payload) = Text.drop 1 <$> Text.breakOn " " line

parseNeed :: Text -> Either Text Need
parseNeed payload = case (labelled "stuck:", labelled "plan wrong:", asks) of
    (Just why, _, _) -> StuckOn <$> oneLine why
    (_, Just finding, _) -> PlanWrong <$> oneLine finding
    (_, _, Just question) -> Right (Asks question)
    (Nothing, Nothing, Nothing) -> Untyped <$> oneLine payload
  where
    labelled label = (\after -> Text.stripPrefix " " after `orElse` after) <$> Text.stripPrefix label payload
    -- needsDecision's shape: @<Kind> <qid>: <question>@.
    asks = do
        let (kindWord, afterKind) = Text.breakOn " " payload
            (qidWord, afterQId) = Text.breakOn ": " (Text.drop 1 afterKind)
        kind <- parseKind kindWord
        qid <- parseQId qidWord
        text <- parseOneLine =<< Text.stripPrefix ": " afterQId
        Just (Question qid kind text)
    orElse stripped whole = fromMaybe whole stripped

parseTouches :: Text -> Either Text (Set Area)
parseTouches raw = case Text.strip raw of
    "none" -> Right Set.empty
    names -> Set.fromList <$> traverse (area . Text.strip) (Text.splitOn "," names)
  where
    area name =
        maybe
            (Left ("Touches: names " <> name <> ", not one of " <> Text.intercalate ", " (map areaText [minBound .. maxBound]) <> " or none"))
            Right
            (parseByName areaText name)

touchesText :: Set Area -> Text
touchesText areas = case Set.toList areas of
    [] -> "none"
    named -> Text.intercalate ", " (map areaText named)

oneLine :: Text -> Either Text OneLine
oneLine raw = maybe (Left (raw <> " holds a line break")) Right (parseOneLine raw)

renderHandback :: Handback -> Text
renderHandback handback =
    Text.unlines $
        maybe "" tokenLine handback.token
            : catMaybes
                [ ("GREW " <>) . oneLineText <$> (grewBelow =<< handback.token)
                , ("Run: " <>) . runIdText <$> handback.run
                , ("Reviewed head: " <>) . shaText <$> handback.reviewedHead
                , ("Simplified: " <>) . shaText <$> handback.simplified
                , ("Touches: " <>) . touchesText <$> handback.touches
                ]

grewBelow :: Token -> Maybe OneLine
grewBelow = \case
    NeedsDecision _ grew -> grew
    Ready _ -> Nothing
    Await _ _ -> Nothing
    Grew _ -> Nothing
    Blocked _ -> Nothing
    Failed _ -> Nothing

-- | Line 1 of a hand-back.
tokenLine :: Token -> Text
tokenLine = \case
    Ready ref -> spaced "READY" (oneLineText ref)
    NeedsDecision need _ -> case need of
        Asks question -> needsDecision question
        StuckOn why -> needing ("stuck: " <> oneLineText why)
        PlanWrong finding -> needing (planWrong (oneLineText finding))
        Untyped question -> needing (oneLineText question)
    Await Ci ref -> spaced "AWAIT ci" (oneLineText ref)
    Grew why -> spaced "GREW" (oneLineText why)
    Blocked why -> spaced "BLOCKED" (oneLineText why)
    Failed why -> spaced "FAILED" (oneLineText why)
  where
    needing = spaced "NEEDS_DECISION"

-- | The hand-back line a run stopped under a parent sends it.
stopLine :: Stop -> Text
stopLine = uncurry spaced . stopWire

-- | Where a finished task's PR stands: POC keeps a draft, set aside.
readyState :: Quality -> Url -> TaskState
readyState quality pr = case quality of
    Poc -> Parked "POC" (Just pr)
    Balanced -> InReview pr
    Max -> InReview pr

planWrong :: Text -> Text
planWrong finding = snd (stopToken Replan) <> finding

-- | The token, and its payload when it has one.
spaced :: Text -> Text -> Text
spaced word payload
    | Text.null payload = word
    | otherwise = word <> " " <> payload

-- | What a hand-back records, and a question for the run itself to triage.
data Typed = Typed {events :: [Event], untriaged :: Maybe OneLine}
    deriving stock (Eq, Show)

{- | A worker's hand-back as the run at its step records it. @READY@ is the
step's done outcome, from the step's own runner only; a question is asked;
@BLOCKED@, @FAILED@, a plan found wrong and a question with no kind are the
run's own to triage (@state ask --from@): a worker's failure does not stop
the run. The sha is the worktree's HEAD.
-}
typeHandback :: Steps -> RunState -> Maybe Sha -> AgentRole -> Handback -> Either Text Typed
typeHandback steps state worktreeHead agent handback = case [fan | At place <- [state.at], Just fan <- [fanNamed place.name], fanRole fan == agent] of
    _ : _ -> fromChild state handback
    [] -> fromWorker steps state worktreeHead agent handback

{- | A child run's hand-back at the fan-out: what it said, under its run id,
which it must name. A question it asked joins this run's pending; its stop
leaves the task to another child or a park, and is this run's to triage.
-}
fromChild :: RunState -> Handback -> Either Text Typed
fromChild state handback = case handback.run of
    Nothing -> Left "a child's hand-back names its run: add Run: <run id> as line 2"
    Just child -> case handback.token of
        Nothing -> Left "line 1 is no token: one of READY, NEEDS_DECISION, AWAIT, GREW, BLOCKED, FAILED"
        Just (Ready summary) -> Right (Typed (said (Finished summary) : prMoved summary) Nothing)
        -- A GREW below it is the child's own size, not this run's.
        Just token@(NeedsDecision need _) -> case need of
            Asks question -> Right (Typed [said (AsksUp question.qid), Asked (Asking question (askedAt state) (ChildRun child))] Nothing)
            PlanWrong _ -> ended token
            StuckOn _ -> unasked
            Untyped _ -> unasked
        Just (Await Ci ref) -> Right (Typed [said (AwaitsCi ref)] Nothing)
        Just token@(Grew _) -> ended token
        Just token@(Blocked _) -> ended token
        Just token@(Failed _) -> ended token
      where
        said = HandedBack child
        -- A READY naming its PR first puts the task in review, a POC task's parked as a draft.
        prMoved summary = case (Text.words (oneLineText summary), childTask state.fanOut child) of
            (pr : _, Just task) | "https://" `Text.isPrefixOf` pr -> [TaskMoved task.id (readyState task.quality (Url pr))]
            _ -> []
        -- Read back as the log reads it, so a fuel stop stays one.
        ended token = case parseStopLine (tokenLine token) of
            Just stop -> Typed [said (Ended stop)] . Just <$> oneLine (tokenLine token)
            Nothing -> Left ("line 1 is no stop: " <> tokenLine token)
        unasked = Left "a child asks by state ask in its own run: hand back NEEDS_DECISION <Kind> <qid>: <question>"

fromWorker :: Steps -> RunState -> Maybe Sha -> AgentRole -> Handback -> Either Text Typed
fromWorker steps state worktreeHead agent handback = case handback.token of
    Nothing -> recorded <$> done True
    Just (Ready _) -> recorded <$> done False
    Just token@(NeedsDecision need grew) ->
        let grown = [Event.Grew (oneLineText why) | Just why <- [grew]]
         in case need of
                Asks question -> Right (recorded (asked question <> grown))
                StuckOn why -> Right (recorded (asked (Question (nextQId state) Stuck why) <> grown))
                PlanWrong _ -> triage grown token
                Untyped _ -> triage grown token
    -- The parent waits: nothing changes in this run.
    Just (Await _ _) -> Right (recorded [])
    Just (Grew why) -> Right (recorded [Event.Grew (oneLineText why)])
    Just token@(Blocked _) -> triage [] token
    Just token@(Failed _) -> triage [] token
  where
    recorded events = Typed events Nothing
    -- Logged, so @state next@ advises the triage until the run asks it.
    triage grown token = (\line -> Typed (grown <> [Event.WorkerHandedBack agent line]) (Just line)) <$> oneLine (tokenLine token)
    asked question = [Asked (Asking question (askedAt state) asker)]
    asker = maybe (Subagent agent) ChildRun handback.run
    done isReport = do
        SomeStep s <- maybe (Left "the run is at no step a subagent runs") Right (nodeStep state.at)
        let name@(StateName label) = stepName s
            AgentRole roleName = agent
        case (row steps s).runner of
            Agent runner | runner == agent -> Right ()
            Agent (AgentRole runner) -> Left (label <> " is run by " <> runner <> ", not " <> roleName)
            Inline -> Left (label <> " runs inline, not by " <> roleName)
        if isReport && name /= stepName Cap.Review
            then Left "line 1 is no token: one of READY, NEEDS_DECISION, AWAIT, GREW, BLOCKED, FAILED"
            else doneOf s
    doneOf :: Step i e o -> Either Text [Event]
    doneOf = \case
        Cap.Research -> Right []
        Cap.SimplifyP -> took SimplifyPlanDone
        Cap.Alternative -> took AlternativeDone
        -- An implementer that names no areas may have touched any (#360's state help).
        Cap.Implement -> took . ImplementDone =<< commit (Set.fromList [minBound .. maxBound])
        Cap.Refactor -> took . RefactorDone =<< atHead
        Cap.Review -> took . ReviewRows =<< required "Reviewed head: <sha>" handback.reviewedHead
        Cap.Fix -> took . FixDone =<< commit Set.empty
        Cap.Describe -> took . DescribeDone =<< atHead
        Cap.SimplifyPR -> took . SimplifyPrDone =<< required "Simplified: <sha>" handback.simplified
        Cap.FixPR -> took . FixPrDone =<< atHead
        Cap.Interview -> inline Cap.Interview
        Cap.PlanS -> inline Cap.PlanS
        Cap.Confirm -> inline Cap.Confirm
        Cap.Draft -> inline Cap.Draft
        Cap.Pick -> inline Cap.Pick
        Cap.AwaitCi -> inline Cap.AwaitCi
        Cap.Ready -> inline Cap.Ready
        Cap.Breakdown -> inline Cap.Breakdown
        Cap.Merge -> inline Cap.Merge
    inline :: Step i e o -> Either Text [Event]
    inline s = let StateName label = stepName s in Left (label <> " has no done a subagent hands back")
    took :: Outcome -> Either Text [Event]
    took outcome = Right [Event.Took outcome]
    atHead :: Either Text Sha
    atHead = required "HEAD (run it in the worktree)" worktreeHead
    commit :: Set Area -> Either Text Commit
    commit unstated = (\sha -> Commit sha (fromMaybe unstated handback.touches)) <$> atHead
    required :: Text -> Maybe a -> Either Text a
    required what = maybe (Left ("no " <> what)) Right
