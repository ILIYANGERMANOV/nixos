{- | The read-only views of a run: @state show@, @state pending@ and @state
brief@; and the texts that need no run: a role's brief and how work begins.
-}
module State.Cli.View (
    showRun,
    pendingLines,
    brief,
    briefOf,
    beginText,
) where

import Data.Bool (bool)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import State.Category.Fuel (fuelLabel)
import State.Category.Graph (Node (..), OpenGraph, Place (..))
import State.Category.Step (SomeStep (..), StateName, stateNameText, stepName)
import State.Cli.Render qualified as Render
import State.FlowName (namedFlowText)
import State.Protocol.Advice (Facts (..), factLines)
import State.Protocol.Hook (Begin (..))
import State.Role (leads)
import State.Run.Ask (Parent (..), Principal (ByRole), Question (..), kindName, oneLineText, qidText, rulingLine)
import State.Run.Codec (branchText, flowText, logOf, reasonText, taskIdText, topicText, urlText)
import State.Run.Event (AgentRole (..), Asker (..), Asking (..), Branch, Note (..), Repo (..), Shape (..), Start (..), Stop (..), Task (..), TaskId, runIdText)
import State.Run.Fan (Fan (..), lookupTask)
import State.Run.Fold (Answer (..), Pending (..), RunState (..), Waits (..), askedAt, currentFan)
import State.Step.Artifact (shellPathText, slugChar)
import State.Step.Catalog (AnyStep (..))
import State.Table (Row (..), Steps, row, stepsRunBy)

-- | Where the run is and what it carries: step, mode, rounds, questions, rulings.
showRun :: OpenGraph -> RunState -> Text
showRun g state =
    Text.unlines $
        ["run: " <> runIdText state.run <> " (" <> flowText state.start.flow <> ")"]
            <> ["task: " <> taskIdText parent.task | ByRole parent _ <- [state.start.principal]]
            <> ["step: " <> stateNameText (askedAt state)]
            <> factLines g (Facts Nothing Nothing []) state
            <> ["stopped: " <> reasonText stop.reason <> " " <> stop.why | Just stop <- [state.stopped]]
            <> ["refused: " <> note.message <> "; fix: " <> note.fix | Just note <- [state.refused]]
            <> section "pending:" (pendingLines state)
            <> section "rulings:" (map rulingLine state.rulings)
            <> section "answered:" (map answerLine state.answers)
  where
    answerLine answered = qidText answered.about.qid <> " " <> kindName answered.about.kind <> ": " <> oneLineText answered.about.text <> " - " <> answered.given
    section title = \case
        [] -> []
        items -> title : map ("  " <>) items

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
    (Just flow, Nothing) -> Right (initLine flow "<dir>" "<id>")
    (Just _, Just taskId) -> case lookupTask fan taskId of
        Nothing -> Left taskId
        Just found -> Right (Text.unlines (taskLines found) <> "\n" <> taskInit found)
    (Nothing, _) -> Right $ case [step | step@(name, _) <- runsOf steps agent, At place <- [state.at], place.name == name] of
        [] -> briefOf steps agent
        here -> sections here <> ruleOf agent
  where
    fan = currentFan state
    taskInit found =
        maybe "" (\path -> "cd " <> Text.pack (shellPathText path) <> " && ") found.worktree
            <> initLine found.flow (maybe "<dir>" (engineerNotes (Map.findWithDefault 0 found.id fan.rounds) found.branch) found.repo) (taskIdText found.id)
    initLine flow notesText taskText =
        "state init --notes "
            <> notesText
            <> flowFlag flow
            <> " --parent "
            <> runIdText state.run
            <> " --parent-log "
            <> Text.pack (logOf state.start.notes)
            <> " --task "
            <> taskText
            <> "\n"
    -- The default flow is left out, so an engineer's line reads as it always has.
    flowFlag = maybe "" (" --flow " <>) . namedFlowText
    taskLines found =
        [ "Task: " <> taskIdText found.id
        , "Fuel: " <> fuelLabel found.fuel
        , "Base: " <> branchText found.base
        , "Branch: " <> branchText found.branch
        , "Depends on: " <> listed (map taskIdText found.deps)
        , "QA: " <> yesNo found.qa
        , "Heavy: " <> yesNo found.heavy
        , "Security-sensitive: " <> listed (map topicText (Set.toList found.security))
        ]
            <> case found.shape of
                OwnPr -> []
                RoundOn url -> ["Round on PR: " <> urlText url]
    listed = \case
        [] -> "none"
        items -> Text.intercalate ", " items
    yesNo = bool "no" "yes"

{- | The notes dir the engineer skill names for a task's run,
@/tmp/engineer-<owner>-<repo>-<slug>/@, the slug its branch with each
character but a 'slugChar' a @-@: a @/@, and whatever a shell would read.
The run of the task's nth round gets @-r<n>@: an earlier run's dir is finished.
-}
engineerNotes :: Int -> Branch -> Repo -> Text
engineerNotes rounds branch repo = "/tmp/engineer-" <> repo.owner <> "-" <> repo.name <> "-" <> Text.map slug (branchText branch) <> suffix <> "/"
  where
    slug c = if slugChar c then c else '-'
    suffix = if rounds > 0 then "-r" <> Text.pack (show rounds) else ""

{- | A role's brief wherever a run is: the task text of each step it runs,
then the rule its hand-back follows. 'brief' gives it at a step the role
does not run.
-}
briefOf :: Steps -> AgentRole -> Text
briefOf steps agent = sections (runsOf steps agent) <> ruleOf agent

-- | Each step a role runs, by name, with its row.
runsOf :: Steps -> AgentRole -> [(StateName, Row)]
runsOf steps agent = [(stepName s, row steps s) | AnyStep _ (SomeStep s) <- stepsRunBy steps agent]

sections :: [(StateName, Row)] -> Text
sections steps = Text.concat ["## " <> stateNameText name <> "\n\n" <> r.task <> "\n\n" | (name, r) <- steps]

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
    TypedSkill -> skillBegins
    CalledSkill -> skillBegins
  where
    skillBegins = "state: this skill begins with `state`: `state init ...`, then `state next`.\n"
