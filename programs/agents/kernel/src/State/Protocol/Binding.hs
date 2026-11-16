{- | Which run an agent works in, whatever directory its hooks fire in (#402).
A subagent's hooks fire in its spawner's directory, not in the worktree its run
is at, so each hook first reads the agent's binding to its run:

@
<root>/<session>/main                       the session's own agent
<root>/<session>/<agent id>                 a subagent
<root>/<session>/handback-<agent id>.json   a hand-back seen before its agent was bound
<root>/<session>/lead-<main|agent id>       the lead skill an agent began (@engineer@)
@

The root is @$XDG_STATE_HOME/state/bindings@. A binding's text is the @run@
line @state init@ prints, so init's output and the store share one codec. An
agent binds itself by its @state init@; a worker, which never inits, is bound
by its spawner's hook to the spawner's run.
-}
module State.Protocol.Binding (
    Binding (..),
    renderBinding,
    parseBinding,
    bindingIn,
    AgentId (..),
    Key (..),
    Slot,
    storeRoot,
    slotOf,
    bindingFile,
    stashFile,
    leadFile,
    Worktree (..),
    resolve,
    staleNote,
    rebound,
) where

import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import State.Run.Event (SessionId (..))
import State.Run.Id (AgentId (..), RunId, parseRunId, runIdText)
import System.FilePath (equalFilePath, isAbsolute, (</>))

-- | A run, its notes dir and the top of the worktree it is at, both absolute.
data Binding = Binding {run :: RunId, notes :: FilePath, toplevel :: FilePath}
    deriving stock (Eq, Show)

{- | @run <id> <notes> <toplevel>@, space separated. The run id is init's hex
and the notes dir holds no whitespace (init's parser refuses it); the toplevel
comes last and is the rest of the line, as git may name a path with spaces.
-}
renderBinding :: Binding -> Text
renderBinding binding = Text.unwords ["run", runIdText binding.run, Text.pack binding.notes, Text.pack binding.toplevel]

parseBinding :: Text -> Maybe Binding
parseBinding line = do
    rest <- Text.stripPrefix "run " line
    let (rawRun, afterRun) = Text.breakOn " " rest
    run <- parseRunId rawRun
    (notes, afterNotes) <- Text.breakOn " " <$> Text.stripPrefix " " afterRun
    toplevel <- Text.stripPrefix " " afterNotes
    if Text.null notes || Text.null toplevel || Text.elem '\n' toplevel
        then Nothing
        else Just (Binding run (Text.unpack notes) (Text.unpack toplevel))

-- | The binding among a text's lines: a successful @state init@'s output, or a binding's file.
bindingIn :: Text -> Maybe Binding
bindingIn = listToMaybe . mapMaybe parseBinding . Text.lines

-- | Whose binding: the session's own agent, or a subagent by its id.
data Key = Main | AgentKey AgentId
    deriving stock (Eq, Show)

-- | Where a key's files live: its session's directory and its own name there.
data Slot = Slot {dir :: FilePath, name :: FilePath}
    deriving stock (Eq, Show)

{- | The store's root from @XDG_STATE_HOME@ and @HOME@, as the XDG base
directory spec reads them: a relative or empty one is unset. No root, no store.
-}
storeRoot :: Maybe FilePath -> Maybe FilePath -> Maybe FilePath
storeRoot xdgStateHome home = (</> "state" </> "bindings") <$> base
  where
    base = case (absolute =<< xdgStateHome, absolute =<< home) of
        (Just state, _) -> Just state
        (Nothing, Just h) -> Just (h </> ".local" </> "state")
        (Nothing, Nothing) -> Nothing
    absolute path = if isAbsolute path then Just path else Nothing

{- | A key's slot in its session, 'Nothing' when the session or the agent id
is no single path component: a binding is never written outside the store.
Claude Code's agent ids are hex, never @main@.
-}
slotOf :: FilePath -> SessionId -> Key -> Maybe Slot
slotOf root (SessionId session) key = Slot . (root </>) <$> component session <*> component keyName
  where
    keyName = case key of
        Main -> "main"
        AgentKey agent -> agent.agentIdText
    component text
        | Text.null text || text `elem` [".", ".."] || Text.elem '/' text || Text.elem '\0' text = Nothing
        | otherwise = Just (Text.unpack text)

bindingFile :: Slot -> FilePath
bindingFile slot = slot.dir </> slot.name

stashFile :: Slot -> FilePath
stashFile slot = slot.dir </> ("handback-" <> slot.name <> ".json")

-- | Marks a key a lead: holds the lead skill its agent began, so its writes wait for its run. Never removed.
leadFile :: Slot -> FilePath
leadFile slot = slot.dir </> ("lead-" <> slot.name)

-- | Whether a binding's worktree still stands: one is removed once its PR merged.
data Worktree = Standing | Removed
    deriving stock (Eq, Show)

{- | The directory a hook runs the caller's run in: its binding's worktree
while it stands, none once it is removed (its run is done); with no binding,
the session's own agent's directory; an unbound subagent has none, as its
directory is its spawner's and may hold another run.
-}
resolve :: Key -> Maybe (Binding, Worktree) -> FilePath -> Maybe FilePath
resolve key bound cwd = case (bound, key) of
    (Just (binding, Standing), _) -> Just binding.toplevel
    (Just (_, Removed), _) -> Nothing
    (Nothing, Main) -> Just cwd
    (Nothing, AgentKey _) -> Nothing

-- | A binding whose worktree holds another run now: the hook records nothing and says so.
staleNote :: Binding -> RunId -> Maybe Text
staleNote binding here
    | binding.run == here = Nothing
    | otherwise =
        Just
            ( "state: this agent is bound to run "
                <> runIdText binding.run
                <> ", but "
                <> Text.pack binding.toplevel
                <> " holds run "
                <> runIdText here
                <> " now; the hook recorded nothing\n"
            )

-- | A binding of the run to the worktree it moved from, bound to the one it moved to; none for another.
rebound :: RunId -> FilePath -> FilePath -> Binding -> Maybe Binding
rebound run from to binding
    | binding.run == run, equalFilePath binding.toplevel from = Just binding {toplevel = to}
    | otherwise = Nothing
