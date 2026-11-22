{- | The grammar of @state record@: every event a lead records by hand, its
arguments' usage and their parser. The CLI parses it and the advice prints
it, from this one table.
-}
module State.Protocol.Record (
    Recording (..),
    Recordable (..),
    Flag (..),
    Arity (..),
    recordables,
    usageOf,
    recordCommand,
    Option (..),
    commandOption,
    recordOption,
    goes,
    extend,
    extendOption,
    spawnChildOption,
    capRecords,
    Args (..),
    option,
    options,
    choices,
) where

import Data.Bifunctor qualified as Bifunctor
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import State.Category.Flow (ScopePath, nameText, unqualify)
import State.Category.Fuel (fuelName, parseByName, parseFuel)
import State.Category.Graph (
    Arrow (..),
    Edge (..),
    Node (..),
    OpenGraph (..),
    Place,
    leaving,
    outOf,
    placeName,
 )
import State.Category.Meter (AtCap (..))
import State.Category.Step (EventName, builtEvent, eventText, stateNameText)
import State.Protocol.Handback (parseTouches, refusalText)
import State.Role (drawnOutcomes)
import State.Run.Codec (judgementText)
import State.Run.Codec qualified as Codec
import State.Run.Event (
    Branch (..),
    Check (..),
    Commit (..),
    DraftPr (..),
    Event (..),
    Label (..),
    Picks (..),
    Requirement (..),
    Sha,
    Target (..),
    TaskId (..),
    TaskState (..),
    Url (..),
    parseRunId,
    tookIn,
 )
import State.Step.Artifact (parsePrUrl, prUrlRule)
import State.Step.Build (Outcome (..), Sing (..))
import State.Step.Catalog qualified as Catalog
import State.Step.Fan (Outcome (..), Sing (..), fanOuts)
import State.Step.Fuel (Outcome (LevelSet), Sing (Fuel))
import State.Step.Gather (Outcome (..))
import State.Step.Plan (Outcome (..), Sing (..))
import State.Step.Request (Outcome (..), Sing (..))
import State.Step.Review (Outcome (..), Sing (..))
import State.Step.Ship (Outcome (..), Sing (..))
import State.Step.Ticket (Outcome (..), Sing (..))

{- | An event to record. Most carry the commit the worktree is at, which only
the shell can read; a breakdown or an added task is read from a file, by the shell too.
-}
data Recording
    = Plain Event
    | AtHead (Sha -> Event)
    | FromFile FilePath (Text -> Either Text Event)

{- | The @state record@ line for an event, its arguments' usage after it. An
event inside a scope is named so, @security/review.rows@, and takes its step's arguments.
-}
recordCommand :: EventName -> Text
recordCommand event =
    Text.strip
        ( "state record "
            <> name
            <> " "
            <> foldMap usageOf [r | r <- recordables, r.name == step]
        )
  where
    name = eventText event
    step = snd (unqualify name)

{- | One way on from where the run is: the exact command, and what taking
it means, where the run goes next among it. An option that spawns names
the agent, not how it runs: whether in the background is the run's
interface's to say, told when the option is printed.
-}
data Option = Option {command :: Text, means :: Text, spawns :: Bool}
    deriving stock (Eq, Show)

-- | An option taken by running its command.
commandOption :: Text -> Text -> Option
commandOption command means = Option command means False

-- | The record of an event along its edge, saying where the run goes.
recordOption :: EventName -> Edge Node -> Option
recordOption event edge = commandOption (recordCommand event) (goes edge)

-- | Where an edge takes the run, in words.
goes :: Edge Node -> Text
goes edge = case (edge.arrow, edge.to, edge.back) of
    (Stay, _, _) -> "the run stays here"
    (Along _, At place, Just loop) ->
        "back to "
            <> stateNameText (placeName place)
            <> ", the "
            <> nameText loop
            <> " loop's next round"
    (Along _, to, _) -> onTo to
  where
    onTo = \case
        At place -> "on to " <> stateNameText (placeName place)
        Out -> "the flow ends"
        Exit -> "the flow ends at its exit"

-- | The @state record@ line that extends a used-up budget, on the user's yes.
extendOption :: Option
extendOption =
    commandOption
        (Text.unwords ["state record", extend.name, usageOf extend])
        "when the user goes on: the used-up budgets here start afresh"

{- | At a fork of child runs (the chief's delegate): the brief to fill in
and spawn the child with. Nothing is recorded here: the child's init moves
the run on.
-}
spawnChildOption :: Option
spawnChildOption =
    commandOption
        "state brief engineer"
        "fill it in and spawn an engineer with it (state brief 10x: a 10x); record nothing - the child's state init --parent moves this run on"

{- | What the run may record at a used-up budget of the step at this state:
the ways out of its loop, then as its 'AtCap' says - nothing more, a stop,
or an @extend@ (with the step's own outcomes when no way leaves).
-}
capRecords :: OpenGraph -> Place -> AtCap -> [Option]
capRecords g place atCap = case atCap of
    Refuse -> exits
    Stop ->
        exits
            <> [commandOption "state stop rounds <why>" "stops the run: the budget is used up"]
    Extend -> extendOption : if null exits then outs else exits
  where
    exits = [recordOption event edge | (event, edge) <- leaving g place]
    outs = [recordOption event edge | (event, edge) <- outOf place g.edges]

-- | The user's yes to one more interview round, and why.
extend :: Recordable
extend =
    atRoot
        ( Recordable
            "extend"
            "<why>"
            []
            (fmap (Plain . Extended) . because . (.positional))
        )

{- | An event of the run, not of a step, as @fuel@ or @task@: no scope
names it, so a scoped one is refused.
-}
atRoot :: Recordable -> Recordable
atRoot r =
    r
        { parse = \a ->
            if a.scope == mempty
                then r.parse a
                else Left "only a step's outcome is named inside a scope"
        }

{- | An event @state record@ takes: its name, its positionals' usage, the
@--name value@ flags it takes, and the parser of both.
-}
data Recordable = Recordable
    { name :: Text
    , positional :: Text
    , flags :: [Flag]
    , parse :: Args -> Either Text Recording
    }

-- | A flag an event takes, its value's usage, and how often it is given.
data Flag = Flag {name :: Text, value :: Text, arity :: Arity}

data Arity = Required | Optional | Repeated

-- | An event's arguments as its usage line shows them, positionals first.
usageOf :: Recordable -> Text
usageOf r =
    Text.unwords (filter (not . Text.null) (r.positional : map flagUsage r.flags))
  where
    flagUsage flag = case flag.arity of
        Required -> given flag
        Optional -> "[" <> given flag <> "]"
        Repeated -> "[" <> given flag <> "]..."
    given flag = "--" <> flag.name <> " " <> flag.value

-- | Every event a lead records by hand, in the order a run meets them.
recordables :: [Recordable]
recordables =
    [ stay "gap" "<text>" $ \case
        [] -> Left "the gap"
        gap -> Right (Gapped (Text.unwords gap))
    , nothing ResearchSpawned
    , nothing ResearchHandedBack
    , nothing InterviewAsked
    , nothing DiscussAsked
    , nothing NotesDone
    ]
        <> [ -- Named at a request's Fuel, before its level.
             stay "target" "<pr <url>|branch <name>|ticket <url>>" $ \case
                ["pr", pr] ->
                    maybe
                        (Left (pr <> " is not " <> prUrlRule))
                        (Right . Targeted . OnPr)
                        (parsePrUrl pr)
                ["branch", name] -> Right (Targeted (OnBranch (Branch name)))
                ["ticket", link] -> Right (Targeted (OnTicket (Url link)))
                _ -> Left "pr and its url, branch and its name, or ticket and its url"
           ]
        <> [ outcome (builtEvent Fuel LevelSet) ("<" <> choices fuelName <> ">") [] $ \a -> case a.positional of
                [raw] -> Plain . tookIn a.scope . LevelSet <$> known "fuel" parseFuel raw
                _ -> Left "one level"
           , extend
           , outcome (builtEvent PlanS PlanDone) "<path>" [] $ \a -> case a.positional of
                -- Read as a file only to refuse a plan not written yet.
                [path] ->
                    Right
                        ( FromFile
                            (Text.unpack path)
                            (const (Right (tookIn a.scope (PlanDone (Text.unpack path)))))
                        )
                _ -> Left "the plan's path"
           , nothing SimplifyPlanDone
           , nothing StandardsPlanDone
           , nothing AlignPlanDone
           , nothing PresentDone
           , nothing ConfirmConfirmed
           , nothing ConfirmAdjusted
           , outcome (builtEvent Draft DraftDone) "<url> <base> <branch>" [] $ \a -> case a.positional of
                [link, base, branch] ->
                    Right
                        ( Plain
                            (tookIn a.scope (DraftDone (DraftPr (Url link) (Branch base) (Branch branch))))
                        )
                _ -> Left "the PR's url, base and branch"
           , -- As a hand-back with no Touches line reads: an implementer may have touched any area.
             commitAt Implement ImplementDone (Set.fromList [minBound .. maxBound])
           , atHead Refactor RefactorDone
           , atHead Review ReviewClean
           , atHead Review ReviewRows
           , picks PickRows PickFinal
           , picks PickRows PickLoop
           , -- A fixer's hand-back with no Touches line touches no area.
             commitAt Fix FixDone Set.empty
           , atHead ReReview ReReviewClean
           , atHead ReReview ReReviewRows
           , atHead Describe DescribeDone
           , atHead SimplifyPR SimplifyPrDone
           , atHead AwaitCi AwaitCiGreen
           , outcome (builtEvent AwaitCi (uncurry AwaitCiRed)) "<check>..." [] $ \a -> case a.positional of
                check : more ->
                    Right
                        (AtHead (\sha -> tookIn a.scope (AwaitCiRed sha (fmap Check (check :| more)))))
                [] -> Left "the failing checks"
           , atHead FixPR FixPrDone
           , url "the PR's url" Ready ReadyDone
           , url "the PR's url" Ready ReadySkipped
           , url "the issue's url" WriteTicket TicketWritten
           , url "the issue's url" OpenPlan OpenPlanDone
           , outcome (builtEvent OpenBranch OpenBranchDone) "<branch|sha>" [] $ \a -> case a.positional of
                [ref] -> Right (Plain (tookIn a.scope (OpenBranchDone (Branch ref))))
                _ -> Left "the branch or sha"
           , url "the PR's url" OpenPr OpenPrDone
           , outcome (builtEvent Direct DirectDone) "<note>" [] $ \a -> case a.positional of
                [] -> Left "what was asked and done"
                note -> Right (Plain (tookIn a.scope (DirectDone (Text.unwords note))))
           , nothing NextRequest
           , nothing NextDone
           ]
        <> [breakdown fan | fan <- fanOuts]
        <> [ atRoot
                $ Recordable
                    "task"
                    "<id> <ci|review|merged|kept|round> <pr> | add <task.json> | <id> parked <why>"
                    [Flag "pr" "<url>" Optional]
                $ \a -> case a.positional of
                    [task, "round", pr] ->
                        maybe
                            (Left (pr <> " is not " <> prUrlRule))
                            (Right . Plain . TaskMoved (TaskId task) . Round)
                            (parsePrUrl pr)
                    [task, state, pr]
                        | Just moved <- lookup state Codec.prStates ->
                            Right (Plain (TaskMoved (TaskId task) (moved (Url pr))))
                    task : "parked" : why@(_ : _) ->
                        Right
                            ( Plain
                                (TaskMoved (TaskId task) (Parked (Text.unwords why) (Url <$> option "pr" a)))
                            )
                    -- Two words never move a task, so a task named add stays recordable.
                    ["add", path] -> Right (FromFile (Text.unpack path) (fmap TaskAdded . Codec.decodeTask))
                    _ ->
                        Left
                            "the task, then ci, review, merged, kept or round and its PR, or parked and why; or add and a task file"
           , stay "held" "<task> <url>" $ \case
                [task, link] -> Right (Held (TaskId task) (Url link))
                _ -> Left "the task and the url"
           , stay "acted" "<task> <url>" $ \case
                [task, link] -> Right (ActedOn (TaskId task) (Url link))
                _ -> Left "the task and the held url acted on"
           , stay "spawning" "<task>" $ \case
                [task] -> Right (Spawning (TaskId task))
                _ -> Left "the task the engineer you spawn takes"
           , stay "resumed" "<child run>" $ \case
                [child] -> maybe (Left (child <> " is no run id")) (Right . Resumed) (parseRunId child)
                _ -> Left "the child run you resume"
           ]
        <> concat
            [ [url "the PR's url" (Merge fan) (MergeDone fan), nothing (MergeNextRound fan)]
            | fan <- fanOuts
            ]
        -- Each pick's label and each skip's choice, as the flows draw them.
        <> [flowOutcome o | o <- drawnOutcomes]
  where
    flowOutcome o = outcome (Catalog.outcomeEvent o) "" [] $ \a -> case a.positional of
        [] -> Right (Plain (Took a.scope o))
        _ -> Left "no arguments"
    breakdown fan = outcome
        (builtEvent (Breakdown fan) (BreakdownDone fan))
        ""
        [Flag "tasks" "<file.json>" Required]
        $ \a -> case (a.positional, option "tasks" a) of
            ([], Just path) ->
                Right
                    ( FromFile
                        (Text.unpack path)
                        (fmap (tookIn a.scope . BreakdownDone fan) . Codec.decodeBreakdown)
                    )
            _ -> Left "the tasks file, as --tasks <file.json>"
    stay name usageText build = atRoot (Recordable name usageText [] (\a -> Plain <$> build a.positional))
    outcome event = Recordable (eventText event)
    nothing done = outcome (Catalog.outcomeEvent (Catalog.outcome done)) "" [] $ \a -> case a.positional of
        [] -> Right (Plain (tookIn a.scope done))
        _ -> Left "no arguments"
    atHead s done = outcome (builtEvent s done) "" [] $ \a -> case a.positional of
        [] -> Right (AtHead (tookIn a.scope . done))
        _ -> Left "no arguments: the head is HEAD"
    commitAt s done unstated = outcome (builtEvent s done) "" [Flag "touches" "<area>,...|none" Optional] $ \a -> case a.positional of
        [] ->
            (\areas -> AtHead (\sha -> tookIn a.scope (done (Commit sha areas))))
                <$> maybe
                    (Right unstated)
                    (Bifunctor.first refusalText . parseTouches)
                    (option "touches" a)
        _ -> Left "no arguments: the head is HEAD"
    picks s done = outcome
        (builtEvent s done)
        ""
        [ Flag "row" "<label>" Repeated
        , Flag "verdict" ("<requirement>=<" <> choices judgementText <> ">") Repeated
        ]
        $ \a -> case a.positional of
            [] ->
                Plain
                    . tookIn a.scope
                    . done
                    . Picks (Set.fromList (map Label (options "row" a)))
                    . Map.fromList
                    <$> traverse verdict (options "verdict" a)
            _ -> Left "rows and verdicts are options"
    url noun s done = outcome (builtEvent s done) "<url>" [] $ \a -> case a.positional of
        [raw] -> Right (Plain (tookIn a.scope (done (Url raw))))
        _ -> Left noun
    verdict raw = case Text.breakOnEnd "=" raw of
        (requirement, judgement)
            | Just r <- Text.stripSuffix "=" requirement
            , not (Text.null r) ->
                (Requirement r,) <$> known "verdict" (parseByName judgementText) judgement
        _ -> Left (raw <> " is not <requirement>=<verdict>")
    known :: Text -> (Text -> Maybe a) -> Text -> Either Text a
    known what parse raw = maybe (Left ("no " <> what <> " " <> raw)) Right (parse raw)

-- | The reason a lead gives, its words joined back.
because :: [Text] -> Either Text Text
because = \case
    [] -> Left "why"
    why -> Right (Text.unwords why)

{- | The scope the event's step sits in, from its qualified name, then
positionals and @--name value@ options, the only kind of flag there is.
-}
data Args = Args {scope :: ScopePath, positional :: [Text], options :: [(Text, Text)]}

-- | The last value given, as a shell user retyping an option expects.
option :: Text -> Args -> Maybe Text
option name a = case options name a of
    [] -> Nothing
    values -> Just (last values)

options :: Text -> Args -> [Text]
options name a = [value | (key, value) <- a.options, key == name]

choices :: (Bounded a, Enum a) => (a -> Text) -> Text
choices name = Text.intercalate "|" (map name [minBound .. maxBound])
