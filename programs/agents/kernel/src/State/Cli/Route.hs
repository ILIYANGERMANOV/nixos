{- | Whether a shell command's @state@ calls reach the run its agent is bound
to (#402). An agent's hooks fire in its spawner's directory, and so may its
shell: a child engineer's @state next@ from its parent's checkout would read
the parent's run. @state-hook route@ denies such a call, naming the fix.

The command is read as a shell would only as far as is simple: simple
commands split at @&&@, @||@, @;@, @|@, @&@ and newlines, quotes and
redirections read, and a @cd <dir>@ moving the calls after it. What this
reader leaves be (a subshell, a substitution, a heredoc, an open quote, a
@cd@ to a variable) routes nothing: the call goes on.

An agent bound to no run is gated instead (#378): a lead's write waits for
its run ('gate'), so its record starts before its work does.
-}
module State.Cli.Route (
    StateCall (..),
    stateCalls,
    route,
    Lead (..),
    leadOf,
    gate,
) where

import Control.Monad (guard)
import Data.Char (isDigit, isSpace)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import State.Cli.Command (Command (..), Exit (..), Failure (..), RunCommand (ShowRun), failureText, initFix, parseCommand, tenXInitFix)
import State.Protocol.Binding (Binding (..))
import State.Protocol.Hook (Gate (..), LeadSkill (..))
import State.Role (leads)
import State.Run.Event (AgentRole, runIdText)
import State.Step.Artifact (shellPath)
import State.Table (Steps)
import System.FilePath ((</>))

-- | A @state@ call that reads a run: the directory it runs in, its subcommand, and its text as written.
data StateCall = StateCall {dir :: FilePath, sub :: Text, written :: Text}
    deriving stock (Eq, Show)

{- | The calls of a command run in this directory that read a run, in order.
@init@, @help@, @render@, @show@ and argv @state@ refuses never route.
-}
stateCalls :: Steps -> FilePath -> Text -> [StateCall]
stateCalls steps cwd command = maybe [] (walk (Just cwd)) (segments command)
  where
    walk dir = \case
        [] -> []
        segment : rest -> case segment.tokens of
            ["cd", target] -> walk ((</> Text.unpack target) <$> (guard (plainDir target) *> dir)) rest
            "cd" : _ -> walk Nothing rest
            "state" : argv
                | Just at <- dir
                , Just sub <- readsRun steps argv ->
                    StateCall at sub segment.written : walk dir rest
            _ -> walk dir rest
    -- A directory the shell reads as written: no home, variable or previous directory.
    plainDir target = case Text.uncons target of
        Just (first, _) -> first `notElem` ['~', '-'] && not (Text.any (== '$') target)
        Nothing -> False

-- | The subcommand of argv that reads the run of the directory it runs in.
readsRun :: Steps -> [Text] -> Maybe Text
readsRun steps argv = case parseCommand steps argv of
    Right (sub, Right command) -> sub <$ guard (readsOne command)
    Right (_, Left _) -> Nothing
    Left _ -> Nothing
  where
    readsOne = \case
        Init _ -> False
        Help -> False
        Render _ _ -> False
        Next -> True
        HandbackOf _ _ -> True
        Move _ -> True
        -- It opens with the run's id, so it reads another run's state safely (#432).
        OnRun ShowRun -> False
        OnRun _ -> True

{- | Why the first call aimed at another worktree than the bound run's is
denied, by the top of the worktree each call's directory is in ('Nothing':
none). Compared whole, never as a prefix: a worktree may sit inside another.
-}
route :: Binding -> [(StateCall, Maybe FilePath)] -> Maybe Text
route bound calls = listToMaybe [denial call top | (call, top) <- calls, top /= Just bound.toplevel]
  where
    denial call top =
        failureText
            call.sub
            Failure
                { exit = BadInput
                , what = maybe (Text.pack call.dir <> " is in no git worktree") (\other -> "the run at " <> Text.pack other <> " is not this agent's") top
                , why = "this agent is bound to run " <> runIdText bound.run <> " at " <> Text.pack bound.toplevel
                , fix = "cd " <> shellWord bound.toplevel <> " && " <> call.written
                }

-- | Whether an agent leads a run, and so where its @state init@ line is.
data Lead
    = NotLead
    | -- | It began a lead skill (@/engineer@): its init is the skill's.
      SkillLead LeadSkill
    | -- | A role that leads a flow, spawned: its prompt holds its init line.
      RoleLead
    deriving stock (Eq, Show)

{- | An agent by its role and the lead skill it began, if any. A role leads
by 'leads', whatever skill it began; any other agent leads only by a skill.
-}
leadOf :: Maybe AgentRole -> Maybe LeadSkill -> Lead
leadOf role began = case (leads =<< role, began) of
    (Just _, _) -> RoleLead
    (Nothing, Just skill) -> SkillLead skill
    (Nothing, Nothing) -> NotLead

{- | Why an unbound agent's call is denied: a lead edits, writes, commits,
pushes, opens or merges a PR and spawns only once its run exists. Reads,
research and @state@ itself go on, as does every call of an agent that leads
nothing. A command this reader leaves be goes on: the gate is a nudge, not a
sandbox.
-}
gate :: Lead -> Gate -> Maybe Text
gate lead call = case lead of
    NotLead -> Nothing
    SkillLead EngineerSkill -> denial initFix <$> writeOf call
    SkillLead TenXSkill -> denial (tenXInitFix <> ", in the run directory Intake or Resume names") <$> writeOf call
    RoleLead -> denial "run the `state init` line in your prompt, as written" <$> writeOf call
  where
    denial fix act =
        failureText
            "init"
            Failure
                { exit = BadInput
                , what = "this lead has no run, so " <> act <> " waits"
                , why = "a lead's writes go in its run's record, which `state init` starts"
                , fix
                }

-- | A write a run must see, as a denial names it; 'Nothing' for any other call.
writeOf :: Gate -> Maybe Text
writeOf = \case
    Edits -> Just "its edit"
    Writes -> Just "its write"
    Spawns -> Just "its spawn"
    RunsShell command -> listToMaybe ["`" <> segment.written <> "`" | segment <- fromMaybe [] (segments command), recorded segment.tokens]

-- | A command a run records: a commit, a push, a PR opened or merged. @git -C <dir>@ is git still.
recorded :: [Text] -> Bool
recorded = \case
    "git" : "-C" : _ : rest -> recorded ("git" : rest)
    "git" : sub : _ -> sub `elem` ["commit", "push"]
    "gh" : "pr" : sub : _ -> sub `elem` ["create", "merge"]
    _ -> False

-- | A path as a shell line reads it back: bare when it can be, else single-quoted.
shellWord :: FilePath -> Text
shellWord path = case shellPath path of
    Just _ -> Text.pack path
    Nothing -> "'" <> Text.replace "'" "'\\''" (Text.pack path) <> "'"

-- | A simple command: its text as written, and its words, quotes read and redirections dropped.
data Segment = Segment {written :: Text, tokens :: [Text]}

-- | Reading so far: the segments done, then the current one's text and words, each reversed.
data Acc = Acc {done :: [Segment], raw :: String, ws :: [String], word :: Maybe String}

-- | A command's simple commands, those with words; 'Nothing' for syntax this reader leaves be.
segments :: Text -> Maybe [Segment]
segments = fmap (reverse . (.done) . close) . scan (Acc [] "" [] Nothing) . Text.unpack

scan :: Acc -> String -> Maybe Acc
scan acc = \case
    [] -> Just acc
    '\'' : rest -> case break (== '\'') rest of
        (quoted, '\'' : after) -> scan (wrote ('\'' : quoted <> "'") (inWord quoted acc)) after
        _ -> Nothing
    '"' : rest -> doubleQuoted acc "" "" rest
    -- A line continuation is no character at all.
    '\\' : '\n' : rest -> scan acc rest
    '\\' : c : rest -> scan (wrote ['\\', c] (inWord [c] acc)) rest
    '`' : _ -> Nothing
    '$' : '(' : _ -> Nothing
    '(' : _ -> Nothing
    ')' : _ -> Nothing
    '<' : '<' : _ -> Nothing
    '&' : '&' : rest -> scan (close acc) rest
    '|' : '|' : rest -> scan (close acc) rest
    '&' : '>' : rest -> redirect "&>" acc rest
    c : rest
        | c `elem` ['<', '>'] -> redirect [c] (dropFd acc) rest
        | c `elem` [';', '|', '&', '\n'] -> scan (close acc) rest
        | isSpace c -> scan (wrote [c] (endWord acc)) rest
        | c == '#', Nothing <- acc.word -> scan acc (dropWhile (/= '\n') rest)
        | otherwise -> scan (wrote [c] (inWord [c] acc)) rest

-- | Inside double quotes: the word's text so far and the text as written, each reversed.
doubleQuoted :: Acc -> String -> String -> String -> Maybe Acc
doubleQuoted acc value text = \case
    '"' : rest -> scan (wrote ('"' : reverse text <> "\"") (inWord (reverse value) acc)) rest
    '\\' : c : rest
        | c `elem` ['"', '\\', '$', '`'] -> doubleQuoted acc (c : value) (c : '\\' : text) rest
        | otherwise -> doubleQuoted acc (c : '\\' : value) (c : '\\' : text) rest
    -- A substitution may nest quotes this reader would misread.
    '`' : _ -> Nothing
    '$' : '(' : _ -> Nothing
    c : rest -> doubleQuoted acc (c : value) (c : text) rest
    [] -> Nothing

{- | A redirection, out of the words: its operator's rest (@>>@, @>&@) and
its target word, kept in the written text.
-}
redirect :: String -> Acc -> String -> Maybe Acc
redirect operator acc input = scan (wrote (operator <> more <> spaces <> target) (endWord acc)) after
  where
    (more, afterOperator) = span (`elem` ['>', '&', '|']) input
    (spaces, afterSpaces) = span (== ' ') afterOperator
    (target, after) = break (\c -> isSpace c || c `elem` [';', '|', '&', '<', '>', '(', ')']) afterSpaces

-- | The file descriptor a redirection names (@2>@) is no word.
dropFd :: Acc -> Acc
dropFd acc = case acc.word of
    Just fd | all isDigit fd -> acc {word = Nothing}
    _ -> endWord acc

wrote :: String -> Acc -> Acc
wrote text acc = acc {raw = reverse text <> acc.raw}

inWord :: String -> Acc -> Acc
inWord text acc = acc {word = Just (reverse text <> fromMaybe "" acc.word)}

endWord :: Acc -> Acc
endWord acc = case acc.word of
    Just w -> acc {ws = reverse w : acc.ws, word = Nothing}
    Nothing -> acc

-- | The current simple command done; one with no words is none.
close :: Acc -> Acc
close acc = Acc (segment <> acc.done) "" [] Nothing
  where
    ended = endWord acc
    segment = case reverse ended.ws of
        [] -> []
        found -> [Segment (Text.strip (Text.pack (reverse ended.raw))) (map Text.pack found)]
