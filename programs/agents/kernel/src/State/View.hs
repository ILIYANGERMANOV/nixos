-- | The read-only views of a run: @state show@, @state pending@ and @state brief@.
module State.View (
    showRun,
    pendingLines,
    brief,
) where

import Data.Bool (bool)
import Data.Foldable (find)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import State.Advice (Facts (..), factLines)
import State.Ask (Question (..), kindName, oneLineText, qidText, rulingLine)
import State.Cap (SomeStep (..), allSteps, stateNameText, stepName)
import State.Codec (branchText, flowText, logOf, reasonText, taskIdText, topicText, urlText)
import State.Event (AgentRole (..), Asker (..), Asking (..), Note (..), Start (..), Stop (..), Task (..), TaskId, runIdText)
import State.Fan (Fan (..))
import State.Fold (Answer (..), Pending (..), RunState (..), Waits (..), askedAt)
import State.Graph (Node (..), Place (..))
import State.Mode (qualityName, sizeName)
import State.Render qualified as Render
import State.Steps (Row (..), Runner (..), Steps, row)

-- | Where the run is and what it carries: step, mode, rounds, questions, rulings.
showRun :: RunState -> Text
showRun state =
    Text.unlines $
        ["run: " <> runIdText state.run <> " (" <> flowText state.start.flow <> ")"]
            <> ["task: " <> state.start.task | not (Text.null state.start.task)]
            <> ["step: " <> stateNameText (askedAt state)]
            <> factLines (Facts Nothing Nothing) state
            <> ["stopped: " <> reasonText stop.reason <> " " <> stop.why | Just stop <- [state.stopped]]
            <> ["refused: " <> note.message <> "; fix: " <> note.fix | Just note <- [state.refused]]
            <> section "pending:" (pendingLines state)
            <> section "rulings:" (map rulingLine state.rulings)
            <> section "answered:" (map answerLine state.answers)
            <> section "held:" [taskIdText task <> " " <> urlText url | (task, url) <- state.fanOut.held]
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

{- | A role's brief skeleton: the entry text of the step the run is at, or,
when the role runs no step there, of each step it runs; then the rule its
hand-back follows. An engineer, a child flow, gets its task's fields and the
line that starts its run under this one; a task the breakdown lacks is
returned as the failure.
-}
brief :: Steps -> RunState -> AgentRole -> Maybe TaskId -> Either TaskId Text
brief steps state (AgentRole role) task = case role of
    "engineer" -> case task of
        Nothing -> Right (initLine "<id>")
        Just taskId -> case find ((== taskId) . (.id)) state.fanOut.tasks of
            Nothing -> Left taskId
            Just found -> Right (Text.unlines (taskLines found) <> "\n" <> initLine (taskIdText taskId))
    _ -> Right (Text.concat [entry name r | (name, r) <- briefed] <> rule)
  where
    initLine taskText =
        "state init --notes <dir> --parent "
            <> runIdText state.run
            <> " --parent-log "
            <> Text.pack (logOf state.start.notes)
            <> " --task "
            <> taskText
            <> "\n"
    taskLines found =
        [ "Task: " <> taskIdText found.id
        , "Quality: " <> qualityName found.quality
        , "Size: " <> sizeName found.size
        , "Base: " <> branchText found.base
        , "Branch: " <> branchText found.branch
        , "Depends on: " <> listed (map taskIdText found.deps)
        , "QA: " <> yesNo found.qa
        , "Heavy: " <> yesNo found.heavy
        , "Security-sensitive: " <> listed (map topicText (Set.toList found.security))
        ]
    listed = \case
        [] -> "none"
        items -> Text.intercalate ", " items
    yesNo = bool "no" "yes"
    runs = [(stepName s, row steps s) | SomeStep s <- allSteps, (row steps s).runner == Agent (AgentRole role)]
    briefed = case [step | step@(name, _) <- runs, At place <- [state.at], place.name == name] of
        [] -> runs
        here -> here
    entry name r = "## " <> stateNameText name <> "\n\n" <> r.entry <> "\n\n"
    rule
        | role `elem` ["implementer", "refactorer", "fixer"] = Render.stopRule
        | role == "review-lead" = Render.planWrong
        | otherwise = ""
