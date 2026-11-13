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
    renderHandback,
    tokenLine,
    stopLine,
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
import State.Codec (areaText, shaText)
import State.Event (AgentRole (..), Asker (..), Asking (..), Commit (..), Event (Asked), Outcome (..), RunId, Sha (..), Stop (..), StopReason (Fuel, Outgrown, Replan), parseRunId, runIdText)
import State.Event qualified as Event
import State.Fold (RunState (..), askedAt, nextQId)
import State.Graph (nodeStep)
import State.Mode (Area, parseByName)
import State.Steps (Row (..), Runner (..), Steps, row)

data Handback = Handback
    { token :: Maybe Token
    -- ^ 'Nothing' when line 1 is no token: a review-lead's report opens with its table.
    , grew :: Maybe OneLine
    -- ^ A @GREW@ line below a @NEEDS_DECISION@ one: the task outgrew Trivial too.
    , run :: Maybe RunId
    -- ^ A flow role's own run.
    , reviewedHead :: Maybe Sha
    , simplified :: Maybe Sha
    , touches :: Set Area
    -- ^ A @Touches: none@ line, and no line, are both the empty set.
    }
    deriving stock (Eq, Show)

data Token
    = Ready OneLine
    | NeedsDecision Need
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
    token <- parseToken first
    grew <- traverse oneLine (trailer "GREW ")
    run <- traverse (\raw -> maybe (Left ("Run: " <> raw <> " is no run id")) Right (parseRunId raw)) (trailer "Run: ")
    reviewedHead <- traverse (sha "Reviewed head:") (trailer "Reviewed head:")
    simplified <- traverse (sha "Simplified:") (trailer "Simplified:")
    touches <- maybe (Right Set.empty) parseTouches (trailer "Touches:")
    Right Handback {token, grew, run, reviewedHead, simplified, touches}
  where
    (first, rest) = case Text.lines message of
        [] -> ("", [])
        top : below -> (top, below)
    -- The last such line wins, as a re-review's report repeats its head.
    trailer prefix = case [value | line <- rest, Just value <- [Text.stripPrefix prefix line]] of
        [] -> Nothing
        values -> Just (last values)
    sha label raw = case Text.strip raw of
        "" -> Left (label <> " names no sha")
        named -> Right (Sha named)

parseToken :: Text -> Either Text (Maybe Token)
parseToken line = case word of
    "READY" -> Just . Ready <$> oneLine payload
    "NEEDS_DECISION" -> Just . NeedsDecision <$> parseNeed payload
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

oneLine :: Text -> Either Text OneLine
oneLine raw = maybe (Left (raw <> " holds a line break")) Right (parseOneLine raw)

renderHandback :: Handback -> Text
renderHandback handback =
    Text.unlines $
        maybe "" tokenLine handback.token
            : catMaybes
                [ ("GREW " <>) . oneLineText <$> handback.grew
                , ("Run: " <>) . runIdText <$> handback.run
                , ("Reviewed head: " <>) . shaText <$> handback.reviewedHead
                , ("Simplified: " <>) . shaText <$> handback.simplified
                , if Set.null handback.touches
                    then Nothing
                    else Just ("Touches: " <> Text.intercalate ", " (map areaText (Set.toList handback.touches)))
                ]

-- | Line 1 of a hand-back.
tokenLine :: Token -> Text
tokenLine = \case
    Ready ref -> spaced "READY" (oneLineText ref)
    NeedsDecision need -> case need of
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
stopLine stop = case stop.reason of
    Event.Blocked -> spaced "BLOCKED" stop.why
    Event.Failed -> spaced "FAILED" stop.why
    Replan -> spaced "NEEDS_DECISION" (planWrong stop.why)
    Fuel -> spaced "BLOCKED" ("out of fuel: " <> stop.why)
    Outgrown -> spaced "GREW" stop.why

planWrong :: Text -> Text
planWrong finding = "plan wrong: " <> finding

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
typeHandback steps state worktreeHead agent handback = case handback.token of
    Nothing -> recorded <$> done True
    Just (Ready _) -> recorded <$> done False
    Just (NeedsDecision need) -> case need of
        Asks question -> Right (recorded (asked question <> grown))
        StuckOn why -> Right (recorded (asked (Question (nextQId state) Stuck why) <> grown))
        PlanWrong _ -> triage (NeedsDecision need)
        Untyped _ -> triage (NeedsDecision need)
    -- The parent waits: nothing changes in this run.
    Just (Await _ _) -> Right (recorded [])
    Just (Grew why) -> Right (recorded [Event.Grew (oneLineText why)])
    Just token@(Blocked _) -> triage token
    Just token@(Failed _) -> triage token
  where
    recorded events = Typed events Nothing
    triage token = Typed grown . Just <$> oneLine (tokenLine token)
    grown = [Event.Grew (oneLineText why) | Just why <- [handback.grew]]
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
        Cap.Implement -> took . ImplementDone =<< commit
        Cap.Refactor -> took . RefactorDone =<< atHead
        Cap.Review -> took . ReviewRows =<< required "Reviewed head: <sha>" handback.reviewedHead
        Cap.Fix -> took . FixDone =<< commit
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
    commit :: Either Text Commit
    commit = (\sha -> Commit sha handback.touches) <$> atHead
    required :: Text -> Maybe a -> Either Text a
    required what = maybe (Left ("no " <> what)) Right
