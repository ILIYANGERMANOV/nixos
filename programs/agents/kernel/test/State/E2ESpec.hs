{- | The e2e scenarios of #360 on the built @state@ binary (@$STATE_BIN@): each
runs in a temp worktree on branch @feat@, whose base @main@ is pushed to a bare
origin, with a scripted @gh@ first on PATH. Scenario 6 drives @state-hook@,
slice C's.
-}
module State.E2ESpec (spec) where

import Control.Monad (void)
import Data.Aeson (Value (..), encode, object, (.=))
import Data.Aeson.Types (Pair)
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.Foldable (for_)
import Data.List (isSuffixOf)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import System.Directory (createDirectory, findExecutable, getPermissions, setOwnerExecutable, setPermissions)
import System.Environment (getEnv, getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import Test.Hspec (Spec, around, describe, expectationFailure, it, runIO, shouldBe, shouldContain, shouldSatisfy)

spec :: Spec
spec = describe "the state binary" $ do
    bin <- runIO (getEnv "STATE_BIN")
    hookBin <- runIO (getEnv "STATE_HOOK_BIN")
    around withRepo $ do
        it "runs the engineer flow at Balanced Normal from init to ready" $ \repo -> do
            transcript <- drive bin repo (balancedPath repo)
            transcript `shouldBe` balancedTranscript
            done <- succeeded =<< state bin repo ["next"]
            take 4 done
                `shouldBe` ["DONE " <> prUrl, "  mode: Balanced Normal", "  changed lines: 1", "  PR: " <> prUrl <> " (draft)"]

        it "logs the steps POC Trivial skips, reviews once and skips ready" $ \repo -> do
            transcript <- drive bin repo (trivialPath repo)
            transcript `shouldBe` trivialTranscript
            done <- succeeded =<< state bin repo ["next"]
            take 1 done `shouldBe` ["DONE " <> prUrl]

        it "refuses an event with no arrow: exit 2, a fix line, and next warns" $ \repo -> do
            _ <- drive bin repo [Record ["quality", "Balanced"], Record ["size", "Normal"]]
            refused <- state bin repo ["record", "ready.done", prUrlString]
            (refused.code, refused.err)
                `shouldBe` (2, ["state record: ready.done - no such arrow out of research", "fix: state record research.done <n>"])
            warned <- succeeded =<< state bin repo ["next"]
            take 3 warned
                `shouldBe` ["SPAWN researcher background: yes", "refused: ready.done - no such arrow out of research", "fix: state record research.done <n>"]
            _ <- succeeded =<< state bin repo ["record", "research.done", "2"]
            moved <- succeeded =<< state bin repo ["next"]
            moved `shouldSatisfy` (not . mentions "refused:")

        it "prints each record it advises with its arguments" $ \repo -> do
            _ <- drive bin repo [Record ["quality", "Balanced"], Record ["size", "Normal"], Record ["research.done", "2"], Record ["interview.enough"]]
            advice <- succeeded =<< state bin repo ["next"]
            take 1 advice `shouldBe` ["RUN state record plan.done <path>"]

        it "starts a run once per notes dir, and refuses one there after it stopped" $ \repo -> do
            run <- startedRun bin repo
            again <- startedRun bin repo
            again `shouldBe` run
            _ <- succeeded =<< state bin repo ["stop", "replan", "the", "plan", "is", "wrong"]
            refused <- state bin repo ["init", "--notes", repo.notes]
            (refused.code, drop 1 refused.err) `shouldBe` (2, ["fix: state init --notes <a new dir>"])

        it "fixes a refused event by the arrows this mode takes, never a skip it refuses" $ \repo -> do
            _ <- drive bin repo (toSimplifyPr repo)
            refused <- state bin repo ["record", "await_ci.green"]
            (refused.code, refused.err)
                `shouldBe` (2, ["state record: await_ci.green - no such arrow out of simplify_pr", "fix: state record simplify_pr.done"])

        it "overrides to a named state" $ \repo -> do
            _ <- drive bin repo []
            moved <- succeeded =<< state bin repo ["override", "review", "resume", "after", "a", "crash"]
            moved `shouldBe` ["recorded 2 overridden -> review"]
            shown <- succeeded =<< state bin repo ["show"]
            shown `shouldContain` ["step: review"]

        it "refuses an override to an unknown state, listing the states" $ \repo -> do
            _ <- drive bin repo []
            refused <- state bin repo ["override", "nowhere", "why"]
            (refused.code, refused.err)
                `shouldBe` ( 2
                           ,
                               [ "state override: override to nowhere - the flow has no single state of that name"
                               , "fix: state override <research|interview|plan|simplify_plan|alternative|confirm|draft|implement|refactor|review|pick|fix|describe|simplify_pr|await_ci|fix_pr|ready> <why>"
                               ]
                           )

        it "names a hand-edited bad line and appends nothing after it" $ \repo -> do
            _ <- drive bin repo []
            appendFile (eventsOf repo) "{\"v\":3,broken\n"
            before <- readFile (eventsOf repo)
            let events = Text.pack (eventsOf repo)
            for_ [("next", []), ("show", []), ("record", ["quality", "Max"])] $ \(sub, args) -> do
                bad <- state bin repo (sub : args)
                (bad.code, map (fst . Text.breakOn " - ") bad.err)
                    `shouldBe` (2, ["state " <> Text.pack sub <> ": " <> events <> " line 2 is not read", "fix: repair or move " <> events])
            after <- readFile (eventsOf repo)
            after `shouldBe` before

        describe "the review loop" $ do
            it "asks Stuck when rounds 1 and 2 pick the same row" $ \repo -> do
                _ <- drive bin repo (atReview <> reviewRound "R1" [] <> [Handback "fixer" ready] <> reviewRound "R1" [])
                advice <- succeeded =<< state bin repo ["next"]
                take 1 advice `shouldBe` ["ASK Stuck the review loop repeats R1: go on, change course, or stop?"]

            it "gives a Not met at the fuel one more round, then exits" $ \repo -> do
                let rounds = concat [reviewRound label [] <> [Handback "fixer" ready] | label <- ["R1", "R2", "R3"]]
                    notMet = ["--verdict", "docs=not-met"]
                _ <- drive bin repo (atReview <> rounds <> reviewRound "R4" notMet <> [Handback "fixer" ready] <> [Handback "review-lead" reviewed])
                advice <- succeeded =<< state bin repo ["next"]
                take 1 advice `shouldSatisfy` all ("- no review round is left" `Text.isSuffixOf`)
                refused <- state bin repo ["record", "pick.loop", "--row", "R5", "--verdict", "docs=not-met"]
                (refused.code, refused.err)
                    `shouldBe` (2, ["state record: another review round - the loop ran its 4 rounds", "fix: state record pick.final [--row <label>]... [--verdict <requirement>=<met|not-met|unverified>]... | state stop fuel <why>"])
                exited <- succeeded =<< state bin repo ["record", "pick.final"]
                recorded exited `shouldBe` ["pick.final -> describe"]

        describe "audit" $ do
            it "puts every ruling of a child run in show and in its hand-back" $ \repo -> do
                parent <- tenXAtFanOut bin repo
                git repo ["checkout", "-q", "-b", "child"]
                child <- childRun bin repo parent "child" "t1"
                [asked, _] <- succeeded =<< state bin repo ["ask", "--kind", "Pick", "which", "lib?"]
                let qid = Text.unpack (Text.drop (Text.length "asked ") asked)
                    ruling = "Ruling " <> Text.pack qid <> " Pick: zod - already used - none"
                _ <- succeeded =<< state bin repo ["rule", qid, "--answer", "zod", "--why", "already used", "--cost", "none"]
                shown <- succeeded =<< state bin repo ["show"]
                shown `shouldContain` ["rulings:", "  " <> ruling]
                forwarded <- succeeded =<< state bin repo ["ask", "--kind", "Design", "which", "store?"]
                forwarded `shouldContain` [ruling]
                stopped <- succeeded =<< state bin repo ["stop", "failed", "no", "access"]
                stopped `shouldBe` ["stopped", "HANDBACK FAILED no access", "Run: " <> child, ruling]

        describe "brief" $ do
            it "gives a refactorer its step's entry and the stop rule" $ \repo -> do
                _ <- drive bin repo []
                stopRule <- succeeded =<< state bin repo ["render", "stop-rule"]
                brief <- succeeded =<< state bin repo ["brief", "refactorer"]
                take 1 brief `shouldBe` ["## refactor"]
                brief `shouldSatisfy` (stopRule `isSuffixOf`)

            it "gives a fixer only the step the run is at, and a worker no command of the lead's" $ \repo -> do
                _ <- drive bin repo (atReview <> [Commit, Handback "review-lead" reviewed, Record ["pick.loop", "--row", "R1"]])
                fixer <- succeeded =<< state bin repo ["brief", "fixer"]
                filter ("## " `Text.isPrefixOf`) fixer `shouldBe` ["## fix"]
                for_ ["researcher", "implementer", "refactorer", "fixer"] $ \role -> do
                    brief <- succeeded =<< state bin repo ["brief", role]
                    brief `shouldSatisfy` (not . any (\line -> any (`Text.isInfixOf` line) ["state record", "state brief"]))

            it "gives a review-lead the plan-wrong line, not the stop rule" $ \repo -> do
                _ <- drive bin repo []
                planWrong <- succeeded =<< state bin repo ["render", "plan-wrong"]
                stopRule <- succeeded =<< state bin repo ["render", "stop-rule"]
                brief <- succeeded =<< state bin repo ["brief", "review-lead"]
                brief `shouldSatisfy` (planWrong `isSuffixOf`)
                brief `shouldSatisfy` (not . any (`elem` stopRule))

            it "ends an engineer's brief with the line that starts its run under this one" $ \repo -> do
                run <- tenXAtFanOut bin repo
                brief <- succeeded =<< state bin repo ["brief", "engineer", "--task", "t1"]
                drop 1 (dropWhile (/= "") brief) `shouldBe` ["state init --notes <dir> --parent " <> run <> " --parent-log " <> Text.pack (eventsOf repo) <> " --task t1"]

        describe "the hooks" $ do
            it "are silent in a worktree with no run" $ \repo -> do
                said <- hook hookBin repo "resume" (sessionStart repo)
                (said.code, said.out) `shouldBe` (0, [])

            it "tell a resumed session where its run stands" $ \repo -> do
                _ <- drive bin repo []
                said <- succeeded =<< hook hookBin repo "resume" (sessionStart repo)
                said `shouldSatisfy` mentions "step: research"

            it "record a hand-back seen twice once, appending what they recorded" $ \repo -> do
                _ <- drive bin repo (init (toImplement repo))
                before <- logLines repo
                first <- succeeded =<< hook hookBin repo "handback" (handedBack repo "implementer")
                once <- logLines repo
                again <- succeeded =<< hook hookBin repo "handback" (handedBack repo "implementer")
                twice <- logLines repo
                first `shouldSatisfy` mentions "state: recorded"
                once `shouldSatisfy` (> before)
                (again, twice) `shouldBe` ([], once)

            it "are silent off the branch the draft PR bound the run to" $ \repo -> do
                _ <- drive bin repo (init (toImplement repo))
                git repo ["checkout", "-q", "-b", "other"]
                said <- succeeded =<< hook hookBin repo "resume" (sessionStart repo)
                said `shouldBe` []

            it "are silent once the drafted PR is merged or closed" $ \repo -> do
                _ <- drive bin repo (init (toImplement repo))
                before <- logLines repo
                for_ ["MERGED", "CLOSED"] $ \over -> do
                    writeFile repo.prJson (pullRequest False over)
                    resumed <- succeeded =<< hook hookBin repo "resume" (sessionStart repo)
                    handed <- succeeded =<< hook hookBin repo "handback" (handedBack repo "implementer")
                    (resumed, handed) `shouldBe` ([], [])
                after <- logLines repo
                after `shouldBe` before

            it "are silent on a log they do not read" $ \repo -> do
                _ <- startedRun bin repo
                writeFile (eventsOf repo) "{\"seq\":0,\"ts\":\"t\",\"head\":null,\"session\":null,\"event\":{\"type\":\"started\",\"notes\":\"n\",\"version\":2}}\n"
                said <- succeeded =<< hook hookBin repo "resume" (sessionStart repo)
                said `shouldBe` []

            it "tell a log line they do not read, as context" $ \repo -> do
                _ <- drive bin repo []
                appendFile (eventsOf repo) "{\"v\":3,broken\n"
                said <- succeeded =<< hook hookBin repo "resume" (sessionStart repo)
                said `shouldSatisfy` mentions "line 2 is not read"

            it "exit 2 on stdin that is no hook event" $ \repo -> do
                said <- hook hookBin repo "resume" "not json"
                said.code `shouldBe` 2

            it "tell the lead how to record the answer to a question put to the user" $ \repo -> do
                _ <- drive bin repo []
                [asked, _] <- succeeded =<< state bin repo ["ask", "--kind", "Design", "which", "store?"]
                let qid = Text.drop (Text.length "asked ") asked
                said <- succeeded =<< hook hookBin repo "asked" (askedUser repo)
                said `shouldSatisfy` mentions ("state answer " <> qid <> " <answer>")

-- | One call of the binary: its exit code and its output, line by line.
data Ran = Ran {code :: Int, out :: [Text], err :: [Text]}

state :: FilePath -> Repo -> [String] -> IO Ran
state bin repo = stateIn bin repo ""

stateIn :: FilePath -> Repo -> String -> [String] -> IO Ran
stateIn bin repo stdin argv = do
    (exit, out, err) <- readCreateProcessWithExitCode (proc bin argv) {cwd = Just repo.work, env = Just repo.env} stdin
    let code = case exit of
            ExitSuccess -> 0
            ExitFailure n -> n
    pure (Ran code (Text.lines (Text.pack out)) (Text.lines (Text.pack err)))

-- | One @state-hook <name>@ call, fed the hook event on stdin.
hook :: FilePath -> Repo -> String -> String -> IO Ran
hook bin repo name stdin = stateIn bin repo stdin [name]

sessionStart :: Repo -> String
sessionStart repo = hookEvent repo Null ["event" .= String "sessionStart", "source" .= String "startup"]

-- | A subagent of this role hands back @READY@.
handedBack :: Repo -> Text -> String
handedBack repo role =
    hookEvent
        repo
        (object ["id" .= String "a1", "role" .= role])
        ["event" .= String "beforeTool", "tool" .= String "handback", "input" .= object ["message" .= String "READY\nDone.\n"], "history" .= ([] :: [Text])]

askedUser :: Repo -> String
askedUser repo = hookEvent repo Null ["event" .= String "afterTool", "tool" .= String "ask", "input" .= object [], "output" .= String "ok", "context" .= Null]

-- | The neutral hook event of the lead's (a @Null@ agent) or a subagent's session in the worktree.
hookEvent :: Repo -> Value -> [Pair] -> String
hookEvent repo agent fields = LBS8.unpack (encode (object (["session" .= String "s1", "cwd" .= repo.work, "agent" .= agent] <> fields)))

mentions :: Text -> [Text] -> Bool
mentions needle = any (needle `Text.isInfixOf`)

logLines :: Repo -> IO Int
logLines repo = length . Text.lines <$> Text.readFile (eventsOf repo)

-- | The output of a call that must succeed.
succeeded :: Ran -> IO [Text]
succeeded ran
    | ran.code == 0 = pure ran.out
    | otherwise = [] <$ expectationFailure ("exit " <> show ran.code <> ": " <> Text.unpack (Text.unlines ran.err))

-- | @init@ in the worktree's notes; the run's id.
startedRun :: FilePath -> Repo -> IO Text
startedRun bin repo =
    (succeeded =<< state bin repo ["init", "--notes", repo.notes]) >>= \case
        [line] | Just run <- Text.stripPrefix "started " line -> pure run
        other -> fail ("not started: " <> show other)

{- | A 10x run at its fan-out with tasks @t1@ and @t2@, @t2@ depending on
@t1@; the run's id.
-}
tenXAtFanOut :: FilePath -> Repo -> IO Text
tenXAtFanOut bin repo = do
    run <-
        (succeeded =<< state bin repo ["init", "--notes", repo.notes, "--flow", "10x"]) >>= \case
            [line] | Just run <- Text.stripPrefix "started " line -> pure run
            other -> fail ("not started: " <> show other)
    let tasks = repo.root </> "tasks.json"
    Text.writeFile tasks ("[" <> task "t1" "[]" <> "," <> task "t2" "[\"t1\"]" <> "]")
    for_ [["record", "quality", "Balanced"], ["record", "size", "Normal"], ["override", "breakdown", "the", "plan", "is", "agreed"], ["record", "breakdown.done", "--tasks", tasks]] $ \argv ->
        succeeded =<< state bin repo argv
    pure run
  where
    task name deps =
        "{\"id\":\"" <> name <> "\",\"deps\":" <> deps <> ",\"base\":\"main\",\"branch\":\"" <> name
            <> "\",\"quality\":\"Balanced\",\"size\":\"Normal\",\"qa\":false,\"heavy\":false,\"security\":[]}"

-- | The child run a parent's brief starts for this task, its notes in @dir@ under the repo's root; its id.
childRun :: FilePath -> Repo -> Text -> FilePath -> Text -> IO Text
childRun bin repo parent dir task =
    (succeeded =<< state bin repo ["init", "--notes", repo.root </> dir, "--parent", Text.unpack parent, "--parent-log", eventsOf repo, "--task", Text.unpack task]) >>= \case
        [line] | Just run <- Text.stripPrefix "started " line -> pure run
        other -> fail ("not started: " <> show other)

-- | What a scenario does between two @state next@ calls.
data Act
    = Record [String]
    | -- | A role's hand-back on stdin, given the worktree's HEAD.
      Handback String (Text -> Text)
    | -- | A commit of one changed line.
      Commit
    | -- | The draft PR the scripted @gh@ reports from now on: @next@ records @draft.done@ from it.
      OpenPr
    | Override String
    | -- | A @record@ the run refuses, with exit 2.
      Refused [String]

{- | Starts the run, then each act and a @state next@ after it, every call
exiting 0. The @recorded@ lines they print, without their sequence numbers:
the run's path, the steps @next@ records itself included.
-}
drive :: FilePath -> Repo -> [Act] -> IO [Text]
drive bin repo acts = do
    _ <- startedRun bin repo
    first <- next
    rest <- traverse (\act -> (<>) <$> perform act <*> next) acts
    pure (recorded (concat (first : rest)))
  where
    next = succeeded =<< state bin repo ["next"]
    perform = \case
        Record argv -> succeeded =<< state bin repo ("record" : argv)
        Handback role report -> do
            sha <- Text.strip . Text.pack <$> gitOut repo ["rev-parse", "HEAD"]
            succeeded =<< stateIn bin repo (Text.unpack (report sha)) ["handback", role]
        Commit -> [] <$ commitLine repo
        OpenPr -> [] <$ writeFile repo.prJson (pullRequest True "OPEN")
        Override to -> succeeded =<< state bin repo ["override", to, "the", "test", "starts", "here"]
        Refused argv -> do
            ran <- state bin repo ("record" : argv)
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
toImplement :: Repo -> [Act]
toImplement repo =
    [ Record ["research.done", "2"]
    , Record ["interview.enough"]
    , Record ["plan.done", repo.notes </> "plan.md"]
    , Handback "researcher" ready
    , Handback "researcher" ready
    , Record ["confirm.confirmed"]
    , OpenPr
    , Commit
    , Handback "implementer" ready
    ]

-- | A Balanced Normal run to its first Simplify of the PR.
toSimplifyPr :: Repo -> [Act]
toSimplifyPr repo =
    [Record ["quality", "Balanced"], Record ["size", "Normal"]]
        <> toImplement repo
        <> [Handback "review-lead" reviewed, Record ["pick.final"], Handback "fixer" ready]

balancedPath :: Repo -> [Act]
balancedPath repo = toSimplifyPr repo <> [Handback "fixer" simplified, Record ["await_ci.green"], Record ["ready.done", prUrlString]]

balancedTranscript :: [Text]
balancedTranscript =
    [ "quality -> research"
    , "size -> research"
    , "research.done -> interview"
    , "interview.enough -> plan"
    , "plan.done -> simplify_plan"
    , "simplify_plan.done -> alternative"
    , "alternative.done -> confirm"
    , "confirm.confirmed -> draft"
    , "draft.done -> implement"
    , "implement.done -> refactor"
    , "refactor.skipped -> review"
    , "review.rows -> pick"
    , "pick.final -> describe"
    , "describe.done -> simplify_pr"
    , "simplify_pr.done -> await_ci"
    , "await_ci.green -> ready"
    , "ready.done -> out"
    ]

-- | POC Trivial: no researcher, proposal or refactor runs, so no hand-back of theirs.
trivialPath :: Repo -> [Act]
trivialPath repo =
    [ Record ["quality", "POC"]
    , Record ["size", "Trivial"]
    , Record ["interview.enough"]
    , Record ["plan.done", repo.notes </> "plan.md"]
    , Record ["confirm.confirmed"]
    , OpenPr
    , Commit
    , Handback "implementer" ready
    , Handback "review-lead" reviewed
    , Refused ["pick.loop", "--row", "R1"]
    , Record ["pick.final"]
    , Handback "fixer" ready
    , Handback "fixer" simplified
    , Record ["await_ci.green"]
    ]

trivialTranscript :: [Text]
trivialTranscript =
    [ "quality -> research"
    , "size -> research"
    , "research.skipped -> interview"
    , "interview.enough -> plan"
    , "plan.done -> simplify_plan"
    , "simplify_plan.skipped -> confirm"
    , "alternative.skipped -> confirm"
    , "confirm.confirmed -> draft"
    , "draft.done -> implement"
    , "implement.done -> refactor"
    , "refactor.skipped -> review"
    , "review.rows -> pick"
    , "pick.final -> describe"
    , "describe.done -> simplify_pr"
    , "simplify_pr.done -> await_ci"
    , "await_ci.green -> ready"
    , "ready.skipped -> out"
    ]

-- | Balanced Normal, moved to the review by override.
atReview :: [Act]
atReview = [Record ["quality", "Balanced"], Record ["size", "Normal"], Override "review"]

-- | A review back with its rows, and the lead's picks: a loop on this row.
reviewRound :: String -> [String] -> [Act]
reviewRound label verdicts = [Commit, Handback "review-lead" reviewed, Record (["pick.loop", "--row", label] <> verdicts)]

prUrl :: Text
prUrl = Text.pack prUrlString

prUrlString :: String
prUrlString = "https://github.com/o/r/pull/1"

-- | The branch's PR as @gh pr view --json@ prints it: draft or not, and its GitHub state.
pullRequest :: Bool -> String -> String
pullRequest isDraft prState =
    "{\"url\":\"" <> prUrlString <> "\",\"baseRefName\":\"main\",\"headRefName\":\"feat\",\"isDraft\":" <> (if isDraft then "true" else "false") <> ",\"state\":\"" <> prState <> "\"}"

-- | A temp worktree, its notes, the file the scripted @gh@ reads, and the environment of every call.
data Repo = Repo {root :: FilePath, work :: FilePath, notes :: FilePath, prJson :: FilePath, env :: [(String, String)]}

eventsOf :: Repo -> FilePath
eventsOf repo = repo.notes </> "events.jsonl"

withRepo :: (Repo -> IO ()) -> IO ()
withRepo test = withSystemTempDirectory "state-e2e" $ \root -> do
    inherited <- getEnvironment
    sh <- fromMaybe (error "no sh on PATH") <$> findExecutable "sh"
    let bin = root </> "bin"
        prJson = root </> "pr.json"
        path = bin <> maybe "" (":" <>) (lookup "PATH" inherited)
        fixed =
            [ ("PATH", path)
            , ("HOME", root)
            , ("GIT_CONFIG_NOSYSTEM", "1")
            , ("GIT_AUTHOR_NAME", "e2e")
            , ("GIT_AUTHOR_EMAIL", "e2e@example.com")
            , ("GIT_COMMITTER_NAME", "e2e")
            , ("GIT_COMMITTER_EMAIL", "e2e@example.com")
            ]
        repo =
            Repo
                { root
                , work = root </> "work"
                , notes = root </> "notes"
                , prJson
                , env = fixed <> [kv | kv@(name, _) <- inherited, name `notElem` map fst fixed]
                }
    createDirectory bin
    -- `gh pr view --json ...` as gh answers it: the PR, or no PR for the branch.
    writeExecutable (bin </> "gh") . unlines $
        [ "#!" <> sh
        , "if [ -f '" <> prJson <> "' ]; then cat '" <> prJson <> "'"
        , "else echo 'no pull requests found for branch \"feat\"' >&2; exit 1; fi"
        ]
    git repo {work = root} ["init", "-q", "--bare", "origin.git"]
    git repo {work = root} ["init", "-q", "-b", "main", "work"]
    git repo ["commit", "-q", "--allow-empty", "-m", "base"]
    git repo ["remote", "add", "origin", root </> "origin.git"]
    git repo ["push", "-q", "origin", "main"]
    git repo ["checkout", "-q", "-b", "feat"]
    test repo

writeExecutable :: FilePath -> String -> IO ()
writeExecutable file content = do
    writeFile file content
    setPermissions file . setOwnerExecutable True =<< getPermissions file

-- | Appends a line to one file and commits it: one changed line each time.
commitLine :: Repo -> IO ()
commitLine repo = do
    appendFile (repo.work </> "change.txt") "line\n"
    git repo ["add", "change.txt"]
    git repo ["commit", "-q", "-m", "change"]

git :: Repo -> [String] -> IO ()
git repo = void . gitOut repo

gitOut :: Repo -> [String] -> IO String
gitOut repo argv =
    readCreateProcessWithExitCode (proc "git" argv) {cwd = Just repo.work, env = Just repo.env} "" >>= \case
        (ExitSuccess, out, _) -> pure out
        (ExitFailure _, _, err) -> fail ("git " <> unwords argv <> ": " <> err)
