-- | The read-only views of a run: @state show@, @state pending@ and @state brief@.
module State.View (
    showRun,
    pendingLines,
    brief,
) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import State.Advice (Facts (..), factLines)
import State.Ask (Question (..), kindName, oneLineText, qidText, rulingLine)
import State.Cap (SomeStep (..), StateName (..), allSteps, stepName)
import State.Codec (flowText, reasonText)
import State.Event (AgentRole (..), Asker (..), Asking (..), Note (..), Start (..), Stop (..), runIdText)
import State.Fold (Pending (..), RunState (..), Waits (..), askedAt)
import State.Render qualified as Render
import State.Shell.Log (logOf)
import State.Steps (Row (..), Runner (..), Steps, row)

-- | Where the run is and what it carries: step, mode, rounds, questions, rulings.
showRun :: RunState -> Text
showRun state =
    Text.unlines $
        ["run: " <> runIdText state.run <> " (" <> flowText state.start.flow <> ")"]
            <> ["task: " <> state.start.task | not (Text.null state.start.task)]
            <> ["step: " <> nameText (askedAt state)]
            <> factLines (Facts Nothing Nothing) state
            <> ["stopped: " <> reasonText stop.reason <> " " <> stop.why | Just stop <- [state.stopped]]
            <> ["refused: " <> note.message <> "; fix: " <> note.fix | Just note <- [state.refused]]
            <> section "pending:" (pendingLines state)
            <> section "rulings:" (map rulingLine state.rulings)
  where
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

{- | A role's brief skeleton: the entry text of each step it runs, then the
rule its hand-back follows. An engineer, a child flow, gets the line that
starts its run under this one.
-}
brief :: Steps -> RunState -> AgentRole -> Maybe Text -> Text
brief steps state (AgentRole role) task = case role of
    "engineer" ->
        "state init --notes <dir> --parent "
            <> runIdText state.run
            <> " --parent-log "
            <> Text.pack (logOf state.start.notes)
            <> " --task "
            <> fromMaybe "<id>" task
            <> "\n"
    _ -> Text.concat [entry name r | (name, r) <- rows, r.runner == Agent (AgentRole role)] <> rule
  where
    rows = [(stepName s, row steps s) | SomeStep s <- allSteps]
    entry name r = "## " <> nameText name <> "\n\n" <> r.entry <> "\n\n"
    rule
        | role `elem` ["implementer", "refactorer", "fixer"] = Render.stopRule
        | role == "review-lead" = Render.planWrong
        | otherwise = ""

nameText :: StateName -> Text
nameText (StateName name) = name
