{- | Whether a shell command's @state@ calls reach the run its agent is bound
to (#402). An agent's hooks fire in its spawner's directory, and so may its
shell: a child engineer's @state next@ from its parent's checkout would read
the parent's run. @state-hook route@ denies such a call, naming the fix, as it
does a subagent's @state init@ that would start a user's run ('parentlessInit').

The command is read as a shell would only as far as is simple: simple
commands split at @&&@, @||@, @;@, @|@, @&@ and newlines, quotes and
redirections read, and a @cd <dir>@ moving the calls after it. What this
reader leaves be (a subshell, a substitution, a heredoc, an open quote, a
@cd@ to a variable) routes nothing: the call goes on.

An agent bound to no run is gated instead (#378): a lead's write waits for
its run ('gate'), so its record starts before its work does. One bound to a
run where the architect flow runs writes no code ('readOnly').
-}
module State.Cli.Route (
    StateCall (..),
    Reach (..),
    Target (..),
    stateCalls,
    parentlessInit,
    route,
    cdThen,
    Lead (..),
    leadOf,
    gate,
    readOnly,
    writesNoCode,
) where

import Control.Monad (guard)
import Data.Char (isDigit, isSpace)
import Data.List (isInfixOf, stripPrefix)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import State.Cli.Command (
    Command (..),
    Exit (..),
    Failure (..),
    InitArgs (..),
    Origin (..),
    RunCommand (..),
    architectInitFix,
    chiefInitFix,
    failureText,
    initFix,
    parseCommand,
    tenXInitFix,
 )
import State.Protocol.Binding (Binding (..))
import State.Protocol.Hook (Gate (..), LeadSkill (..))
import State.Protocol.Record (Recording (NeedDone))
import State.Role (FlowName (..), leads)
import State.Run.Event (AgentRole, RunId, runIdText)
import State.Step.Artifact (shellPath)
import State.Table (Steps)
import System.FilePath (splitDirectories, (</>))

-- | A @state@ call that reads a run: the directory it runs in, its subcommand, its text as written, and whose run it may reach.
data StateCall = StateCall {dir :: FilePath, sub :: Text, written :: Text, reach :: Reach}
    deriving stock (Eq, Show)

{- | The runs a bound agent's call may act in: its own run's only, or a
child run's too, as a parent records its child's awaited CI or answers its
question there (#479).
-}
data Reach = OwnRun | OwnOrChildRun
    deriving stock (Eq, Show)

{- | The worktree a call's directory is in: its top, and the parent of the
run it holds, if that run is a child.
-}
data Target = Target {top :: FilePath, parent :: Maybe RunId}
    deriving stock (Eq, Show)

{- | The calls of a command run in this directory that read a run, in order.
@init@, @help@, @render@, @show@, @dump@, @artifact show@, @resume@, @report@, @sql@ and argv @state@
refuses never route.
-}
stateCalls :: Steps -> FilePath -> Text -> [StateCall]
stateCalls steps cwd command =
    [ StateCall at sub written (reachOf parsed)
    | (Just at, sub, parsed, written) <- stateCommands steps (Just cwd) command
    , readsOne parsed
    ]
  where
    readsOne = \case
        Init _ -> False
        Help -> False
        Render _ _ -> False
        Next -> True
        HandbackOf _ _ -> True
        Move _ -> True
        Focus _ _ -> True
        Tasks -> True
        -- It names its run and writes nothing, whatever directory it runs in.
        Dump _ -> False
        ShowArtifact _ -> False
        -- It names the gap's run, whatever directory it runs in.
        MoveGap _ _ -> False
        HandOver _ -> True
        Register {} -> True
        -- It writes nothing, whatever run it reads.
        Resume _ _ -> False
        -- It opens with the run's id, so it reads another run's state safely (#432).
        OnRun ShowRun -> False
        -- It names the need's run, whatever directory it runs in, as a gap move does.
        OnRun (Record (NeedDone _ _)) -> False
        OnRun _ -> True
        -- They read every run and write nothing, whatever directory they run in.
        Report _ _ -> False
        Sql _ -> False

{- | Whose run a command may act in. A parent records in its child's run and
answers its question there, as the child's hand-back prints; every other
command acts in the agent's own run only.
-}
reachOf :: Command -> Reach
reachOf = \case
    OnRun on -> case on of
        Record _ -> OwnOrChildRun
        Answer {} -> OwnOrChildRun
        RecordUnknown _ -> OwnRun
        Brief _ _ -> OwnRun
        ShowRun -> OwnRun
        Override _ _ -> OwnRun
        Void _ _ -> OwnRun
        AskOwn {} -> OwnRun
        AskFrom {} -> OwnRun
        RuleOn {} -> OwnRun
        Forward _ _ -> OwnRun
        Retry _ _ -> OwnRun
        Park _ _ -> OwnRun
        StopRun _ -> OwnRun
        Pending -> OwnRun
        NoteOn _ _ -> OwnRun
        MoveEpic _ _ -> OwnRun
    Init _ -> OwnRun
    HandbackOf _ _ -> OwnRun
    Next -> OwnRun
    Render _ _ -> OwnRun
    Help -> OwnRun
    Move _ -> OwnRun
    Dump _ -> OwnRun
    Focus _ _ -> OwnRun
    Tasks -> OwnRun
    HandOver _ -> OwnRun
    ShowArtifact _ -> OwnRun
    MoveGap _ _ -> OwnRun
    Register {} -> OwnRun
    Resume _ _ -> OwnRun
    Report _ _ -> OwnRun
    Sql _ -> OwnRun

{- | Why a subagent's command is denied: a @state init@ in it starts a user's
run, which may spawn in the background and ask the user, neither of which a
subagent can (#459). Its run is a child: of its fan-out's run, or, spawned
outside one, of its caller ('FromCaller').
-}
parentlessInit :: Steps -> Text -> Maybe Text
parentlessInit steps command =
    listToMaybe
        [ denial sub written
        | (_, sub, Init args, written) <- stateCommands steps Nothing command
        , FromUser _ <- [args.origin]
        ]
  where
    denial sub written =
        failureText
            sub
            Failure
                { exit = BadInput
                , what = written <> " starts a user's run"
                , why =
                    "a subagent's run is a child: it neither asks the user nor spawns in the background"
                , fix =
                    "rerun it with --parent <run> from your brief, plus --task <id> under a fan-out; with no parent run, with --child"
                }

{- | Every @state@ call of a command that parses, in order: the directory it
runs in ('Nothing': unknown, as a @cd@ this reader leaves be moved it, or
none was given), its subcommand, the command and its text as written.
-}
stateCommands ::
    Steps -> Maybe FilePath -> Text -> [(Maybe FilePath, Text, Command, Text)]
stateCommands steps cwd command = maybe [] (walk cwd) (segments command)
  where
    walk dir = \case
        [] -> []
        segment : rest -> case segment.tokens of
            ["cd", target] -> walk ((</> Text.unpack target) <$> (guard (plainDir target) *> dir)) rest
            "cd" : _ -> walk Nothing rest
            "state" : argv
                | Right (sub, Right parsed) <- parseCommand steps argv ->
                    (dir, sub, parsed, segment.written) : walk dir rest
            _ -> walk dir rest
    -- A directory the shell reads as written: no home, variable or previous directory.
    plainDir target = case Text.uncons target of
        Just (first, _) -> first `notElem` ['~', '-'] && not (Text.any (== '$') target)
        Nothing -> False

{- | Why the first call aimed at another worktree than the bound run's is
denied, by the worktree each call's directory is in ('Nothing': none). A
call that may reach a child run goes on in a worktree whose run is the
bound run's child. Tops are compared whole, never as a prefix: a worktree
may sit inside another.
-}
route :: Binding -> [(StateCall, Maybe Target)] -> Maybe Text
route bound calls =
    listToMaybe
        [ denial call ((.top) <$> target)
        | (call, target) <- calls
        , not (maybe False (reaches call.reach) target)
        ]
  where
    reaches reach target =
        target.top == bound.toplevel || case reach of
            OwnRun -> False
            OwnOrChildRun -> target.parent == Just bound.run
    denial call top =
        failureText
            call.sub
            Failure
                { exit = BadInput
                , what =
                    maybe
                        (Text.pack call.dir <> " is in no git worktree")
                        (\other -> "the run at " <> Text.pack other <> " is not this agent's")
                        top
                , why =
                    "this agent is bound to run "
                        <> runIdText bound.run
                        <> " at "
                        <> Text.pack bound.toplevel
                , fix = cdThen bound.toplevel call.written
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
    SkillLead TenXSkill ->
        denial (tenXInitFix <> ", in the run directory Intake or Resume names")
            <$> writeOf call
    SkillLead ArchitectSkill -> denial architectInitFix <$> writeOf call
    SkillLead ChiefSkill -> denial chiefInitFix <$> writeOf call
    RoleLead ->
        denial "run the `state init` line in your prompt, as written" <$> writeOf call
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

{- | Why a call is denied where this flow runs, in a run whose notes dir is
given: the architect's design goes into its notes and its ticket, so it
edits and writes only files directly in the notes dir, none below it, and commits, pushes and
opens or merges a PR nowhere. It writes, edits or comments on the ticket
(@gh issue create@, @edit@, @comment@) at any state, as its researchers
spawn and its shell reads. Other flows write, the chief where no scope runs
the architect's.
-}
readOnly :: FilePath -> FlowName -> Gate -> Maybe Text
readOnly notes flow call = guard (writesNoCode flow) *> (denial <$> codeWrite)
  where
    codeWrite = case call of
        Spawns -> Nothing
        Edits file -> outsideNotes file
        Writes file -> outsideNotes file
        RunsShell _ -> writeOf call
    outsideNotes file = guard (not (any (directlyIn notes) file)) *> writeOf call
    denial act =
        failureText
            "architect"
            Failure
                { exit = BadInput
                , what = "the architect flow changes no code, so " <> act <> " is denied"
                , why =
                    "an architect run writes only its notes, in "
                        <> Text.pack notes
                        <> ", and its ticket"
                , fix =
                    "keep the design in the discussion and in "
                        <> Text.pack (notes </> "notes.md")
                        <> ", which Edit and Write may change; write or edit the ticket at any point: a quoted heredoc (<<'EOF') into `gh issue create` or `gh issue edit <number> --body-file -`"
                }

{- | Whether an absolute path is a file directly in a directory, read
lexically: @.@ and @..@ resolved, so @<dir>/../x@ is outside. Nothing
deeper counts: a worktree may sit below the notes dir, and its code is not
the notes. Symlinks are not followed: a route reads no disk before every
edit, and a link in the notes dir is the run's own.
-}
directlyIn :: FilePath -> FilePath -> Bool
directlyIn dir path = case stripPrefix (lexical dir) (lexical path) of
    Just [_] -> True
    Just _ -> False
    Nothing -> False
  where
    lexical = reverse . foldl' step [] . splitDirectories
    step parts part = case (part, parts) of
        (".", _) -> parts
        -- The root's parent is the root.
        ("..", _ : up@(_ : _)) -> up
        ("..", _) -> parts
        _ -> part : parts

-- | Whether a flow changes no code, so 'readOnly' denies its writes.
writesNoCode :: FlowName -> Bool
writesNoCode = \case
    ArchitectFlow -> True
    EngineerFlow -> False
    TenXFlow -> False
    ChiefFlow -> False

-- | A write a run must see, as a denial names it; 'Nothing' for any other call.
writeOf :: Gate -> Maybe Text
writeOf = \case
    Edits _ -> Just "its edit"
    Writes _ -> Just "its write"
    Spawns -> Just "its spawn"
    RunsShell command ->
        listToMaybe
            [ "`" <> segment.written <> "`"
            | segment <- fromMaybe [] (segments command)
            , recorded segment.tokens
            ]

-- | A command a run records: a commit, a push, a PR opened or merged. @git -C <dir>@ is git still.
recorded :: [Text] -> Bool
recorded = \case
    "git" : "-C" : _ : rest -> recorded ("git" : rest)
    "git" : sub : _ -> sub `elem` ["commit", "push"]
    "gh" : "pr" : sub : _ -> sub `elem` ["create", "merge"]
    _ -> False

-- | A shell line that runs this command in this directory.
cdThen :: FilePath -> Text -> Text
cdThen dir command = "cd " <> shellWord dir <> " && " <> command

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
    '<' : '<' : rest -> heredoc acc rest
    '&' : '&' : rest -> scan (close acc) rest
    '|' : '|' : rest -> scan (close acc) rest
    '&' : '>' : rest -> redirect "&>" acc rest
    c : rest
        | c `elem` ['<', '>'] -> redirect [c] (dropFd acc) rest
        | c `elem` [';', '|', '&', '\n'] -> scan (close acc) rest
        | isSpace c -> scan (wrote [c] (endWord acc)) rest
        | c == '#', Nothing <- acc.word -> scan acc (dropWhile (/= '\n') rest)
        | otherwise -> scan (wrote [c] (inWord [c] acc)) rest

{- | A here-document: its operator and delimiter stay in the written text;
its body, the lines up to the delimiter's own, is no command. A line with
another here-document, or a body with no end, is left be.
-}
heredoc :: Acc -> String -> Maybe Acc
heredoc acc input = case (delimiter, break (== '\n') afterMarker) of
    (_ : _, (line, '\n' : body))
        | not ("<<" `isInfixOf` line)
        , (_, _ : after) <- break ((== delimiter) . stripTabs) (lines body) ->
            scan
                (wrote ("<<" <> dash <> spaces <> marker) (endWord acc))
                (line <> "\n" <> unlines after)
    _ -> Nothing
  where
    -- @<<-@ strips the body's leading tabs, the delimiter's line's too.
    (dash, afterDash) = span (== '-') input
    (spaces, afterSpaces) = span (== ' ') afterDash
    (marker, afterMarker) =
        break
            (\c -> isSpace c || c `elem` [';', '|', '&', '<', '>', '(', ')'])
            afterSpaces
    delimiter = filter (`notElem` ['\'', '"', '\\']) marker
    stripTabs = if null dash then id else dropWhile (== '\t')

-- | Inside double quotes: the word's text so far and the text as written, each reversed.
doubleQuoted :: Acc -> String -> String -> String -> Maybe Acc
doubleQuoted acc value text = \case
    '"' : rest -> scan (wrote ('"' : reverse text <> "\"") (inWord (reverse value) acc)) rest
    '\\' : c : rest
        | c `elem` ['"', '\\', '$', '`'] ->
            doubleQuoted acc (c : value) (c : '\\' : text) rest
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
    (target, after) =
        break
            (\c -> isSpace c || c `elem` [';', '|', '&', '<', '>', '(', ')'])
            afterSpaces

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
