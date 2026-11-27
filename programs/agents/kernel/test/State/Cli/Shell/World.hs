{- | The world @state@ and @state-hook@ run in, made of the test doubles: a
worktree on branch @feat@ at @/work@ whose base @main@ is on origin, its
notes dir @/notes@, and a GitHub with no PR for the branch yet. Each call is
one process: it runs a shell program in the world and leaves it changed, as
the e2e specs' calls do a temp repo.
-}
module State.Cli.Shell.World (
    World (..),
    Ran (..),
    newWorld,
    state,
    stateIn,
    hook,
    succeeded,
    startedRun,
    startedIn,
    putFile,
    tenXAtFanOut,
    tenXAtFanOutOf,
    tenXAtFanOutBy,
    childRun,
    atWorktree,
    addWorktree,
    childWorktree,
    logged,
    loggedIn,
    runOf,
    storeDown,
    loggedEvents,
    loggedEventsIn,
    headOf,
    draftPr,
    prOn,
    editLog,
    editLogIn,
    appendUnread,
    lessUnread,
    newerStart,
    logRows,
    fileBytes,
    prUrl,
    notes,
    sessionStart,
    sessionStartIn,
    handedBack,
    spawned,
    agentStarted,
    stateCall,
    editCall,
    spawnResult,
    spawnResultOf,
    spawnResultBy,
    initRan,
    agentStop,
    leadStop,
    stopCall,
    Act (..),
    drive,
    driveOut,
    recorded,
    ready,
    reviewed,
    simplified,
    toImplement,
    refinePasses,
    gathered,
) where

import Data.Aeson (Value (..), encode, object, (.=))
import Data.Aeson.Types (Pair)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Entity.Event (EventRow (..))
import Data.Entity.Event qualified as Row
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Payload.Event (Decoded (..), decodeRow)
import Data.Payload.Upcast (shipped)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import Data.Time (UTCTime (..), fromGregorian)
import Data.Word (Word8)
import Doubles.Clock (runClockFixed)
import Doubles.Console (Streams (..), runConsoleCaptured)
import Doubles.Environment (runEnvironmentGiven)
import Doubles.FileSystem (Disk (..), runFileSystemInMemory)
import Doubles.Gh (printedPr, runGhScripted)
import Doubles.Git (Worktree (..), runGitMissing, runGitScripted)
import Doubles.Log (
    Access (..),
    Runs,
    editRows,
    noRuns,
    rowsOf,
    runLogInMemory,
    withAccess,
 )
import Doubles.Random (runRandomFixed)
import Effectful (Eff, runPureEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Effectful.State.Static.Local (runState)
import Effects.Store.Connection (OpenRefusal)
import State.Cli.Shell qualified as Shell
import State.Protocol.Advice (PrView (..), PullRequest (..), Readiness (..))
import State.Run.Codec (eventType)
import State.Run.Event (
    Branch (..),
    DraftPr (..),
    Envelope (..),
    Event (..),
    RunId,
    Sha (..),
    Start (..),
    Task (..),
    Url (..),
    runIdText,
 )
import State.Run.RunGen (breakdownJson, plainTask)
import System.Environment (getEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Hspec (expectationFailure)

{- | Everything outside the process. The worktree's commits on @feat@ are
counted: each changes one line, as the e2e's do.
-}
data World = World
    { env :: Map String String
    , disk :: Disk
    , runs :: Runs
    -- ^ The run store's runs, apart from the disk as the real store's are.
    , gitDir :: Either Text FilePath
    , others :: [FilePath]
    -- ^ The tops of other worktrees, apart from the one calls run in.
    , gitOnPath :: Bool
    -- ^ Without it every git call throws, as a missing binary's spawn does.
    , branch :: Maybe Branch
    , commits :: Int
    , pr :: PrView
    , clock :: UTCTime
    , entropy :: [Word8]
    }

-- | The world, holding the flows' step table the build exports as @STATE_STEPS@ (kernel/default.nix).
newWorld :: IO (IORef World)
newWorld = do
    steps <- BS.readFile =<< getEnv "STATE_STEPS"
    newIORef
        World
            { env = Map.fromList [("STATE_STEPS", stepsPath), ("HOME", "/home")]
            , disk =
                Disk
                    { files = Map.singleton stepsPath steps
                    , dirs = Set.fromList ["/", "/etc", "/work", "/work/.git"]
                    , cwd = "/work"
                    }
            , runs = noRuns
            , gitDir = Right "/work/.git"
            , others = []
            , gitOnPath = True
            , branch = Just (Branch "feat")
            , commits = 0
            , pr = PrViewFailed "no pull requests found for branch \"feat\"\n"
            , clock = UTCTime (fromGregorian 2026 11 13) 0
            , entropy = cycle [0 .. 255]
            }
  where
    stepsPath = "/etc/steps.json"

-- | One call: its exit code and its output, line by line.
data Ran = Ran {code :: Int, out :: [Text], err :: [Text]}

state :: IORef World -> [Text] -> IO Ran
state world = stateIn world ""

stateIn :: IORef World -> ByteString -> [Text] -> IO Ran
stateIn world input argv = run world input (Shell.main argv)

-- | One @state-hook <name>@ call, fed the hook event on stdin.
hook :: IORef World -> Text -> LBS.ByteString -> IO Ran
hook world name input = run world (LBS.toStrict input) (Shell.hook [name])

run ::
    IORef World ->
    ByteString ->
    (forall es. (Shell.Shell es) => Eff es ExitCode) ->
    IO Ran
run world input program = atomicModifyIORef' world $ \w ->
    let ((opened, disk), streams) =
            runPureEff
                . runClockFixed w.clock
                . runConsoleCaptured input
                . runEnvironmentGiven w.env
                . runState w.disk
                . runFileSystemInMemory
                . runGhScripted w.pr
                . (if w.gitOnPath then runGitScripted (worktreeOf w) else runGitMissing)
                . runErrorNoCallStack @OpenRefusal
                . runState w.runs
                . runLogInMemory shipped
                . runRandomFixed w.entropy
                $ program
        -- The double opens no file, so it refuses none.
        ((code, entropy), runs) = either (error . show) id opened
     in ( w {entropy, runs, disk}
        , Ran (exitNumber code) (Text.lines streams.stdout) (Text.lines streams.stderr)
        )
  where
    exitNumber = \case
        ExitSuccess -> 0
        ExitFailure n -> n

worktreeOf :: World -> Worktree
worktreeOf w =
    Worktree
        { gitDir = w.gitDir
        , head = Just (headOf w.commits)
        , branch = w.branch
        , numstats =
            [
                ( Branch "main"
                , if w.commits == 0 then "" else Text.pack (show w.commits) <> "\t0\tchange.txt\n"
                )
            ]
        , others = w.others
        }

-- | HEAD after this many commits on @feat@; 0 is @main@'s.
headOf :: Int -> Sha
headOf n = Sha (Text.justifyRight 40 '0' (Text.pack (show n)))

-- | The output of a call that must succeed.
succeeded :: Ran -> IO [Text]
succeeded ran
    | ran.code == 0 = pure ran.out
    | otherwise =
        []
            <$ expectationFailure
                ("exit " <> show ran.code <> ": " <> Text.unpack (Text.unlines ran.err))

-- | @init@ in the worktree's notes; the run's id.
startedRun :: IORef World -> IO Text
startedRun world = startedIn world []

-- | @init@ with these arguments, in the worktree's notes unless they name others; the run's id.
startedIn :: IORef World -> [Text] -> IO Text
startedIn world argv =
    ( succeeded
        =<< state
            world
            ( "init"
                : (if "--notes" `elem` argv then argv else "--notes" : Text.pack notes : argv)
            )
    )
        >>= \case
            [line, _] | Just runId <- Text.stripPrefix "started " line -> pure runId
            other -> fail ("not started: " <> show other)

notes :: FilePath
notes = "/notes"

-- | A file written outside @state@, as an agent writes the breakdown.
putFile :: IORef World -> FilePath -> Text -> IO ()
putFile world path content = modifyIORef' world $ \w ->
    let disk = w.disk
     in w {disk = disk {files = Map.insert path (encodeUtf8 content) disk.files}}

{- | A 10x run at its fan-out with tasks @t1@ and @t2@, @t2@ depending on
@t1@, @t2@ heavy; the run's id.
-}
tenXAtFanOut :: IORef World -> IO Text
tenXAtFanOut world =
    tenXAtFanOutOf world [plainTask "t1" [], (plainTask "t2" ["t1"]) {heavy = True}]

-- | A 10x run at its fan-out with these tasks; the run's id.
tenXAtFanOutOf :: IORef World -> [Task] -> IO Text
tenXAtFanOutOf world = tenXAtFanOutBy world []

-- | A 10x run started with these further init arguments, at its fan-out with these tasks; the run's id.
tenXAtFanOutBy :: IORef World -> [Text] -> [Task] -> IO Text
tenXAtFanOutBy world argv tasks = do
    tenX <- startedIn world (["--flow", "10x"] <> argv)
    putFile world (notes </> "tasks.json") (breakdownJson tasks)
    _ <-
        succeeded
            =<< state world ["override", "breakdown", "the", "plan", "is", "agreed"]
    _ <-
        succeeded
            =<< state
                world
                ["record", "breakdown.done", "--tasks", Text.pack (notes </> "tasks.json")]
    pure tenX

{- | The child run a parent's brief starts for this task, in the notes dir
given, in 'childWorktree', where later calls run; its id.
-}
childRun :: IORef World -> Text -> FilePath -> Text -> IO Text
childRun world parent dir task = do
    atWorktree world childWorktree
    startedIn world ["--notes", Text.pack dir, "--parent", parent, "--task", task]

-- | The worktree a child runs in, apart from the parent's at @/work@.
childWorktree :: FilePath
childWorktree = "/child-work"

-- | Later calls run in this worktree, on the disk from now on: its git dir is its top's @.git@.
atWorktree :: IORef World -> FilePath -> IO ()
atWorktree world top = modifyIORef' world $ \w ->
    let disk = w.disk
     in w
            { gitDir = Right (top </> ".git")
            , disk = disk {dirs = disk.dirs <> Set.fromList [top, top </> ".git"], cwd = top}
            }

-- | Another worktree at this top, its git dir its top's @.git@; calls run where they did.
addWorktree :: IORef World -> FilePath -> IO ()
addWorktree world top = modifyIORef' world $ \w ->
    let disk = w.disk
     in w
            { others = top : w.others
            , disk = disk {dirs = disk.dirs <> Set.fromList [top, top </> ".git"]}
            }

-- | The log of the worktree's notes' run as written, decoded row by row; it must read.
logged :: IORef World -> IO [Envelope]
logged world = loggedIn world notes

-- | The log of the run started in these notes as written, decoded row by row; it must read.
loggedIn :: IORef World -> FilePath -> IO [Envelope]
loggedIn world dir =
    either
        ( \(n, why) ->
            []
                <$ expectationFailure
                    ("the log's row " <> show n <> " does not read: " <> show why)
        )
        pure
        . traverse
            ( \(n, row) -> case decodeRow shipped row of
                Known e -> Right e
                other -> Left (n :: Int, other)
            )
        . zip [1 ..]
        =<< logRowsIn world dir

-- | The id of the worktree's notes' run.
runOf :: IORef World -> IO Text
runOf world =
    logged world >>= \case
        first : _ -> pure (runIdText first.run)
        [] -> "" <$ expectationFailure "no run logged"

loggedEvents :: IORef World -> IO [Text]
loggedEvents world = loggedEventsIn world notes

-- | The event types of the log of the run started in these notes.
loggedEventsIn :: IORef World -> FilePath -> IO [Text]
loggedEventsIn world dir = map (eventType . (.event)) <$> loggedIn world dir

prUrl :: Text
prUrl = "https://github.com/o/r/pull/1"

-- | What @gh pr view@ prints for the branch's PR into @main@.
draftPr :: Readiness -> PrView
draftPr = prOn "main"

-- | What @gh pr view@ prints for the branch's PR into this base.
prOn :: Text -> Readiness -> PrView
prOn base = printedPr . PullRequest (DraftPr (Url prUrl) (Branch base) (Branch "feat"))

-- | Edit the log of the worktree's notes' run by hand, row by row, as a store's rows are.
editLog :: IORef World -> ([EventRow] -> [EventRow]) -> IO ()
editLog world = editLogIn world notes

-- | Edit the log of the run started in these notes by hand, row by row.
editLogIn :: IORef World -> FilePath -> ([EventRow] -> [EventRow]) -> IO ()
editLogIn world dir edit = modifyIORef' world $ \w ->
    w
        { runs =
            maybe
                (withAccess Writable w.runs)
                (\found -> editRows found edit w.runs)
                (runIn w dir)
        }

{- | The rows and one more after them that this kernel does not read, as
another kernel could write it: an event type it does not know.
-}
appendUnread :: [EventRow] -> [EventRow]
appendUnread rows =
    rows
        <> [ lastRow {Row.seq = lastRow.seq + 1, Row.eventType = unknownType, payload = "{}"}
           | lastRow <- take 1 (reverse rows)
           ]

-- | The rows less those 'appendUnread' added.
lessUnread :: [EventRow] -> [EventRow]
lessUnread = filter ((/= unknownType) . (.eventType))

unknownType :: Text
unknownType = "no_such_event"

-- | The run's first row alone, of payload version 2, as a newer kernel could write it.
newerStart :: [EventRow] -> [EventRow]
newerStart rows = [row {Row.schemaVersion = 2} | row <- take 1 rows]

-- | The log of the worktree's notes' run as the rows the store holds.
logRows :: IORef World -> IO [EventRow]
logRows world = logRowsIn world notes

logRowsIn :: IORef World -> FilePath -> IO [EventRow]
logRowsIn world dir =
    ( \w ->
        maybe [] (\found -> fromMaybe [] (lookup found (rowsOf w.runs))) (runIn w dir)
    )
        <$> readIORef world

-- | The run whose first row starts it in these notes.
runIn :: World -> FilePath -> Maybe RunId
runIn w dir =
    listToMaybe
        [ found
        | (found, first : _) <- rowsOf w.runs
        , Known Envelope {event = Started start} <- [decodeRow shipped first]
        , start.notes == dir
        ]

-- | The run store takes no write from now on, as on a disk failure; it still reads.
storeDown :: IORef World -> IO ()
storeDown world = modifyIORef' world (\w -> w {runs = withAccess ReadOnly w.runs})

-- | A file's bytes as written, if it exists.
fileBytes :: IORef World -> FilePath -> IO (Maybe ByteString)
fileBytes world path = Map.lookup path . (.disk.files) <$> readIORef world

-- | The neutral hook event of the lead's (a @Null@ agent) or a subagent's session in the worktree.
hookEvent :: Value -> [Pair] -> LBS.ByteString
hookEvent = hookEventIn "/work"

hookEventIn :: FilePath -> Value -> [Pair] -> LBS.ByteString
hookEventIn cwd agent fields =
    encode
        (object (["session" .= String "s1", "cwd" .= cwd, "agent" .= agent] <> fields))

sessionStart :: LBS.ByteString
sessionStart = sessionStartIn "/work"

-- | The lead's session starting in this directory.
sessionStartIn :: FilePath -> LBS.ByteString
sessionStartIn cwd =
    hookEventIn
        cwd
        Null
        ["event" .= String "sessionStart", "source" .= String "startup"]

-- | A subagent of this role hands back @READY@.
handedBack :: Text -> LBS.ByteString
handedBack role =
    hookEvent
        (object ["id" .= String "a1", "role" .= role])
        [ "event" .= String "beforeTool"
        , "tool" .= String "handback"
        , "input" .= object ["message" .= String "READY\nDone.\n"]
        , "history" .= ([] :: [Text])
        ]

-- | The lead spawns a subagent of this role.
spawned :: Text -> LBS.ByteString
spawned role =
    hookEvent
        Null
        [ "event" .= String "beforeTool"
        , "tool" .= String "delegate"
        , "input" .= object ["subagent_type" .= role]
        , "history" .= ([] :: [Text])
        ]

-- | A subagent @a1@ of this role starting in the worktree.
agentStarted :: Text -> LBS.ByteString
agentStarted role =
    hookEvent
        (object ["id" .= String "a1", "role" .= role])
        ["event" .= String "agentStart"]

-- | The lead about to edit a file in the worktree.
editCall :: LBS.ByteString
editCall =
    hookEvent
        Null
        [ "event" .= String "beforeTool"
        , "tool" .= String "edit"
        , "input" .= object ["file_path" .= String "/work/a.hs"]
        , "history" .= ([] :: [Text])
        ]

-- | The lead about to run this shell command in the worktree.
stateCall :: Text -> LBS.ByteString
stateCall command =
    hookEvent
        Null
        [ "event" .= String "beforeTool"
        , "tool" .= String "shell"
        , "input" .= object ["command" .= command]
        , "history" .= ([] :: [Text])
        ]

-- | The lead's spawn of a subagent @a1@ of this role, done: its result names the agent.
spawnResult :: Text -> LBS.ByteString
spawnResult role = spawnResultOf role "a1"

-- | The lead's spawn of a subagent of this role and id, done.
spawnResultOf :: Text -> Text -> LBS.ByteString
spawnResultOf = spawnResultFrom Null

-- | A subagent of this role and id spawning one of that role and id, done.
spawnResultBy :: Text -> Text -> Text -> Text -> LBS.ByteString
spawnResultBy spawnerRole spawner = spawnResultFrom (object ["id" .= spawner, "role" .= spawnerRole])

spawnResultFrom :: Value -> Text -> Text -> LBS.ByteString
spawnResultFrom spawner role agent =
    hookEvent
        spawner
        [ "event" .= String "afterTool"
        , "tool" .= String "delegate"
        , "input" .= object ["subagent_type" .= role]
        , "output"
            .= object
                ["status" .= String "completed", "agentId" .= String agent, "agentType" .= role]
        , "context" .= Null
        ]

-- | A subagent of this role and id ran @state init@, which printed this.
initRan :: Text -> Text -> Text -> LBS.ByteString
initRan role agent stdout =
    hookEvent
        (object ["id" .= agent, "role" .= role])
        [ "event" .= String "afterTool"
        , "tool" .= String "shell"
        , "input" .= object ["command" .= String "state init"]
        , "output" .= object ["stdout" .= stdout, "stderr" .= String ""]
        , "context" .= Null
        ]

-- | A subagent of this role and id stops, these agents running in the session.
agentStop :: Text -> Text -> [Text] -> LBS.ByteString
agentStop role agent = stopOf (object ["id" .= agent, "role" .= role])

-- | The lead stops, these agents running in the session.
leadStop :: [Text] -> LBS.ByteString
leadStop = stopOf Null

stopOf :: Value -> [Text] -> LBS.ByteString
stopOf agent running = hookEvent agent ["event" .= String "agentStop", "running" .= running]

-- | The lead's call stopping the agent of this id, done.
stopCall :: Text -> LBS.ByteString
stopCall agent =
    hookEvent
        Null
        [ "event" .= String "afterTool"
        , "tool" .= String "stopAgent"
        , "input" .= object ["task_id" .= agent]
        , "output" .= object ["message" .= String "stopped"]
        , "context" .= Null
        ]

-- | What a scenario does between two @state next@ calls.
data Act
    = Record [Text]
    | -- | A role's hand-back on stdin, given the worktree's HEAD.
      Handback Text (Text -> Text)
    | -- | A commit of one changed line.
      Commit
    | -- | The draft PR GitHub reports from now on: @next@ records @draft.done@ from it.
      OpenPr
    | Override Text
    | -- | The lead writes its plan to the notes dir and records @plan.done@.
      Planned

{- | Starts the run, then each act and a @state next@ after it, every call
exiting 0. The @recorded@ lines they print, without their sequence numbers.
-}
drive :: IORef World -> [Act] -> IO [Text]
drive world acts = recorded . concat <$> driveOut world acts

-- | As 'drive', each call's whole output: the first @next@'s, then each act's with its @next@.
driveOut :: IORef World -> [Act] -> IO [[Text]]
driveOut world acts = do
    _ <- startedRun world
    first <- next
    rest <- traverse (\act -> (<>) <$> perform act <*> next) acts
    pure (first : rest)
  where
    next = succeeded =<< state world ["next"]
    perform = \case
        Record argv -> succeeded =<< state world ("record" : argv)
        Handback role report -> do
            Sha sha <- headOf . (.commits) <$> readIORef world
            succeeded =<< stateIn world (encodeUtf8 (report sha)) ["handback", role]
        Commit -> [] <$ modifyIORef' world (\w -> w {commits = w.commits + 1})
        OpenPr -> [] <$ modifyIORef' world (\w -> w {pr = draftPr IsDraft})
        Override to -> succeeded =<< state world ["override", to, "the", "test", "starts", "here"]
        Planned -> do
            putFile world plan "the plan"
            succeeded =<< state world ["record", "plan.done", Text.pack plan]
    plan = notes </> "plan.md"

-- | The @recorded <seq> <event> -> <state>@ lines of an output, without their sequence numbers.
recorded :: [Text] -> [Text]
recorded = concatMap $ \line -> case Text.words line of
    ["recorded", _, event, "->", at] -> [event <> " -> " <> at]
    _ -> []

ready, reviewed, simplified :: Text -> Text
ready _ = "READY\nDone.\n"
reviewed sha = "| # | Finding |\n|---|---|\nReviewed head: " <> sha <> "\n"
simplified sha = "READY\nSimplified: " <> sha <> "\n"

-- | From the start to the draft PR and a first commit on it.
toImplement :: [Act]
toImplement =
    [ Record ["gather.research"]
    , Record ["gather/research.spawned"]
    , Handback "researcher" ready
    ]
        <> gathered
        <> [Planned]
        <> refinePasses
        <> [ Record ["confirm.confirmed"]
           , OpenPr
           , Commit
           , Handback "implementer" ready
           ]

-- | Each refine pass hands back, then the lead presents the plan: from @plan@'s done to @confirm@.
refinePasses :: [Act]
refinePasses =
    [ Handback "researcher" ready
    , Handback "researcher" ready
    , Handback "reviewer" ready
    , Record ["present.done"]
    ]

-- | The gather ended with no researcher open: its await goes on by itself to the notes.
gathered :: [Act]
gathered = [Record ["gather.enough"], Record ["gather/notes.done"]]
