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
    switched,
) where

import Data.Aeson.Key qualified as Key
import Data.Bifunctor qualified as Bifunctor
import Data.Char (ord)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric (showHex)
import Numeric.Natural (Natural)
import State.Artifact (FileKind, parseUri, uriRule)
import State.Artifact qualified as Artifact
import State.Category.Flow (ScopePath, nameText, unqualify)
import State.Category.Fuel (choices, fuelName, parseByName, parseFuel)
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
import State.Run.Ask (parseOneLine)
import State.Run.Codec (judgementText)
import State.Run.Codec qualified as Codec
import State.Run.Event (
    Branch (..),
    Check (..),
    Commit (..),
    DepsEdit (..),
    DraftPr (..),
    Event (..),
    Instruction (..),
    Label (..),
    Need (..),
    Picks (..),
    Requirement (..),
    RunId,
    Sha,
    TakeUp (TakesUp),
    Target (..),
    TaskId (..),
    TaskRef,
    TaskState (..),
    Url (..),
    parseRunId,
    parseVerbatim,
    tookIn,
 )
import State.Run.Gap (
    Evidence (..),
    GapArea (..),
    GapDraft (..),
    gapKindText,
    parseGapText,
    severityText,
 )
import State.Run.Gap qualified as Gap
import State.Run.IJson (IJsonRefusal (..), ijsonCap, parseIJson)
import State.Run.Id (EventRef (..), parseEventRef, parseSeq)
import State.Run.Stopgap (StopgapAt (..), parseStopgapKey, stopgapKeyRule)
import State.Step.Artifact (
    NonBlank,
    baseTextForms,
    parseBase,
    parseNamesOrNone,
    parseNonBlank,
    parsePrUrl,
    parseSha,
    parseTaskId,
    prUrlRule,
    shaRule,
 )
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
the shell can read; a breakdown or an added task is read from a file, by the
shell too, which registers the file as an artifact of this kind. A plan's
event only names its file: the shell registers it if it can read it, and a
file it cannot read refuses nothing. An event naming a task or a child names
the task's breakdown too, which the shell reads off the run.
-}
data Recording
    = Plain Event
    | AtHead (Sha -> Event)
    | FromFile FileKind FilePath (Text -> Either Text Event)
    | NamesFile FileKind FilePath Event
    | {- | A gap, its area left to the step the run is at when not given, its
      reporter the run's role; its evidence lines are looked up first.
      -}
      Filing GapDraft
    | OnTask TaskId (TaskRef -> Event)
    | -- | The child's task as its @spawned@ names it, none for an untasked child.
      OnChild RunId (Maybe TaskRef -> Event)
    | -- | A task read from this file joins the breakdown logged at a seq.
      AddsTask FilePath (Text -> Either Text (Natural -> Event))
    | -- | The task's branch is at this commit: the shell prints it as @task <id> head <sha>@.
      HeadOf TaskId Sha
    | -- | An event naming these tasks, none to many, each by its breakdown.
      OnTasks [TaskId] ([TaskRef] -> Event)
    | {- | The need logged at this line is done, maybe with a note: closed in
      the run that logged it, under that run's lock.
      -}
      NeedDone EventRef (Maybe NonBlank)
    | {- | The task's PR moves to this state, refused before it appends once
      the task merged ('State.Run.Fold.movable').
      -}
      MovesTask TaskId TaskState

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

-- | A 'Switch' takes no value: its 'Flag' value is empty.
data Arity = Required | Optional | Repeated | Switch

-- | An event's arguments as its usage line shows them, positionals first.
usageOf :: Recordable -> Text
usageOf r =
    Text.unwords (filter (not . Text.null) (r.positional : map flagUsage r.flags))
  where
    flagUsage flag = case flag.arity of
        Required -> given flag
        Optional -> "[" <> given flag <> "]"
        Repeated -> "[" <> given flag <> "]..."
        Switch -> "[--" <> flag.name <> "]"
    given flag = "--" <> flag.name <> " " <> flag.value

-- | Every event a lead records by hand, in the order a run meets them.
recordables :: [Recordable]
recordables =
    [ atRoot
        $ Recordable
            "gap"
            "<text>"
            [ Flag "kind" ("<" <> choices gapKindText <> ">") Optional
            , Flag "severity" ("<" <> choices severityText <> ">") Optional
            , Flag "area" "<area>" Optional
            , Flag "evidence" "<run:seq|url>" Repeated
            ]
        $ \a -> case a.positional of
            [] -> Left "the gap"
            gap -> Filing <$> draftOf (Text.unwords gap) a
    , atRoot
        $ Recordable
            "instructed"
            ("<" <> choices Codec.instructionKindText <> "> <verbatim>")
            [Flag "replaces" "<seq>" Optional]
        $ \a -> case a.positional of
            raw : words'@(_ : _) -> do
                kind <-
                    maybe
                        ( Left
                            ( "no instruction kind "
                                <> raw
                                <> ": one of "
                                <> choices Codec.instructionKindText
                            )
                        )
                        Right
                        (parseByName Codec.instructionKindText raw)
                text <-
                    maybe
                        (Left "the user's words")
                        Right
                        (parseVerbatim (Text.unwords words'))
                replaces <- traverse seqOf (option "replaces" a)
                Right (Plain (Instructed (Instruction kind text) replaces))
            _ -> Left "the instruction's kind, then the user's words"
    , atRoot
        $ Recordable
            "user_needed"
            "<text> | <run:seq>"
            [ Flag "blocks" "<task>,..." Optional
            , Flag "url" "<url>" Optional
            , Flag "done" "" Switch
            , Flag "note" "<n>" Optional
            ]
        $ \a -> if switched "done" a then needDone a else needed a
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
                [path] ->
                    Right
                        ( NamesFile
                            Artifact.Plan
                            (Text.unpack path)
                            (tookIn a.scope (PlanDone (Text.unpack path)))
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
           , atHead Visual VisualDone
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
                    ( "<id> <"
                        <> prStateNames
                        <> "> <pr> | add <task.json> | head <id> <sha> | <id> base <base> --reason <r> [--deps <task>,...|none] | <id> parked <why>"
                    )
                    [ Flag "pr" "<url>" Optional
                    , Flag "reason" "<r>" Optional
                    , Flag "deps" "<task>,...|none" Optional
                    ]
                $ \a -> case a.positional of
                    -- Before a move: no task state is named head.
                    ["head", task, raw] ->
                        maybe
                            (Left (raw <> " is not " <> shaRule))
                            (Right . HeadOf (TaskId task))
                            (parseSha raw)
                    [task, "base", raw] -> do
                        base <-
                            maybe
                                ( Left
                                    (raw <> " is no base: " <> baseTextForms)
                                )
                                Right
                                (parseBase raw)
                        reason <-
                            maybe
                                (Left "a base change says why, as --reason <r>: one line")
                                Right
                                (parseNonBlank =<< option "reason" a)
                        deps <- maybe (Right DepsKept) (fmap DepsSet . depsOf) (option "deps" a)
                        Right (OnTask (TaskId task) (\ref -> TaskBaseChanged ref base reason deps))
                    [task, "round", pr] ->
                        maybe
                            (Left (pr <> " is not " <> prUrlRule))
                            (Right . moving task . Round)
                            (parsePrUrl pr)
                    [task, state, pr]
                        | Just moved <- lookup state Codec.prStates ->
                            Right (moving task (moved (Url pr)))
                    task : "parked" : why@(_ : _) ->
                        Right (moving task (Parked (Text.unwords why) (Url <$> option "pr" a)))
                    -- Two words never move a task; a task file refuses the id add.
                    ["add", path] ->
                        Right (AddsTask (Text.unpack path) (fmap (flip TaskAdded) . Codec.decodeTask))
                    _ ->
                        Left
                            ( "the task, then "
                                <> prStateNames
                                <> " and its PR, base and its base, or parked and why; or add and a task file, or head, the task and its sha"
                            )
           , named "held" "<task> <url>" $ \case
                [task, link] -> Right (OnTask (TaskId task) (`Held` Url link))
                _ -> Left "the task and the url"
           , named "acted" "<task> <url>" $ \case
                [task, link] -> Right (OnTask (TaskId task) (`ActedOn` Url link))
                _ -> Left "the task and the held url acted on"
           , named "spawning" "<task>" $ \case
                [task] -> Right (OnTask (TaskId task) (`Spawning` TakesUp))
                _ -> Left "the task the engineer you spawn takes"
           , named "resumed" "<child run>" $ \case
                [child] ->
                    maybe
                        (Left (child <> " is no run id"))
                        (\run -> Right (OnChild run (\ref -> Resumed run ref TakesUp)))
                        (parseRunId child)
                _ -> Left "the child run you resume"
           ]
        <> concat
            [ [url "the PR's url" (Merge fan) (MergeDone fan), nothing (MergeNextRound fan)]
            | fan <- fanOuts
            ]
        -- Each pick's label and each skip's choice, as the flows draw them.
        <> [flowOutcome o | o <- drawnOutcomes]
        -- Last: a stopgap is only for a fact no typed event above fits.
        <> [stopgap]
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
                        Artifact.TaskList
                        (Text.unpack path)
                        (fmap (tookIn a.scope . BreakdownDone fan) . Codec.decodeBreakdown)
                    )
            _ -> Left "the tasks file, as --tasks <file.json>"
    stay name usageText build = named name usageText (fmap Plain . build)
    named name usageText build = atRoot (Recordable name usageText [] (build . (.positional)))
    moving task = MovesTask (TaskId task)
    prStateNames = Text.intercalate "|" (map fst Codec.prStates)
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

{- | A gap's draft from its text and flags: the defaults where a flag is not
given. An unknown kind or severity is refused with the allowed words;
evidence is read as @<run>:<seq>@ first, as @abc:5@ is an absolute URI too.
-}
draftOf :: Text -> Args -> Either Text GapDraft
draftOf words' a = do
    text <- maybe (Left "the gap, one line") Right (parseGapText words')
    let bare = Gap.draft text
    kind <- traverse (allowed "gap kind" gapKindText) (option "kind" a)
    severity <- traverse (allowed "severity" severityText) (option "severity" a)
    area <- traverse areaOf (option "area" a)
    evidence <- traverse evidenceOf (options "evidence" a)
    Right
        ( GapDraft
            (fromMaybe bare.kind kind)
            (fromMaybe bare.severity severity)
            area
            text
            evidence
        )
  where
    allowed :: (Bounded v, Enum v) => Text -> (v -> Text) -> Text -> Either Text v
    allowed what name raw =
        maybe
            (Left ("no " <> what <> " " <> raw <> ": one of " <> choices name))
            Right
            (parseByName name raw)
    areaOf raw = maybe (Left "the area, one line") (Right . GapArea) (parseOneLine raw)
    evidenceOf raw = case (parseEventRef raw, parseUri raw) of
        (Just ref, _) -> Right (OfEvent ref)
        (Nothing, Just uri) -> Right (OfUrl uri)
        (Nothing, Nothing) -> Left (raw <> " is no <run>:<seq>, nor " <> uriRule)

-- | @--deps@: the tasks a task builds on, or @none@ ('parseNamesOrNone').
depsOf :: Text -> Either Text (Set TaskId)
depsOf =
    parseNamesOrNone
        (taskNamed "a dependency's task id, as --deps t1,t2 or --deps none")

-- | A task id a flag names, or the given error.
taskNamed :: Text -> Text -> Either Text TaskId
taskNamed missing = maybe (Left missing) Right . parseTaskId

{- | @user_needed "<text>"@: what the user must do by hand, the tasks it
holds up, a repeat counted once, and where to do it.
-}
needed :: Args -> Either Text Recording
needed a = do
    without ["note"] "a new need" a
    text <- oneLine "what the user must do" (Text.unwords a.positional)
    url <- traverse uriOf (option "url" a)
    tasks <-
        Set.unions
            <$> traverse
                (parseNamesOrNone (taskNamed "a blocked task's id, as --blocks t3,t4"))
                (options "blocks" a)
    Right
        ( OnTasks
            (Set.toList tasks)
            (\refs -> UserNeeded (Need text (Set.fromList refs) url))
        )
  where
    uriOf raw = maybe (Left (raw <> " is not " <> uriRule)) Right (parseUri raw)

-- | @user_needed <run:seq> --done@: the need is done, closed in the run that logged it.
needDone :: Args -> Either Text Recording
needDone a = do
    without ["blocks", "url"] "a need done" a
    note <- traverse (oneLine "the note") (option "note" a)
    case a.positional of
        [raw] ->
            maybe
                (Left (raw <> " is no need: <run:seq>, as state resume prints it"))
                (\ref -> Right (NeedDone ref note))
                (parseEventRef raw)
        _ -> Left "the need, as <run:seq>"

{- | A stopgap set or unset, and why: the run's, or a task's with @--task@.
The key and the value are parsed before anything is written.
-}
stopgap :: Recordable
stopgap =
    atRoot
        $ Recordable
            "stopgap"
            "<key> <json> | <key>"
            [ Flag "unset" "" Switch
            , Flag "task" "<id>" Optional
            , Flag "reason" "<r>" Required
            ]
        $ \a -> do
            reason <- oneLine "why, as --reason <r>" (fromMaybe "" (option "reason" a))
            event <- case (switched "unset" a, a.positional) of
                (False, [raw, json]) -> do
                    key <- keyOf raw
                    value <- Bifunctor.first ijsonRefusalText (parseIJson json)
                    Right (\scope -> StopgapSet (StopgapAt scope key) value reason)
                (True, [raw]) -> (\key scope -> StopgapUnset (StopgapAt scope key) reason) <$> keyOf raw
                (False, _) -> Left "the key, then its JSON value as one argument"
                (True, _) -> Left "the key alone: --unset takes no value"
            Right $ case option "task" a of
                Nothing -> Plain (event Nothing)
                Just task -> OnTask (TaskId task) (event . Just)
  where
    keyOf raw =
        maybe (Left (raw <> " is not " <> stopgapKeyRule)) Right (parseStopgapKey raw)

-- | Why a stopgap's value is refused, and what to do instead.
ijsonRefusalText :: IJsonRefusal -> Text
ijsonRefusalText = \case
    NotJson why -> "the value is no JSON text, or holds a lone surrogate: " <> Text.strip why
    RepeatedKey key -> "an object repeats the key " <> Key.toText key <> ": keep one"
    BigInteger _ ->
        "an integer past 2^53-1, which not every JSON reader reads exactly: quote it as a string"
    OutOfRange _ -> "a number past a double's range: quote it as a string"
    Noncharacter c ->
        "a key or string holds the noncharacter U+"
            <> Text.justifyRight 4 '0' (Text.toUpper (Text.pack (showHex (ord c) "")))
            <> ", which I-JSON forbids: drop it"
    TopLevelNull ->
        "the value is null: to clear the key, state record stopgap <key> --unset --reason <r>"
    OverCap octets ->
        "the value takes "
            <> Text.pack (show octets)
            <> " octets, past the cap of "
            <> Text.pack (show ijsonCap)
            <> ": keep a stopgap small"

-- | A line's seq in the run's log.
seqOf :: Text -> Either Text Natural
seqOf raw =
    maybe
        (Left (raw <> " is no seq: a line's number in the log"))
        Right
        (parseSeq raw)

oneLine :: Text -> Text -> Either Text NonBlank
oneLine what = maybe (Left (what <> ", one line")) Right . parseNonBlank

-- | Refuses any of these flags: they belong to another form of the event, named.
without :: [Text] -> Text -> Args -> Either Text ()
without names form a = case [name | name <- names, not (null (options name a))] of
    [] -> Right ()
    name : _ -> Left ("--" <> name <> " has no place in " <> form)

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

-- | Whether a 'Switch' flag is given.
switched :: Text -> Args -> Bool
switched name a = not (null (options name a))
