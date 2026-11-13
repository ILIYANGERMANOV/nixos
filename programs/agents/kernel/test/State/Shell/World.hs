{- | The world @state@ and @state-hook@ run in, made of the test doubles: a
worktree on branch @feat@ at @/work@ whose base @main@ is on origin, its
notes dir @/notes@, and a GitHub with no PR for the branch yet. Each call is
one process: it runs a shell program in the world and leaves it changed, as
the e2e specs' calls do a temp repo.
-}
module State.Shell.World (
    World (..),
    Ran (..),
    newWorld,
    state,
    stateIn,
    hook,
    succeeded,
    startedRun,
    putFile,
    tenXAtFanOut,
    childRun,
    logged,
    loggedEvents,
    headOf,
    draftPr,
    prOn,
    editLog,
    logBytes,
    prUrl,
    notes,
    eventsPath,
    sessionStart,
    sessionStartIn,
    handedBack,
    askedUser,
    spawned,
    Act (..),
    drive,
    recorded,
    ready,
    reviewed,
    simplified,
    toImplement,
) where

import Data.Aeson (Value (..), encode, object, (.=))
import Data.Aeson.Types (Pair)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (for_)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
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
import Doubles.Git (Worktree (..), runGitScripted)
import Doubles.Log (runLogInMemory)
import Doubles.Random (runRandomFixed)
import Effectful (Eff, runPureEff)
import Effectful.State.Static.Local (runState)
import State.Advice (PrView (..), PullRequest (..), Readiness (..))
import State.Codec (LogError (..), decodeLogBytes, eventType, logOf)
import State.Event (Branch (..), DraftPr (..), Envelope (..), Sha (..), Task (..), Url (..))
import State.RunGen (breakdownJson, plainTask)
import State.Shell qualified as Shell
import System.Environment (getEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Hspec (expectationFailure, shouldBe)

{- | Everything outside the process. The worktree's commits on @feat@ are
counted: each changes one line, as the e2e's do.
-}
data World = World
    { env :: Map String String
    , disk :: Disk
    , gitDir :: Either Text FilePath
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
            { env = Map.fromList [("STATE_STEPS", stepsPath)]
            , disk = Disk {files = Map.singleton stepsPath steps, dirs = Set.fromList ["/", "/etc", "/work", "/work/.git"], cwd = "/work"}
            , gitDir = Right "/work/.git"
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

run :: IORef World -> ByteString -> (forall es. (Shell.Shell es) => Eff es ExitCode) -> IO Ran
run world input program = atomicModifyIORef' world $ \w ->
    let (((code, entropy), disk), streams) =
            runPureEff
                . runClockFixed w.clock
                . runConsoleCaptured input
                . runEnvironmentGiven w.env
                . runState w.disk
                . runFileSystemInMemory
                . runGhScripted w.pr
                . runGitScripted (worktreeOf w)
                . runLogInMemory
                . runRandomFixed w.entropy
                $ program
     in (w {entropy, disk}, Ran (exitNumber code) (Text.lines streams.stdout) (Text.lines streams.stderr))
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
        , numstats = [(Branch "main", if w.commits == 0 then "" else Text.pack (show w.commits) <> "\t0\tchange.txt\n")]
        }

-- | HEAD after this many commits on @feat@; 0 is @main@'s.
headOf :: Int -> Sha
headOf n = Sha (Text.justifyRight 40 '0' (Text.pack (show n)))

-- | The output of a call that must succeed.
succeeded :: Ran -> IO [Text]
succeeded ran
    | ran.code == 0 = pure ran.out
    | otherwise = [] <$ expectationFailure ("exit " <> show ran.code <> ": " <> Text.unpack (Text.unlines ran.err))

-- | @init@ in the worktree's notes; the run's id.
startedRun :: IORef World -> IO Text
startedRun world = startedIn world []

-- | @init@ with these arguments, in the worktree's notes unless they name others; the run's id.
startedIn :: IORef World -> [Text] -> IO Text
startedIn world argv =
    (succeeded =<< state world ("init" : (if "--notes" `elem` argv then argv else "--notes" : Text.pack notes : argv))) >>= \case
        [line] | Just runId <- Text.stripPrefix "started " line -> pure runId
        other -> fail ("not started: " <> show other)

notes :: FilePath
notes = "/notes"

-- | A file written outside @state@, as an agent writes the breakdown.
putFile :: IORef World -> FilePath -> Text -> IO ()
putFile world path content = modifyIORef' world $ \w ->
    let disk = w.disk in w {disk = disk {files = Map.insert path (encodeUtf8 content) disk.files}}

{- | A 10x run at its fan-out with tasks @t1@ and @t2@, @t2@ depending on
@t1@, @t2@ heavy; the run's id.
-}
tenXAtFanOut :: IORef World -> IO Text
tenXAtFanOut world = do
    tenX <- startedIn world ["--flow", "10x"]
    putFile world (notes </> "tasks.json") (breakdownJson [plainTask "t1" [], (plainTask "t2" ["t1"]) {heavy = True}])
    for_ [["quality", "Balanced"], ["size", "Normal"]] $ \argv -> succeeded =<< state world ("record" : argv)
    _ <- succeeded =<< state world ["override", "breakdown", "the", "plan", "is", "agreed"]
    _ <- succeeded =<< state world ["record", "breakdown.done", "--tasks", Text.pack (notes </> "tasks.json")]
    pure tenX

-- | The child run a parent's brief starts for this task, in the notes dir given; its id.
childRun :: IORef World -> Text -> FilePath -> Text -> IO Text
childRun world parent dir task = startedIn world ["--notes", Text.pack dir, "--parent", parent, "--parent-log", Text.pack eventsPath, "--task", task]

eventsPath :: FilePath
eventsPath = logOf notes

-- | The worktree's log as written, decoded line by line; it must read.
logged :: IORef World -> IO [Envelope]
logged world = do
    w <- readIORef world
    case decodeLogBytes (Map.findWithDefault "" eventsPath w.disk.files) of
        Right lines' -> pure lines'
        Left bad -> [] <$ expectationFailure ("the log does not read: " <> show bad.line)

loggedEvents :: IORef World -> IO [Text]
loggedEvents world = map (eventType . (.event)) <$> logged world

prUrl :: Text
prUrl = "https://github.com/o/r/pull/1"

-- | What @gh pr view@ prints for the branch's PR into @main@.
draftPr :: Readiness -> PrView
draftPr = prOn "main"

-- | What @gh pr view@ prints for the branch's PR into this base.
prOn :: Text -> Readiness -> PrView
prOn base = printedPr . PullRequest (DraftPr (Url prUrl) (Branch base) (Branch "feat"))

-- | Edit the worktree's log by hand, as the bytes on disk.
editLog :: IORef World -> (ByteString -> ByteString) -> IO ()
editLog world edit = modifyIORef' world $ \w ->
    let disk = w.disk in w {disk = disk {files = Map.alter (Just . edit . fromMaybe "") eventsPath disk.files}}

-- | The worktree's log as the bytes on disk.
logBytes :: IORef World -> IO (Maybe ByteString)
logBytes world = Map.lookup eventsPath . (.disk.files) <$> readIORef world

-- | The neutral hook event of the lead's (a @Null@ agent) or a subagent's session in the worktree.
hookEvent :: Value -> [Pair] -> LBS.ByteString
hookEvent = hookEventIn "/work"

hookEventIn :: FilePath -> Value -> [Pair] -> LBS.ByteString
hookEventIn cwd agent fields = encode (object (["session" .= String "s1", "cwd" .= cwd, "agent" .= agent] <> fields))

sessionStart :: LBS.ByteString
sessionStart = sessionStartIn "/work"

-- | The lead's session starting in this directory.
sessionStartIn :: FilePath -> LBS.ByteString
sessionStartIn cwd = hookEventIn cwd Null ["event" .= String "sessionStart", "source" .= String "startup"]

-- | A subagent of this role hands back @READY@.
handedBack :: Text -> LBS.ByteString
handedBack role =
    hookEvent
        (object ["id" .= String "a1", "role" .= role])
        ["event" .= String "beforeTool", "tool" .= String "handback", "input" .= object ["message" .= String "READY\nDone.\n"], "history" .= ([] :: [Text])]

askedUser :: LBS.ByteString
askedUser = hookEvent Null ["event" .= String "afterTool", "tool" .= String "ask", "input" .= object [], "output" .= String "ok", "context" .= Null]

-- | The lead spawns a subagent of this role.
spawned :: Text -> LBS.ByteString
spawned role = hookEvent Null ["event" .= String "beforeTool", "tool" .= String "delegate", "input" .= object ["subagent_type" .= role], "history" .= ([] :: [Text])]

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
    | -- | A @record@ the run refuses, with exit 2.
      Refused [Text]

{- | Starts the run, then each act and a @state next@ after it, every call
exiting 0. The @recorded@ lines they print, without their sequence numbers.
-}
drive :: IORef World -> [Act] -> IO [Text]
drive world acts = do
    _ <- startedRun world
    first <- next
    rest <- traverse (\act -> (<>) <$> perform act <*> next) acts
    pure (recorded (concat (first : rest)))
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
        Refused argv -> do
            ran <- state world ("record" : argv)
            [] <$ (ran.code `shouldBe` 2)

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
    [ Record ["research.done", "2"]
    , Record ["interview.enough"]
    , Record ["plan.done", Text.pack (notes </> "plan.md")]
    , Handback "researcher" ready
    , Handback "researcher" ready
    , Record ["confirm.confirmed"]
    , OpenPr
    , Commit
    , Handback "implementer" ready
    ]
