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
    TokenWord (..),
    tokenWordText,
    tokenWords,
    Refusal (..),
    refusalText,
    areaNames,
    parseHandback,
    parseTouches,
    renderHandback,
    tokenLine,
    stopLine,
    Typed (..),
    typeHandback,
    typeDirectHandback,
) where

import Control.Applicative ((<|>))
import Data.Bifunctor qualified as Bifunctor
import Data.List (genericLength)
import Data.Maybe (
    catMaybes,
    fromMaybe,
    isJust,
    listToMaybe,
    mapMaybe,
    maybeToList,
 )
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import State.Category.Flow (ScopePath)
import State.Category.Fuel (Area, parseByName)
import State.Category.Graph (
    Metered (..),
    Node (..),
    OpenGraph,
    Place (..),
    placeName,
 )
import State.Category.Step (
    Outcome,
    Sing,
    SomeStep (..),
    StateName (..),
    StepSet,
    stateNameText,
    stepName,
 )
import State.Role (leads)
import State.Run.Ask (
    Kind (Stuck),
    OneLine,
    QId (..),
    Question (..),
    oneLineText,
    parseKind,
    parseOneLine,
    parseQId,
    questionLine,
 )
import State.Run.Codec (
    areaText,
    parseStopLine,
    shaText,
    stopToken,
    stopWire,
    waitingText,
 )
import State.Run.Event (
    AgentId,
    AgentRole (..),
    Asker (..),
    Asking (..),
    Commit (..),
    Event (Asked, Gapped, HandedBack, TaskMoved),
    RunId,
    Said (..),
    Sha (..),
    Shape (..),
    Stop,
    StopReason (Replan),
    Task (..),
    TaskState (..),
    Url (..),
    Waiting (..),
    parseRunId,
    runIdText,
    tookIn,
 )
import State.Run.Event qualified as Event
import State.Run.Fan (Fan, childTask)
import State.Run.Fold (
    RunState (..),
    ScopedFan (..),
    askedAt,
    fanIn,
    forks,
    returnOf,
    untaskedFan,
 )
import State.Run.Gap (GapArea (..), GapLine, gapLineText, lineGap, parseGapLine)
import State.Step.Build (Outcome (..))
import State.Step.Build qualified as Build
import State.Step.Catalog (AnyStep (..), KnownLayer, Layer (..), stepNamed)
import State.Step.Fan qualified as Fan
import State.Step.Gather qualified as Gather
import State.Step.Plan (Outcome (..))
import State.Step.Plan qualified as Plan
import State.Step.Request qualified as Request
import State.Step.Review (Outcome (..))
import State.Step.Review qualified as Review
import State.Step.Ship (Outcome (..))
import State.Step.Ship qualified as Ship
import State.Step.Ticket qualified as Ticket
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
    , gaps :: [GapLine]
    -- ^ Every @Gap:@ line, in order: unlike the other trailers, each one counts.
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

-- | Why a hand-back records nothing: line 1 opens with no 'TokenWord', a @Touches:@ name is no 'Area', or another reason.
data Refusal = NoToken | NoArea Text | Why Text
    deriving stock (Eq, Show)

refusalText :: Refusal -> Text
refusalText = \case
    NoToken -> "line 1 is no token: one of " <> Text.intercalate ", " tokenWords
    NoArea name -> "Touches: names " <> name <> ", not one of " <> areaNames
    Why why -> why

-- | The word line 1 opens with, one per 'Token' case.
data TokenWord = ReadyWord | NeedsDecisionWord | AwaitWord | BlockedWord | FailedWord
    deriving stock (Bounded, Enum)

tokenWordText :: TokenWord -> Text
tokenWordText = \case
    ReadyWord -> "READY"
    NeedsDecisionWord -> "NEEDS_DECISION"
    AwaitWord -> "AWAIT"
    BlockedWord -> "BLOCKED"
    FailedWord -> "FAILED"

-- | Every area a @Touches:@ line may name, and none.
areaNames :: Text
areaNames = Text.intercalate ", " (map areaText [minBound .. maxBound]) <> " or none"

-- | Every word line 1 may open with, in 'Token''s order.
tokenWords :: [Text]
tokenWords = map tokenWordText [minBound .. maxBound]

data Need
    = -- | Asked already by a flow role's @state ask@, under its id.
      Asks Question
    | StuckOn OneLine
    | PlanWrong OneLine
    | -- | No kind given: the reader triages it.
      Untyped OneLine
    deriving stock (Eq, Show)

parseHandback :: Text -> Either Refusal Handback
parseHandback message = do
    token <- parseToken first
    run <-
        traverse
            ( \raw ->
                maybe (Left (Why ("Run: " <> raw <> " is no run id"))) Right (parseRunId raw)
            )
            (trailer "Run: ")
    reviewedHead <- traverse (sha "Reviewed head:") (trailer "Reviewed head:")
    simplified <- traverse (sha "Simplified:") (trailer "Simplified:")
    touches <- traverse parseTouches (trailer "Touches:")
    let gaps = mapMaybe parseGapLine rest
    Right Handback {token, run, reviewedHead, simplified, touches, gaps}
  where
    (first, rest) = case Text.lines message of
        [] -> ("", [])
        -- An agent may paste the line as @state next@ delivered it.
        top : below -> (fromMaybe top (Text.stripPrefix "HANDBACK " top), below)
    values prefix = [value | line <- rest, Just value <- [Text.stripPrefix prefix line]]
    -- The last such line wins, as a re-review's report repeats its head.
    trailer prefix = case values prefix of
        [] -> Nothing
        found -> Just (last found)
    sha label raw = case Text.strip raw of
        "" -> Left (Why (label <> " names no sha"))
        named -> Right (Sha named)

parseToken :: Text -> Either Refusal (Maybe Token)
parseToken line = case parseByName tokenWordText word of
    Just ReadyWord -> Just . Ready <$> line1 payload
    Just NeedsDecisionWord -> Just . NeedsDecision <$> Bifunctor.first Why (parseNeed payload)
    Just AwaitWord -> case parseByName waitingText what of
        Just waiting -> Just . Await waiting <$> line1 refs
        Nothing ->
            Left
                ( Why
                    ( tokenWordText AwaitWord
                        <> " "
                        <> what
                        <> ": only "
                        <> Text.intercalate " or " (map waitingText [minBound .. maxBound])
                        <> " is awaited"
                    )
                )
    Just BlockedWord -> Just . Blocked <$> line1 payload
    Just FailedWord -> Just . Failed <$> line1 payload
    Nothing -> Right Nothing
  where
    (written, payload) = Text.drop 1 <$> Text.breakOn " " line
    -- "READY: done" reads as "READY done": agents often colon the token.
    word = fromMaybe written (Text.stripSuffix ":" written)
    (what, refs) = Text.drop 1 <$> Text.breakOn " " payload
    line1 = Bifunctor.first Why . oneLine

parseNeed :: Text -> Either Text Need
parseNeed payload = case (labelled "stuck:", labelled "plan wrong:", asks) of
    (Just why, _, _) -> StuckOn <$> oneLine why
    (_, Just finding, _) -> PlanWrong <$> oneLine finding
    (_, _, Just question) -> Right (Asks question)
    (Nothing, Nothing, Nothing) -> Untyped <$> oneLine payload
  where
    labelled label =
        (\after -> Text.stripPrefix " " after `orElse` after)
            <$> Text.stripPrefix label payload
    -- questionLine's shape: @<Kind> <qid>: <question>@.
    asks = do
        let (kindWord, afterKind) = Text.breakOn " " payload
            (qidWord, afterQId) = Text.breakOn ": " (Text.drop 1 afterKind)
        kind <- parseKind kindWord
        qid <- parseQId qidWord
        text <- parseOneLine =<< Text.stripPrefix ": " afterQId
        Just (Question qid kind text)
    orElse stripped whole = fromMaybe whole stripped

parseTouches :: Text -> Either Refusal (Set Area)
parseTouches raw = case Text.strip raw of
    "none" -> Right Set.empty
    names -> Set.fromList <$> traverse (area . Text.strip) (Text.splitOn "," names)
  where
    area name = maybe (Left (NoArea name)) Right (parseByName areaText name)

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
                <> map (("Gap: " <>) . gapLineText) handback.gaps

-- | Line 1 of a hand-back.
tokenLine :: Token -> Text
tokenLine = \case
    Ready ref -> spaced (tokenWordText ReadyWord) (oneLineText ref)
    NeedsDecision need -> case need of
        Asks question -> needing (questionLine question)
        StuckOn why -> needing ("stuck: " <> oneLineText why)
        PlanWrong finding -> needing (planWrong (oneLineText finding))
        Untyped question -> needing (oneLineText question)
    Await waiting ref ->
        spaced (tokenWordText AwaitWord <> " " <> waitingText waiting) (oneLineText ref)
    Blocked why -> spaced (tokenWordText BlockedWord) (oneLineText why)
    Failed why -> spaced (tokenWordText FailedWord) (oneLineText why)
  where
    needing = spaced (tokenWordText NeedsDecisionWord)

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
the run. A worker's hand-back also says it returned, when it was logged at
work ('returnOf'). The sha is the worktree's HEAD; the qid is the id of the
next line, which a question the run mints counts on from.
-}
typeHandback ::
    Steps ->
    OpenGraph ->
    RunState ->
    Maybe Sha ->
    QId ->
    AgentRole ->
    Maybe AgentId ->
    Handback ->
    Either Refusal Typed
typeHandback steps g state worktreeHead next agent agentId handback =
    (\typed -> typed {events = typed.events <> gaps}) <$> case [fan | Just child <- [handback.run], Just fan <- [untaskedFan state child]]
        <> [ ScopedFan place.scope fan
           | Just _ <- [leads agent]
           , At place <- [state.at]
           , Just fan <- [Fan.fanNamed place.name]
           ] of
        here : _ -> fromChild state (fanIn state.fans here) handback
        [] ->
            ( \typed -> typed {events = typed.events <> maybeToList (returnOf state agent agentId)}
            )
                <$> fromWorker steps g state worktreeHead next agent handback
  where
    -- Last, so a question's line keeps the qid counted for it.
    gaps =
        map
            ( Gapped
                . lineGap
                    ( GapArea
                        ( stateNameText
                            (maybe (askedAt state) (placeName . fst) (stepHere steps g state agent))
                        )
                    )
                    agent
            )
            handback.gaps

{- | A direct child's hand-back, wherever this run is: only a question is
this run's, which joins its pending to rule on or forward up. The rest
records nothing: no fan-out tracks the child, and the agent that spawned it
reads its reply.
-}
typeDirectHandback :: RunState -> RunId -> Handback -> Either Refusal Typed
typeDirectHandback state child handback = case handback.token of
    Nothing -> Left NoToken
    Just (NeedsDecision need) -> case need of
        Asks question -> Right (Typed [childAsked state child question] Nothing)
        StuckOn _ -> Left unaskedByChild
        Untyped _ -> Left unaskedByChild
        PlanWrong _ -> Right (Typed [] Nothing)
    Just (Ready _) -> Right (Typed [] Nothing)
    Just (Await _ _) -> Right (Typed [] Nothing)
    Just (Blocked _) -> Right (Typed [] Nothing)
    Just (Failed _) -> Right (Typed [] Nothing)

-- | A question a child run asked in its own run, put to this one.
childAsked :: RunState -> RunId -> Question -> Event
childAsked state child question = Asked (Asking question (askedAt state) (ChildRun child))

unaskedByChild :: Refusal
unaskedByChild =
    Why
        ( "a child asks by state ask in its own run: hand back "
            <> tokenWordText NeedsDecisionWord
            <> " <Kind> <qid>: <question>"
        )

{- | A child run's hand-back at the fan-out: what it said, under its run id,
which it must name. A question it asked joins this run's pending; its stop
leaves the task to another child or a park, and is this run's to triage.
-}
fromChild :: RunState -> Fan -> Handback -> Either Refusal Typed
fromChild state fan handback = case handback.run of
    Nothing -> Left (Why "a child's hand-back names its run: add Run: <run id> as line 2")
    Just child -> case handback.token of
        Nothing -> Left NoToken
        Just (Ready summary) -> Right (Typed (said (Finished summary) : prMoved summary) Nothing)
        Just token@(NeedsDecision need) -> case need of
            Asks question ->
                Right
                    (Typed [said (AsksUp question.qid), childAsked state child question] Nothing)
            PlanWrong _ -> ended token
            StuckOn _ -> Left unaskedByChild
            Untyped _ -> Left unaskedByChild
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
            Just stop ->
                Typed [said (Ended stop)] . Just
                    <$> Bifunctor.first Why (oneLine (tokenLine token))
            Nothing -> Left (Why ("line 1 is no stop: " <> tokenLine token))

{- | The step a worker's hand-back closes: the one forked, as a worker of a
group hands back wherever the run is, before its bind too (structured
concurrency); else the step here.
-}
stepHere ::
    Steps -> OpenGraph -> RunState -> AgentRole -> Maybe (Place, AnyStep)
stepHere steps g state agent =
    forkedStep steps g state agent
        <|> listToMaybe
            [(place, step) | At place <- [state.at], Just step <- [stepNamed place.name]]

-- | The step forked that this role runs, if a group's worker of it hands back.
forkedStep ::
    Steps -> OpenGraph -> RunState -> AgentRole -> Maybe (Place, AnyStep)
forkedStep steps g state agent =
    listToMaybe
        [ (metered.place, step)
        | metered <- forks g state
        , step@(AnyStep _ (SomeStep s)) <- stepsRunBy steps agent
        , stepName s == metered.step
        ]

{- | How a step's worker hands back: a report in its own shape, which needs
no token (a reviewer's table, a refine pass's findings), or a token line.
-}
data HandsBack = AsReport | WithToken

fromWorker ::
    Steps ->
    OpenGraph ->
    RunState ->
    Maybe Sha ->
    QId ->
    AgentRole ->
    Handback ->
    Either Refusal Typed
fromWorker steps g state worktreeHead next agent handback = case handback.token of
    -- A forked worker reports in its own shape (a researcher's opens with its index): any hand-back closes its child.
    Nothing -> recorded <$> done (not forked)
    Just (Ready _) -> recorded <$> done False
    Just token@(NeedsDecision need) ->
        closing <$> case need of
            Asks question -> Right (recorded (asked question))
            StuckOn why -> Right (recorded (asked (Question stuckQId Stuck why)))
            PlanWrong _ -> triage token
            Untyped _ -> triage token
    -- The parent waits: nothing changes in this run.
    Just (Await _ _) -> Right (recorded [])
    Just token@(Blocked _) -> closing <$> triage token
    Just token@(Failed _) -> closing <$> triage token
  where
    recorded events = Typed events Nothing
    -- A forked worker is done whatever it says: its child hands back first.
    closing typed = typed {events = donePrefix <> typed.events}
    donePrefix = case (forked, done False) of
        (True, Right events) -> events
        _ -> []
    -- The question's line comes after the done prefix: its qid is that line's id.
    stuckQId = case next of
        QId run n -> QId run (n + genericLength donePrefix)
    forked = isJust (forkedStep steps g state agent)
    -- Logged, so @state next@ advises the triage until the run asks it.
    triage token =
        (\line -> Typed [Event.WorkerHandedBack agent line] (Just line))
            <$> Bifunctor.first Why (oneLine (tokenLine token))
    asked question = [Asked (Asking question (askedAt state) asker)]
    asker = maybe (Subagent agent) ChildRun handback.run
    done isReport = do
        (place, step@(AnyStep _ (SomeStep s))) <-
            maybe
                (Left (Why "the run is at no step a subagent runs"))
                Right
                (stepHere steps g state agent)
        let StateName label = stepName s
            AgentRole roleName = agent
        case (row steps s).runner of
            Agent runner _ | runner == agent -> Right ()
            Agent (AgentRole runner) _ -> Left (Why (label <> " is run by " <> runner <> ", not " <> roleName))
            Inline -> Left (Why (label <> " runs inline, not by " <> roleName))
        let (handsBack, events) = doneOf place.scope step
        case handsBack of
            WithToken | isReport -> Left NoToken
            WithToken -> Bifunctor.first Why events
            AsReport -> Bifunctor.first Why events
    {- One arm per layer, each total over its steps: how the step's worker
    hands back, and its outcome in the step's scope.
    -}
    doneOf :: ScopePath -> AnyStep -> (HandsBack, Either Text [Event])
    doneOf scope (AnyStep l (SomeStep s)) = case l of
        GatherLayer -> case s of
            Gather.Research -> tokened (took Gather.ResearchHandedBack)
            Gather.Interview -> inline s
            Gather.Discuss -> inline s
            Gather.Notes -> inline s
        PlanLayer -> case s of
            Plan.SimplifyP -> reported (took SimplifyPlanDone)
            Plan.StandardsP -> reported (took StandardsPlanDone)
            Plan.AlignP -> reported (took AlignPlanDone)
            Plan.PlanS -> inline s
            Plan.Present -> inline s
            Plan.Confirm -> inline s
        BuildLayer -> case s of
            -- An implementer that names no areas may have touched any (#360's state help).
            Build.Implement ->
                tokened (took . ImplementDone =<< commit (Set.fromList [minBound .. maxBound]))
            Build.Refactor -> tokened (took . RefactorDone =<< atHead)
            Build.Draft -> inline s
        ReviewLayer -> case s of
            Review.Review ->
                reported
                    (took . ReviewRows =<< required "Reviewed head: <sha>" handback.reviewedHead)
            Review.Fix -> tokened (took . FixDone =<< commit Set.empty)
            Review.PickRows -> inline s
            Review.ReReview ->
                reported
                    (took . ReReviewRows =<< required "Reviewed head: <sha>" handback.reviewedHead)
        ShipLayer -> case s of
            Ship.Describe -> tokened (took . DescribeDone =<< atHead)
            Ship.Visual -> tokened (took . VisualDone =<< atHead)
            Ship.SimplifyPR ->
                tokened
                    (took . SimplifyPrDone =<< required "Simplified: <sha>" handback.simplified)
            Ship.FixPR -> tokened (took . FixPrDone =<< atHead)
            Ship.AwaitCi -> inline s
            Ship.Ready -> inline s
        TicketLayer -> case s of
            Ticket.WriteTicket -> inline s
        RequestLayer -> case s of
            Request.OpenPlan -> inline s
            Request.OpenBranch -> inline s
            Request.OpenPr -> inline s
            Request.Direct -> inline s
            Request.Next -> inline s
        FanLayer -> case s of
            Fan.Breakdown _ -> inline s
            Fan.Merge _ -> inline s
        PickLayer -> inline s
        FuelLayer -> inline s
      where
        took :: (KnownLayer k) => Outcome (s :: k) l -> Either Text [Event]
        took outcome = Right [tookIn scope outcome]
    reported events = (AsReport, events)
    tokened events = (WithToken, events)
    inline :: (StepSet k) => Sing (s :: k) -> (HandsBack, Either Text [Event])
    inline s =
        let StateName label = stepName s
         in (WithToken, Left (label <> " has no done a subagent hands back"))
    atHead :: Either Text Sha
    atHead = required "HEAD (run it in the worktree)" worktreeHead
    commit :: Set Area -> Either Text Commit
    commit unstated = (\sha -> Commit sha (fromMaybe unstated handback.touches)) <$> atHead
    required :: Text -> Maybe a -> Either Text a
    required what = maybe (Left ("no " <> what)) Right
