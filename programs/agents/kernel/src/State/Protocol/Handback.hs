{- | A worker's hand-back on the wire (#360): a token on line 1, then the
trailer lines the kernel reads anywhere below it; other lines are prose.
'parseHandback' and 'renderHandback' are the two directions of the one
format, and 'typeHandback' turns a parsed hand-back into what the run records.
-}
module State.Protocol.Handback (
    Handback (..),
    Token (..),
    Need (..),
    Waiting (..),
    parseHandback,
    parseTouches,
    renderHandback,
    tokenLine,
    stopLine,
    Typed (..),
    typeHandback,
) where

import Data.Maybe (catMaybes, fromMaybe, isJust, listToMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import State.Category.Flow (ScopePath)
import State.Category.Fuel (Area, parseByName)
import State.Category.Graph (Node (..), Place (..))
import State.Category.Step (Outcome, Sing, SomeStep (..), StateName (..), StepSet, stepName)
import State.Role (leads)
import State.Run.Ask (Kind (Stuck), OneLine, Question (..), needsDecision, oneLineText, parseKind, parseOneLine, parseQId)
import State.Run.Codec (areaText, parseStopLine, shaText, stopToken, stopWire, waitingText)
import State.Run.Event (AgentRole (..), Asker (..), Asking (..), Commit (..), Event (Asked, HandedBack, TaskMoved), RunId, Said (..), Sha (..), Shape (..), Stop, StopReason (Replan), Task (..), TaskState (..), Url (..), Waiting (..), parseRunId, runIdText, tookIn)
import State.Run.Event qualified as Event
import State.Run.Fan (Fan, childTask)
import State.Run.Fold (RunState (..), ScopedFan (..), askedAt, fanIn, nextQId)
import State.Step.Build (Outcome (..))
import State.Step.Build qualified as Build
import State.Step.Catalog (AnyStep (..), KnownLayer, Layer (..), stepNamed)
import State.Step.Choice (Sing (Hub), nodeChoice)
import State.Step.Fan qualified as Fan
import State.Step.Gather qualified as Gather
import State.Step.Plan (Outcome (..))
import State.Step.Plan qualified as Plan
import State.Step.Review (Outcome (..))
import State.Step.Review qualified as Review
import State.Step.Ship (Outcome (..))
import State.Step.Ship qualified as Ship
import State.Table (Row (..), Runner (..), Steps, row, stepsRunBy)

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
    | NeedsDecision Need
    | -- | What the sender cannot wait on itself, and its ref: the parent waits.
      Await Waiting OneLine
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

parseHandback :: Text -> Either Text Handback
parseHandback message = do
    token <- parseToken first
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

parseToken :: Text -> Either Text (Maybe Token)
parseToken line = case word of
    "READY" -> Just . Ready <$> oneLine payload
    "NEEDS_DECISION" -> Just . NeedsDecision <$> parseNeed payload
    "AWAIT" -> case parseByName waitingText what of
        Just waiting -> Just . Await waiting <$> oneLine refs
        Nothing -> Left ("AWAIT " <> what <> ": only " <> Text.intercalate " or " (map waitingText [minBound .. maxBound]) <> " is awaited")
    "BLOCKED" -> Just . Blocked <$> oneLine payload
    "FAILED" -> Just . Failed <$> oneLine payload
    _ -> Right Nothing
  where
    (word, payload) = Text.drop 1 <$> Text.breakOn " " line
    (what, refs) = Text.drop 1 <$> Text.breakOn " " payload

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
                [ ("Run: " <>) . runIdText <$> handback.run
                , ("Reviewed head: " <>) . shaText <$> handback.reviewedHead
                , ("Simplified: " <>) . shaText <$> handback.simplified
                , ("Touches: " <>) . touchesText <$> handback.touches
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
    Await waiting ref -> spaced ("AWAIT " <> waitingText waiting) (oneLineText ref)
    Blocked why -> spaced "BLOCKED" (oneLineText why)
    Failed why -> spaced "FAILED" (oneLineText why)
  where
    needing = spaced "NEEDS_DECISION"

-- | The hand-back line a run stopped under a parent sends it.
stopLine :: Stop -> Text
stopLine = uncurry spaced . stopWire

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
typeHandback steps state worktreeHead agent handback = case [ScopedFan place.scope fan | Just _ <- [leads agent], At place <- [state.at], Just fan <- [Fan.fanNamed place.name]] of
    here : _ -> fromChild state (fanIn state.fans here) handback
    [] -> fromWorker steps state worktreeHead agent handback

{- | A child run's hand-back at the fan-out: what it said, under its run id,
which it must name. A question it asked joins this run's pending; its stop
leaves the task to another child or a park, and is this run's to triage.
-}
fromChild :: RunState -> Fan -> Handback -> Either Text Typed
fromChild state fan handback = case handback.run of
    Nothing -> Left "a child's hand-back names its run: add Run: <run id> as line 2"
    Just child -> case handback.token of
        Nothing -> Left "line 1 is no token: one of READY, NEEDS_DECISION, AWAIT, BLOCKED, FAILED"
        Just (Ready summary) -> Right (Typed (said (Finished summary) : prMoved summary) Nothing)
        Just token@(NeedsDecision need) -> case need of
            Asks question -> Right (Typed [said (AsksUp question.qid), Asked (Asking question (askedAt state) (ChildRun child))] Nothing)
            PlanWrong _ -> ended token
            StuckOn _ -> unasked
            Untyped _ -> unasked
        Just (Await waiting ref) -> Right (Typed [said (Awaits waiting ref)] Nothing)
        Just token@(Blocked _) -> ended token
        Just token@(Failed _) -> ended token
      where
        said = HandedBack child
        -- A round's READY keeps its PR; any other naming its PR first puts the task in review.
        prMoved summary = case childTask fan child of
            Just task -> case (task.shape, Text.words (oneLineText summary)) of
                (RoundOn pr, _) -> [TaskMoved task.id (Kept pr)]
                (OwnPr, pr : _) | "https://" `Text.isPrefixOf` pr -> [TaskMoved task.id (InReview (Url pr))]
                (OwnPr, _) -> []
            Nothing -> []
        -- Read back as the log reads it, so an out-of-rounds stop stays one.
        ended token = case parseStopLine (tokenLine token) of
            Just stop -> Typed [said (Ended stop)] . Just <$> oneLine (tokenLine token)
            Nothing -> Left ("line 1 is no stop: " <> tokenLine token)
        unasked = Left "a child asks by state ask in its own run: hand back NEEDS_DECISION <Kind> <qid>: <question>"

fromWorker :: Steps -> RunState -> Maybe Sha -> AgentRole -> Handback -> Either Text Typed
fromWorker steps state worktreeHead agent handback = case handback.token of
    -- A choice's worker reports in its own shape (a researcher's opens with its index): any hand-back closes its child.
    Nothing -> recorded <$> done (not atChoice)
    Just (Ready _) -> recorded <$> done False
    Just token@(NeedsDecision need) ->
        closing <$> case need of
            Asks question -> Right (recorded (asked question))
            StuckOn why -> Right (recorded (asked (Question (nextQId state) Stuck why)))
            PlanWrong _ -> triage token
            Untyped _ -> triage token
    -- The parent waits: nothing changes in this run.
    Just (Await _ _) -> Right (recorded [])
    Just token@(Blocked _) -> closing <$> triage token
    Just token@(Failed _) -> closing <$> triage token
  where
    recorded events = Typed events Nothing
    -- A choice's worker is done whatever it says: its child hands back first.
    closing typed = case (atChoice, done False) of
        (True, Right events) -> typed {events = events <> typed.events}
        _ -> typed
    atChoice = isJust (nodeChoice state.at)
    -- At a choice, the step is the action this worker runs.
    stepHere = listToMaybe ([(place, step) | At place <- [state.at], Just step <- [stepNamed place.name]] <> [(place, step) | atChoice, At place <- [state.at], step <- stepsRunBy steps agent])
    -- Logged, so @state next@ advises the triage until the run asks it.
    triage token = (\line -> Typed [Event.WorkerHandedBack agent line] (Just line)) <$> oneLine (tokenLine token)
    asked question = [Asked (Asking question (askedAt state) asker)]
    asker = maybe (Subagent agent) ChildRun handback.run
    done isReport = do
        (place, step@(AnyStep _ (SomeStep s))) <- maybe (Left "the run is at no step a subagent runs") Right stepHere
        let name@(StateName label) = stepName s
            AgentRole roleName = agent
        case (row steps s).runner of
            Agent runner _ | runner == agent -> Right ()
            Agent (AgentRole runner) _ -> Left (label <> " is run by " <> runner <> ", not " <> roleName)
            Inline -> Left (label <> " runs inline, not by " <> roleName)
        if isReport && name `notElem` [stepName Review.Review, stepName Review.ReReview]
            then Left "line 1 is no token: one of READY, NEEDS_DECISION, AWAIT, BLOCKED, FAILED"
            else doneOf place.scope step
    -- One arm per layer, each total over its steps; the outcome is in the step's scope.
    doneOf :: ScopePath -> AnyStep -> Either Text [Event]
    doneOf scope (AnyStep l (SomeStep s)) = case l of
        GatherLayer -> case s of
            Gather.Research -> took Gather.ResearchHandedBack
            Gather.Interview -> inline s
        PlanLayer -> case s of
            Plan.SimplifyP -> took SimplifyPlanDone
            Plan.PlanS -> inline s
            Plan.Confirm -> inline s
        BuildLayer -> case s of
            -- An implementer that names no areas may have touched any (#360's state help).
            Build.Implement -> took . ImplementDone =<< commit (Set.fromList [minBound .. maxBound])
            Build.Refactor -> took . RefactorDone =<< atHead
            Build.Draft -> inline s
        ReviewLayer -> case s of
            Review.Review -> took . ReviewRows =<< required "Reviewed head: <sha>" handback.reviewedHead
            Review.Fix -> took . FixDone =<< commit Set.empty
            Review.Pick -> inline s
            Review.ReReview -> took . ReReviewRows =<< required "Reviewed head: <sha>" handback.reviewedHead
        ShipLayer -> case s of
            Ship.Describe -> took . DescribeDone =<< atHead
            Ship.SimplifyPR -> took . SimplifyPrDone =<< required "Simplified: <sha>" handback.simplified
            Ship.FixPR -> took . FixPrDone =<< atHead
            Ship.AwaitCi -> inline s
            Ship.Ready -> inline s
        FanLayer -> case s of
            Fan.Breakdown _ -> inline s
            Fan.FanOut _ -> inline s
            Fan.Merge _ -> inline s
        ChoiceLayer -> case s of
            Hub _ -> inline s
      where
        took :: (KnownLayer k) => Outcome (s :: k) l -> Either Text [Event]
        took outcome = Right [tookIn scope outcome]
    inline :: (StepSet k) => Sing (s :: k) -> Either Text [Event]
    inline s = let StateName label = stepName s in Left (label <> " has no done a subagent hands back")
    atHead :: Either Text Sha
    atHead = required "HEAD (run it in the worktree)" worktreeHead
    commit :: Set Area -> Either Text Commit
    commit unstated = (\sha -> Commit sha (fromMaybe unstated handback.touches)) <$> atHead
    required :: Text -> Maybe a -> Either Text a
    required what = maybe (Left ("no " <> what)) Right
