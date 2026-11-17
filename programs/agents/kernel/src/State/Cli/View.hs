{- | The read-only views of a run: @state show@, @state pending@ and @state
brief@; and the texts that need no run: a role's brief and how work begins.
-}
module State.Cli.View (
    showRun,
    pendingLines,
    brief,
    briefSection,
    taskBrief,
    briefOf,
    beginText,
) where

import Data.Bool (bool)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import State.Category.Fuel (fuelLabel)
import State.Category.Graph (Node (..), OpenGraph (..), Place (..))
import State.Category.Step (EventName (..), SomeStep (..), StateName, eventText, handedBackOutcome, spawnedOutcome, stateNameText, stepName)
import State.Cli.Render qualified as Render
import State.FlowName (namedFlowText)
import State.Protocol.Advice (Facts (..), factLines)
import State.Protocol.Hook (Begin (..), HookName (HandbackHook, SpawnHook), hookName, opensChild)
import State.Role (leads)
import State.Run.Ask (Parent (..), Principal (ByRole), Question (..), kindName, oneLineText, qidText, rulingLine)
import State.Run.Codec (branchText, flowText, logOf, reasonText, taskIdText, topicText, urlText)
import State.Run.Event (AgentRole (..), Asker (..), Asking (..), Branch, FlowName, Note (..), Repo (..), Shape (..), Start (..), Stop (..), Task (..), TaskId, roleText, runIdText)
import State.Run.Fan (Fan (..), lookupTask, tries)
import State.Run.Fold (Answer (..), Pending (..), RunState (..), Waits (..), askedAt, currentFan)
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
            <> ["task: " <> taskIdText parent.task | ByRole parent _ _ <- [state.start.principal]]
            <> ["step: " <> stateNameText (askedAt state)]
            <> factLines g (Facts Nothing Nothing []) state
            <> ["stopped: " <> reasonText stop.reason <> " " <> stop.why | Just stop <- [state.stopped]]
            <> ["refused: " <> note.message <> "; fix: " <> note.fix | Just note <- [state.refused]]
            <> section "pending:" (pendingLines state)
            <> section "rulings:" (map rulingLine state.rulings)
            <> section "answered:" (map answerLine state.answers)
            <> section "gaps:" state.gaps
            <> section "hooks:" (hookLines steps g)
  where
    answerLine answered = qidText answered.about.qid <> " " <> kindName answered.about.kind <> ": " <> oneLineText answered.about.text <> " - " <> answered.given
    section title = \case
        [] -> []
        items -> title : map ("  " <>) items

{- | What the hooks record of the flow's events, so no agent records them
by hand: the spawn and the hand-back of each step a subagent runs as a child
of a choice, the only steps whose spawn a hook sees ('opensChild'), that this flow takes.
-}
hookLines :: Steps -> OpenGraph -> [Text]
hookLines steps g =
    [ line
    | role <- agentRoles steps
    , AnyStep l (SomeStep s) <- stepsRunBy steps role
    , opensChild l s
    , let spawned = EventName (stepName s) spawnedOutcome
    , Set.member spawned flowEvents
    , line <-
        [ eventText spawned <> ": the " <> hookName SpawnHook <> " hook, as the lead spawns a " <> roleText role
        , eventText (EventName (stepName s) handedBackOutcome) <> ": the " <> hookName HandbackHook <> " hook, at its hand-back"
        ]
    ]
  where
    flowEvents = Set.fromList (map snd (Map.keys g.edges))

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
    askerText = \case
        Itself -> "this run"
        Subagent (AgentRole role) -> role
        ChildRun run -> runIdText run

{- | A role's brief skeleton: the task text of the step the run is at, or,
when the role runs no step there, of each step it runs; then the rule its
hand-back follows. A role that leads a flow, a child run, gets its task's
fields and the line that starts its run under this one, on the task's flow:
in the task's worktree and notes dir when the breakdown names them; a task
the breakdown lacks is returned as the failure.
-}
brief :: Steps -> RunState -> AgentRole -> Maybe TaskId -> Either TaskId Text
brief steps state agent task = case (leads agent, task) of
    (Just flow, Nothing) -> Right (initLine state flow "<dir>" "<id>")
    (Just _, Just taskId) -> maybe (Left taskId) (Right . taskBrief state) (lookupTask (currentFan state) taskId)
    (Nothing, _) -> Right $ case [text | At place <- [state.at], Right text <- [briefSection steps agent place.name]] of
        [] -> briefOf steps agent
        here : _ -> here

{- | A child engineer's brief head: its task's fields, then the line that
starts its run under this one, on the task's flow: in the task's worktree and
notes dir when the breakdown names them.
-}
taskBrief :: RunState -> Task -> Text
taskBrief state found = Text.unlines (taskLines found) <> "\n" <> taskInit
  where
    fan = currentFan state
    taskInit =
        maybe "" (\path -> "cd " <> Text.pack (shellPathText path) <> " && ") found.worktree
            <> initLine state found.flow (maybe "<dir>" (engineerNotes (Map.findWithDefault 0 found.id fan.rounds) (tries fan found.id) found.branch) found.repo) (taskIdText found.id)
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

-- | The line that starts a child run under this one: on this flow, in these notes, taking this task.
initLine :: RunState -> FlowName -> Text -> Text -> Text
initLine state flow notesText taskText =
    "state init --notes "
        <> notesText
        <> flowFlag
        <> " --parent "
        <> runIdText state.run
        <> " --parent-log "
        <> Text.pack (logOf state.start.notes)
        <> " --task "
        <> taskText
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
    "/tmp/engineer-" <> repo.owner <> "-" <> repo.name <> "-" <> Text.map slug (branchText branch) <> roundSuffix <> trySuffix <> "/"
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
runsOf steps agent = [(stepName s, row steps s) | AnyStep _ (SomeStep s) <- stepsRunBy steps agent]

sections :: [(StateName, Row)] -> Text
sections steps = Text.concat ["## " <> stateNameText name <> "\n\n" <> r.task <> "\n\n" | (name, r) <- steps]

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
skill how its run starts, a step runner its brief. Stated as facts, as
imperative text in a hook's context can read as an injected order.
-}
beginText :: Steps -> Begin -> Text
beginText steps = \case
    SpawnedLead ->
        "state: this lead's run is driven by `state`. Its first command is the `state init` line in its prompt, as written; "
            <> "then `state next`, until it prints DONE.\n"
    SpawnedWorker role -> briefOf steps role
    TypedSkill _ -> skillBegins
    CalledSkill _ -> skillBegins
  where
    skillBegins = "state: this skill begins with `state`: `state init ...`, then `state next`.\n"
