{- | The read-only views of a run: @state show@, @state pending@ and @state
brief@; and the texts that need no run: a role's brief and how work begins.
-}
module State.Cli.View (
    showRun,
    section,
    pendingLines,
    answerLine,
    brief,
    briefSection,
    taskBrief,
    briefOf,
    beginText,
    cardLines,
    minutesSince,
) where

import Data.Bifunctor qualified as Bifunctor
import Data.Bool (bool)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, diffUTCTime)
import State.Category.Flow (qualifyEvent)
import State.Category.Fuel (fuelLabel)
import State.Category.Graph (Edge (..), Node (..), OpenGraph (..), Place (..))
import State.Category.Step (
    EventName (..),
    SomeStep (..),
    StateName,
    eventText,
    handedBackOutcome,
    spawnedOutcome,
    stateNameText,
    stepName,
 )
import State.Cli.Render qualified as Render
import State.FlowName (fixedFuel, namedFlowText)
import State.Protocol.Advice (Facts (..), factLines)
import State.Protocol.Hook (
    Begin (..),
    HookName (HandbackHook, SpawnHook),
    beside,
    hookName,
    opensChild,
 )
import State.Role (leads)
import State.Run.Ask (
    ChildTask (..),
    Link (..),
    Parent (..),
    Principal (ByRole),
    Question (..),
    kindName,
    oneLineText,
    qidText,
    replyText,
    rulingLine,
 )
import State.Run.Card (
    Card (..),
    ResumeAdvice (..),
    Standing (..),
    advice,
    resumeWindow,
 )
import State.Run.Codec (
    branchText,
    flowText,
    reasonText,
    taskIdText,
    topicText,
    urlText,
 )
import State.Run.Event (
    AgentId (..),
    AgentRole (..),
    Asker (..),
    Asking (..),
    Branch,
    FlowName,
    Note (..),
    Repo (..),
    Shape (..),
    Start (..),
    Stop (..),
    Task (..),
    TaskId,
    roleText,
    runIdText,
    taskNoText,
 )
import State.Run.Fan (Fan (..), tries)
import State.Run.Fold (
    Answer (..),
    Holder (..),
    Pending (..),
    RunState (..),
    Waits (..),
    askedAt,
    fanAt,
    fanIn,
    taskHolder,
 )
import State.Show (tshow)
import State.Step.Artifact (shellPathText, slugChar)
import State.Step.Catalog (AnyStep (..))
import State.Table (Row (..), Steps, agentRoles, row, stepsRunBy)

{- | Where the run is and what it carries: step, mode, rounds, questions,
rulings, gaps; and which hook records which of the flow's events.
-}
showRun :: Steps -> OpenGraph -> RunState -> Text
showRun steps g state =
    Text.unlines $
        ["run: " <> runIdText state.run <> " (" <> flowText state.start.flow <> ")"]
            <> concat [linkLine parent.link | ByRole parent _ _ <- [state.start.principal]]
            <> ["step: " <> stateNameText (askedAt state)]
            <> factLines g (Facts Nothing Nothing []) state
            <> [ "stopped: " <> reasonText stop.reason <> " " <> stop.why
               | Just stop <- [state.stopped]
               ]
            <> [ "refused: " <> note.message <> "; fix: " <> note.fix
               | Just note <- [state.refused]
               ]
            <> section "pending:" (pendingLines state)
            <> section "rulings:" (map rulingLine state.rulings)
            <> section "answered:" (map answerLine state.answers)
            <> section "gaps:" [tshow n <> " " <> gap | (n, gap) <- state.gaps]
            <> section "hooks:" (hookLines steps g)
  where
    linkLine = \case
        InFan (Tasked task) -> ["task: " <> taskIdText task]
        InFan Untasked -> ["untasked: the parent handed on its request whole"]
        Direct -> []

-- | A titled section, its items indented under it; none when it has no items.
section :: Text -> [Text] -> [Text]
section title = \case
    [] -> []
    items -> title : map ("  " <>) items

-- | A forwarded question and the answer that came down.
answerLine :: Answer -> Text
answerLine answered =
    qidText answered.about.qid
        <> " "
        <> kindName answered.about.kind
        <> ": "
        <> oneLineText answered.about.text
        <> " - "
        <> replyText answered.about.kind answered.given

{- | What the hooks record of the flow's events, so no agent records them
by hand: the spawn and the hand-back of each step a subagent runs as a child
of a choice, the only steps whose spawn a hook sees ('opensChild'), at each
place this flow takes it, named in its scopes. A hook is best effort: the
last line names the commands that record a missed line by hand.
-}
hookLines :: Steps -> OpenGraph -> [Text]
hookLines steps g = case hooked of
    [] -> []
    _ ->
        hooked
            <> [ "best effort: with no recorded line after a spawn or hand-back, run state record <step>.spawned or state handback <role>"
               ]
  where
    hooked =
        [ line
        | role <- agentRoles steps
        , AnyStep l (SomeStep s) <- stepsRunBy steps role
        , opensChild l s
        , spawned <-
            Set.toList
                ( Set.fromList
                    [ event
                    | (place, event) <- Map.keys g.edges
                    , place.name == stepName s
                    , event == qualifyEvent place.scope (EventName (stepName s) spawnedOutcome)
                    ]
                )
        , line <-
            [ eventText spawned
                <> ": the "
                <> hookName SpawnHook
                <> " hook, as the lead spawns a "
                <> roleText role
            , eventText spawned {outcome = handedBackOutcome}
                <> ": the "
                <> hookName HandbackHook
                <> " hook, at its hand-back"
            ]
        ]

{- | A request's resume card at this time: where it stands, what was
decided in it, what it still asks, and how to take it up again.
-}
cardLines :: UTCTime -> Card -> [Text]
cardLines now card =
    headline
        : [ "  decided " <> qidText qid <> " - " <> replyText kind reply
          | (qid, kind, reply) <- card.decisions
          ]
            <> [ "  open "
                    <> qidText q.qid
                    <> " "
                    <> kindName q.kind
                    <> ": "
                    <> oneLineText q.text
               | q <- card.open
               ]
            <> ["  " <> adviceLine resume | Just resume <- [advice now card]]
  where
    headline = case card.standing of
        InFocus -> taskNoText card.task <> " in focus at " <> stateNameText card.node
        Paused at summary ->
            taskNoText card.task
                <> " paused "
                <> minutesSince now at
                <> " at "
                <> stateNameText card.node
                <> ": "
                <> oneLineText summary

-- | Whole minutes from then to now: @5m@.
minutesSince :: UTCTime -> UTCTime -> Text
minutesSince now at = tshow (floor (diffUTCTime now at / 60) :: Integer) <> "m"

adviceLine :: ResumeAdvice -> Text
adviceLine = \case
    ResumeAgent agent ->
        "resume agent "
            <> agent.agentIdText
            <> ": paused under "
            <> life
            <> ", its cache is warm (SendMessage)"
    FreshFromCard -> "fresh agent from card: paused " <> life <> " or more, its cache is cold"
  where
    life = minutesSeconds (round resumeWindow)

-- | Whole seconds as @4m45s@.
minutesSeconds :: Integer -> Text
minutesSeconds total = let (m, s) = total `divMod` 60 in tshow m <> "m" <> tshow s <> "s"

-- | One line per open question, oldest first.
pendingLines :: RunState -> [Text]
pendingLines state = map line state.pending
  where
    line p =
        qidText p.asking.question.qid
            <> " "
            <> kindName p.asking.question.kind
            <> " "
            <> waiting p.waits
            <> " from "
            <> askerText p.asking.from
            <> ": "
            <> oneLineText p.asking.question.text
    waiting = \case
        ForTriage -> "to triage"
        ForAnswer -> "forwarded"
        ForLater why -> "parked (" <> oneLineText why <> ")"
    askerText = \case
        Itself -> "this run"
        Subagent (AgentRole role) -> role
        ChildRun run -> runIdText run

{- | A role's brief skeleton: its 'stepBrief'; then the rule its hand-back
follows. A role that leads a flow, a child run, gets its task's
fields and the line that starts its run under this one, on the task's flow:
in the task's worktree and notes dir when the breakdown names them; a task
the breakdown lacks is returned as the failure.
-}
brief ::
    Steps ->
    OpenGraph ->
    RunState ->
    AgentRole ->
    Maybe TaskId ->
    Either TaskId Text
brief steps g state agent task = case (leads agent, task, fanAt state.at) of
    (Just flow, Nothing, Just _) -> Right (initLine state flow "<dir>" (Just "<id>"))
    -- At no fan-out the child takes no task: it names --parent alone.
    (Just flow, Nothing, Nothing) -> Right (untaskedBrief state flow)
    (Just _, Just taskId, _) ->
        Bifunctor.bimap
            (const taskId)
            (\holder -> taskBrief state (fanIn state.fans holder.fan) holder.held)
            (taskHolder state taskId)
    (Nothing, _, _) -> Right (stepBrief steps g state.at agent)

{- | A brief for a child that takes no task, to fill in: the fields a task
would give it, where its run starts as to Fuel, the request in the user's
words, the plan it carries out and when it is done, then the line that
starts its run under this one. Unlike a task's child, nothing records its
Fuel line for it.
-}
untaskedBrief :: RunState -> FlowName -> Text
untaskedBrief state flow =
    Text.unlines
        [ "Fuel: <low|balanced|max>"
        , "Base: <branch>"
        , "Branch: <branch>"
        , case fixedFuel flow of
            Nothing ->
                "Your run starts at fuel: record the Fuel line there, state record fuel.set <level>."
            Just fuel ->
                "Your run starts past fuel, at " <> fuelLabel fuel <> ": record no fuel.set."
        , ""
        , "## The user's words"
        , "<the request, verbatim>"
        , ""
        , "## Plan"
        , "<the confirmed ticket or plan>"
        , ""
        , "## Acceptance criteria"
        , "- <a check the result passes>"
        , ""
        ]
        <> initLine state flow "<dir>" Nothing

{- | A step runner's brief where the run is: the task text of the step the
run is at, else of the step whose spawn led there, as a researcher's leads
back to the gather's pick before it starts; else, where the role runs
neither, of each step it runs.
-}
stepBrief :: Steps -> OpenGraph -> Node -> AgentRole -> Text
stepBrief steps g at agent = case briefHere steps g at agent of
    [] -> briefOf steps agent
    here : _ -> here

-- | The brief sections of the steps 'stepBrief' tries, in its order.
briefHere :: Steps -> OpenGraph -> Node -> AgentRole -> [Text]
briefHere steps g at agent =
    [text | name <- named, Right text <- [briefSection steps agent name]]
  where
    named = case at of
        At place ->
            place.name
                : [ from.name
                  | ((from, event), edge) <- Map.toList g.edges
                  , event.outcome == spawnedOutcome
                  , edge.to == at
                  ]
        Out -> []
        Exit -> []

{- | A child engineer's brief head: its task's fields, then the line that
starts its run under this one, on the task's flow: in the task's worktree and
notes dir when the breakdown names them.
-}
taskBrief :: RunState -> Fan -> Task -> Text
taskBrief state fan found = Text.unlines (taskLines found) <> "\n" <> taskInit
  where
    taskInit =
        maybe
            ""
            (\path -> "cd " <> Text.pack (shellPathText path) <> " && ")
            found.worktree
            <> initLine
                state
                found.flow
                ( maybe
                    "<dir>"
                    ( engineerNotes
                        (Map.findWithDefault 0 found.id fan.rounds)
                        (tries fan found.id)
                        found.branch
                    )
                    found.repo
                )
                (Just (taskIdText found.id))
    taskLines task =
        [ "Task: " <> taskIdText task.id
        , "Fuel: " <> fuelLabel task.fuel
        , "Base: " <> branchText task.base
        , "Branch: " <> branchText task.branch
        , "Depends on: " <> listed (map taskIdText task.deps)
        , "QA: " <> yesNo task.qa
        , "Heavy: " <> yesNo task.heavy
        , "Security-sensitive: " <> listed (map topicText (Set.toList task.security))
        ]
            <> case task.shape of
                OwnPr -> []
                RoundOn url -> ["Round on PR: " <> urlText url]
    listed = \case
        [] -> "none"
        items -> Text.intercalate ", " items
    yesNo = bool "no" "yes"

-- | The line that starts a child run under this one: on this flow, in these notes, taking this task, if at a fan-out.
initLine :: RunState -> FlowName -> Text -> Maybe Text -> Text
initLine state flow notesText taskText =
    "state init --notes "
        <> notesText
        <> flowFlag
        <> " --parent "
        <> runIdText state.run
        <> foldMap (" --task " <>) taskText
        <> "\n"
  where
    -- The default flow is left out, so an engineer's line reads as it always has.
    flowFlag = maybe "" (" --flow " <>) (namedFlowText flow)

{- | The notes dir the engineer skill names for a task's run,
@/tmp/engineer-<owner>-<repo>-<slug>/@, the slug its branch with each
character but a 'slugChar' a @-@: a @/@, and whatever a shell would read.
The run of the task's nth round gets @-r<n>@, and a retry, a child beyond one
per round, @-t<n>@ for the nth child of the task (#429): an earlier run's dir
is finished. As the task's children only grow, each child's dir is fresh.
-}
engineerNotes :: Int -> Int -> Branch -> Repo -> Text
engineerNotes rounds tried branch repo =
    "/tmp/engineer-"
        <> repo.owner
        <> "-"
        <> repo.name
        <> "-"
        <> Text.map slug (branchText branch)
        <> roundSuffix
        <> trySuffix
        <> "/"
  where
    slug c = if slugChar c then c else '-'
    roundSuffix = if rounds > 0 then "-r" <> tshow rounds else ""
    trySuffix = if tried > rounds then "-t" <> tshow (tried + 1) else ""

{- | One section of a role's brief: the task text of the step named, then
the rules its hand-back follows; the role's step names when it runs no such step.
-}
briefSection :: Steps -> AgentRole -> StateName -> Either [StateName] Text
briefSection steps agent name = case filter ((== name) . fst) runs of
    [] -> Left (map fst runs)
    named -> Right (sections named <> rulesOf agent)
  where
    runs = runsOf steps agent

{- | A role's brief wherever a run is: the task text of each step it runs,
then the rules its hand-back follows. 'brief' gives it at a step the role
does not run.
-}
briefOf :: Steps -> AgentRole -> Text
briefOf steps agent = case runsOf steps agent of
    [] -> ""
    runs -> sections runs <> rulesOf agent

-- | Each step a role runs, by name, with its row.
runsOf :: Steps -> AgentRole -> [(StateName, Row)]
runsOf steps agent =
    [(stepName s, row steps s) | AnyStep _ (SomeStep s) <- stepsRunBy steps agent]

sections :: [(StateName, Row)] -> Text
sections steps =
    Text.concat
        ["## " <> stateNameText name <> "\n\n" <> r.task <> "\n\n" | (name, r) <- steps]

-- | The rules every step runner's hand-back follows: the token line, then its role's 'ruleOf'.
rulesOf :: AgentRole -> Text
rulesOf agent = Render.handbackRule <> "\n" <> ruleOf agent

-- | The rule a role's hand-back follows: the stop rule, or a review-lead's plan-wrong line.
ruleOf :: AgentRole -> Text
ruleOf (AgentRole role)
    | role `elem` ["implementer", "refactorer", "fixer"] = Render.stopRule
    | role == "review-lead" = Render.planWrong
    | otherwise = ""

{- | What a hook tells as work begins (#403): a spawned lead and a lead
skill how its run starts, a step runner its brief: at the worktree's run,
when read, its 'stepBrief', none for one spawned beside at no step it runs.
Stated as facts, as imperative text in a hook's context can read as an
injected order.
-}
beginText :: Steps -> Maybe (OpenGraph, RunState) -> Begin -> Text
beginText steps run = \case
    SpawnedLead ->
        "state: this lead's run is driven by `state`. Its first command is the `state init` line in its prompt, as written; "
            <> "then `state next`, until it prints DONE.\n"
    SpawnedWorker role -> case run of
        Nothing -> briefOf steps role
        Just (g, state) -> case briefHere steps g state.at role of
            here : _ -> here
            -- Spawned beside the advice, as a review-lead's reviewer: its
            -- spawner's prompt is its brief, no step's of the run.
            []
                | role `elem` beside -> ""
                | otherwise -> briefOf steps role
    TypedSkill _ -> skillBegins
    CalledSkill _ -> skillBegins
  where
    skillBegins =
        "state: this skill begins with `state`: `state init ...`, then `state next`.\n"
