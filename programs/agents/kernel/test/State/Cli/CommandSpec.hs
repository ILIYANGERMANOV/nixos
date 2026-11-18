module State.Cli.CommandSpec (spec) where

import Data.Either (fromLeft, fromRight)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Options.Applicative qualified as Optparse
import State.Category.Flow (unqualify)
import State.Category.Fuel (Fuel (..))
import State.Category.Graph (Cap (..), OpenGraph (..))
import State.Category.Meter (someMeterName)
import State.Category.Path (unrecorded)
import State.Category.Step (eventText)
import State.Cli.Command (BriefPart (..), Command (..), Exit (..), Failure (..), InitArgs (..), Origin (..), RunCommand (..), Usage (..), anyEvent, explain, failureText, help, openQid, optparseText, parseCommand, parseHook, unknownEvent)
import State.Golden (golden)
import State.Protocol.Record (Recording (..))
import State.Run.Ask (Above (..), Kind (..), Link (..), Parent (..), Proposal (..), Reply (..), Route (..), oneLineText)
import State.Run.Event (AgentRole (..), Branch (..), Commit (..), Event (..), Label (..), Picks (..), RunId, StateName (..), Stop (..), StopReason (..), Target (..), TaskId (..), stepTook, tookIn)
import State.Run.EventGen (fuelSet, runId)
import State.Run.Fold (Refusal (..), RunState (..))
import State.Run.RunGen (g, happyPath, loadSteps, pickOf, runAt, securityScope, sha)
import State.Step.Artifact (Shape (..), Url (..), shellPathText)
import State.Step.Build (Outcome (..))
import State.Step.Catalog (outcome, outcomeEvent)
import State.Step.Plan (Outcome (..))
import State.Step.Request (Outcome (..))
import State.Step.Review (Outcome (..))
import System.Exit (ExitCode (..))
import Test.Hspec (Spec, describe, expectationFailure, it, runIO, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "State.Cli.Command" $ do
    steps <- runIO loadSteps
    let
        -- The command, else a refusal's what or a usage error's first line.
        parse argv = case parseCommand steps argv of
            Right (_, parsed) -> either (Left . (.what)) Right parsed
            Left said -> case usage "state" said of
                Right _ -> Left "help"
                Left text -> Left (Text.takeWhile (/= '\n') text)
        -- The event @record@ appends, at HEAD 'sha' when it records one.
        recorded argv = case parse ("record" : argv) of
            Right (OnRun (Record (Plain event))) -> Right event
            Right (OnRun (Record (AtHead event))) -> Right (event sha)
            Right _ -> Left "not a record"
            Left why -> Left why
        helpOf argv = case parseCommand steps argv of
            Left said -> fromRight "not help" (usage "state" said)
            Right _ -> "not help"

    describe "brief" $ do
        it "takes one step's section" $
            case parse ["brief", "researcher", "--section", "research"] of
                Right (OnRun (Brief (AgentRole "researcher") (Section (StateName "research")))) -> pure ()
                _ -> expectationFailure "not the research section"

        it "takes a whole brief, with a child engineer's task" $
            case parse ["brief", "engineer", "--task", "t1"] of
                Right (OnRun (Brief (AgentRole "engineer") (Whole (Just (TaskId "t1"))))) -> pure ()
                _ -> expectationFailure "not the task's brief"

        it "refuses a section and a task together" $
            fromLeft "parsed" (parse ["brief", "engineer", "--task", "t1", "--section", "research"]) `shouldBe` "Invalid option `--section'"

    describe "record" $ do
        it "parses the Fuel step's level" $
            recorded ["fuel.set", "low"] `shouldBe` Right (fuelSet Low)

        it "parses a request's target: a PR by its GitHub url, a branch, a ticket" $
            map recorded [["target", "pr", "https://github.com/o/r/pull/7"], ["target", "branch", "feat"], ["target", "ticket", "https://github.com/o/r/issues/3"]]
                `shouldBe` map (Right . Targeted) [OnPr (Url "https://github.com/o/r/pull/7"), OnBranch (Branch "feat"), OnTicket (Url "https://github.com/o/r/issues/3")]

        it "refuses a PR target that is no GitHub PR url" $
            case parseCommand steps ["record", "target", "pr", "https://github.com/o/r/issues/3"] of
                Right (_, Left failure) -> failure.why `shouldSatisfy` Text.isInfixOf "is not a GitHub PR URL"
                _ -> expectationFailure "not a refusal"

        it "records a gap with its text, words joined back" $
            recorded ["gap", "no", "hook", "fact"] `shouldBe` Right (Gapped "no hook fact")

        it "refuses a gap with no text" $
            recorded ["gap"] `shouldBe` Left "record gap"

        it "records an extend with its why" $
            recorded ["extend", "the", "user", "goes", "on"] `shouldBe` Right (Extended "the user goes on")

        it "records a commit event at HEAD with its touched areas" $
            recorded ["implement.done", "--touches", "none"] `shouldBe` Right (stepTook (ImplementDone (Commit sha Set.empty)))

        it "reads an implementer's unstated touches as every area" $
            recorded ["implement.done"] `shouldBe` Right (stepTook (ImplementDone (Commit sha (Set.fromList [minBound .. maxBound]))))

        it "leaves an event the table lacks, named as typed, to the run to refuse" $
            case parse ["record", "security/deploy.done", "now"] of
                Right (OnRun (RecordUnknown name)) -> name `shouldBe` "security/deploy.done"
                _ -> expectationFailure "not an unknown event"

        it "reads a plan's path to refuse a plan not written yet" $
            case parse ["record", "plan.done", "/notes/plan.md"] of
                Right (OnRun (Record (FromFile path parsed))) -> (path, parsed "") `shouldBe` ("/notes/plan.md", Right (stepTook (PlanDone "/notes/plan.md")))
                _ -> expectationFailure "not a recording read from a file"

        it "refuses an option the event does not take" $
            recorded ["implement.done", "--row", "R1"] `shouldBe` Left "Invalid option `--row'"

        it "takes a repeated flag once per time it is given" $
            recorded ["pick.final", "--row", "R1", "--row", "R2"] `shouldBe` Right (stepTook (PickFinal (Picks (Set.fromList [Label "R1", Label "R2"]) Map.empty)))

        it "keeps an event's free words that start with a dash" $
            recorded ["direct.done", "-x", "--flag", "added"] `shouldBe` Right (stepTook (DirectDone "-x --flag added"))

        it "records a step's outcome named inside a scope in that scope" $
            recorded ["security/review.rows"] `shouldBe` Right (tookIn securityScope (ReviewRows sha))

        it "refuses a run's event named inside a scope" $
            case parseCommand steps ["record", "security/target", "branch", "b"] of
                Right (_, Left failure) -> (failure.what, failure.why) `shouldBe` ("record security/target", "only a step's outcome is named inside a scope")
                _ -> expectationFailure "not a refusal"

        it "refuses a scoped event's usage with its qualified name" $
            case parseCommand steps ["record", "security/plan.done"] of
                Right (_, Left failure) -> (failure.what, failure.fix) `shouldBe` ("record security/plan.done", "state record security/plan.done <path>")
                _ -> expectationFailure "not a refusal"

        it "refuses an event's usage with its own fix" $
            case parseCommand steps ["record", "plan.done"] of
                Right (_, Left failure) -> (failure.what, failure.fix) `shouldBe` ("record plan.done", "state record plan.done <path>")
                _ -> expectationFailure "not a refusal"

    describe "other commands" $ do
        it "takes a question's words as one line, asked by the run itself" $
            case parse ["ask", "--kind", "Scope", "include", "docs?"] of
                Right (OnRun (AskOwn kind how question)) -> (kind, how, oneLineText question) `shouldBe` (Scope, ByRow, "include docs?")
                _ -> expectationFailure "not a question"

        it "takes --to user as the run's own question sent up at once, and refuses it with --from" $
            case (parse ["ask", "--kind", "Pick", "--to", "user", "which", "rows?"], parse ["ask", "--kind", "Pick", "--to", "user", "--from", "fixer", "q?"]) of
                (Right (OnRun (AskOwn kind how question)), Left refused) -> (kind, how, oneLineText question, refused) `shouldBe` (Pick, ToUser, "which rows?", "--to with --from")
                _ -> expectationFailure "not a question sent to the user and a refusal"

        it "takes an answer as chosen, --other as a reply none of the options covers, and --park as why it waits" $
            case (parse ["answer", "r1:1", "use", "Y"], parse ["answer", "r1:1", "--other", "add", "a", "CLI"], parse ["answer", "r1:1", "--park", "after", "the", "release"]) of
                (Right (OnRun (Answer _ chosen Nothing)), Right (OnRun (Answer _ other Nothing)), Right (OnRun (Park qid why))) ->
                    (chosen, other, qid, oneLineText why) `shouldBe` (Chose "use Y", Other "add a CLI", "r1:1", "after the release")
                _ -> expectationFailure "not an answer, an other reply and a park"

        it "takes a stop's reason and the rest as why" $
            case parse ["stop", "blocked", "no", "access"] of
                Right (OnRun (StopRun stop)) -> stop `shouldBe` Stop Blocked "no access"
                _ -> expectationFailure "not a stop"

        it "takes a void's seq and the rest as why" $
            case (parse ["void", "4", "spawned", "-in", "error"], parse ["void", "four", "why"]) of
                (Right (OnRun (Void n why)), Left refused) -> (n, why, refused) `shouldBe` (4, "spawned -in error", "seq four")
                _ -> expectationFailure "not a void"

        it "takes a move's worktree" $
            case parse ["move", "/work/other"] of
                Right (Move target) -> target `shouldBe` "/work/other"
                _ -> expectationFailure "not a move"

        it "keeps free words that start with a dash, an option it takes aside" $
            case (parse ["stop", "blocked", "-x", "--force", "failed"], parse ["ask", "--kind", "Scope", "-v", "or", "--verbose?"], parse ["answer", "r1:1", "use", "-f", "--by", "user"]) of
                (Right (OnRun (StopRun stop)), Right (OnRun (AskOwn _ _ question)), Right (OnRun (Answer _ answer by))) ->
                    (stop.why, oneLineText question, answer, by) `shouldBe` ("-x --force failed", "-v or --verbose?", Chose "use -f", Just TheUser)
                _ -> expectationFailure "not a stop, a question and an answer"

        it "takes a question's kind in any case" $
            [kind | kindName <- ["design", "DESIGN", "Design"], Right (OnRun (AskOwn kind _ _)) <- [parse ["ask", "--kind", kindName, "q?"]]]
                `shouldBe` [Design, Design, Design]

        it "refuses an unknown kind, listing the kinds" $
            case parseCommand steps ["ask", "--kind", "idea", "q?"] of
                Right (_, Left failure) -> (failure.what, failure.why) `shouldBe` ("no kind idea", "one of Fact|Pick|Design|Scope|Confirm|Security|Stuck")
                _ -> expectationFailure "not a refusal"

        it "takes a ruling's quoted words as one answer, why and cost" $
            case parse ["rule", "r1:1", "--answer", "use Y", "--why", "it is simpler", "--cost", "none"] of
                Right (OnRun (RuleOn qid _ proposal)) -> (qid, oneLineText proposal.answer, oneLineText proposal.why) `shouldBe` ("r1:1", "use Y", "it is simpler")
                _ -> expectationFailure "not a ruling"

        it "refuses a ruling's unquoted words, its fix quoting them" $
            case parseCommand steps ["rule", "r1:1", "--answer", "use", "Y", "--why", "it", "is", "simpler", "--cost", "none"] of
                Right (_, Left failure) -> (failure.what, failure.fix) `shouldBe` ("--answer, --why and --cost", "state rule r1:1 --answer \"<a>\" --why \"<w>\" --cost \"<c>\"")
                _ -> expectationFailure "not a refusal"

        it "needs the free words" $
            failureWhat (parse ["override", "review"]) `shouldBe` Just "Missing: <why>"

        it "takes a child's parent run and task" $
            case parse ["init", "--notes", "/n", "--parent", "r1", "--task", "t1"] of
                Right (Init args) -> args.origin `shouldBe` FromParent (Parent (runId "r1") (AtFan (TaskId "t1")))
                _ -> expectationFailure "not an init"

        it "takes a direct child's parent run, with no task" $
            case parse ["init", "--notes", "/n", "--parent", "r1"] of
                Right (Init args) -> args.origin `shouldBe` FromParent (Parent (runId "r1") Direct)
                _ -> expectationFailure "not an init"

        it "refuses --parent-log: a child names its parent by run id alone" $
            (failureWhat . parse) ["init", "--notes", "/n", "--parent", "r1", "--parent-log", "/p/events.jsonl", "--task", "t1"]
                `shouldBe` Just "Invalid option `--parent-log'"

        it "takes dump with a run id, refusing an event id" $
            (fmap dumped . parse <$> [["dump", "r1"], ["dump", "r1:2"]])
                `shouldBe` [Right (Just (runId "r1")), Left "no run id r1:2"]

        it "refuses a notes dir that is relative or holds what a shell reads" $
            map (failureWhat . parse . (["init", "--notes"] <>) . pure) ["rel/dir", ".", "/a b", "/a;b", "/a$(b)"]
                `shouldBe` [Just "--notes rel/dir", Just "--notes .", Just "--notes /a b", Just "--notes /a;b", Just "--notes /a$(b)"]

        it "keeps a notes dir in one spelling, with no trailing separator" $
            map (fmap notesOf . parse . (["init", "--notes"] <>) . pure) ["/n/", "/n", "/./n//"]
                `shouldBe` replicate 3 (Right (Just "/n"))

        it "refuses a task with no parent run" $
            failureWhat (parse ["init", "--notes", "/n", "--task", "t1"]) `shouldBe` Just "--task without --parent"

        it "takes --pr as a user's round on that PR" $
            map (fmap originOf . parse . (["init", "--notes", "/n"] <>)) [[], ["--pr", "https://github.com/o-1/r.x/pull/12"]]
                `shouldBe` [Right (Just (FromUser OwnPr)), Right (Just (FromUser (RoundOn (Url "https://github.com/o-1/r.x/pull/12"))))]

        it "takes --child as a caller's run, on its own PR or a round on --pr's" $
            map (fmap originOf . parse . (["init", "--notes", "/n", "--child"] <>)) [[], ["--pr", "https://github.com/o/r/pull/3"]]
                `shouldBe` [Right (Just (FromCaller OwnPr)), Right (Just (FromCaller (RoundOn (Url "https://github.com/o/r/pull/3"))))]

        it "refuses --child with --parent, its task or both" $
            map
                (failureWhat . parse . (["init", "--notes", "/n", "--child"] <>))
                [["--parent", "r1", "--task", "t1"], ["--task", "t1"], ["--parent", "r1"]]
                `shouldBe` replicate 3 (Just "--child with --parent")

        it "refuses a --pr that is no GitHub PR URL, its fix the URL's form" $ do
            let bad =
                    [ "github.com/o/r/pull/1"
                    , "http://github.com/o/r/pull/1"
                    , "https://gitlab.com/o/r/pull/1"
                    , "https://github.com/o/r/issues/1"
                    , "https://github.com/o/r/pull/1/files"
                    , "https://github.com/o/r/pull/"
                    , "https://github.com/o/r/pull/0"
                    , "https://github.com/o/r/pull/01"
                    , "https://github.com/o/r/pull/1x"
                    , "https://github.com/o/r/pull/1?x=1"
                    , "https://github.com/o r/r/pull/1"
                    , "https://github.com//r/pull/1"
                    ]
            map (failureWhat . parse . (["init", "--notes", "/n", "--pr"] <>) . pure) bad `shouldBe` map (Just . ("--pr " <>)) bad
            case parseCommand steps ["init", "--notes", "/n", "--pr", "https://github.com/o/r/pull/0"] of
                Right (_, Left failure) -> failure.fix `shouldBe` "state init --notes <dir> --pr https://github.com/<owner>/<repo>/pull/<n>"
                _ -> expectationFailure "not a refusal"

        it "refuses --pr with --parent or its task: a child's PR is its task's" $
            map
                (failureWhat . parse . (["init", "--notes", "/n", "--pr", "https://github.com/o/r/pull/1"] <>))
                [["--parent", "r1", "--task", "t1"], ["--parent", "r1"], ["--task", "t1"]]
                `shouldBe` replicate 3 (Just "--pr with --parent")

    describe "failures" $ do
        it "prints what, why and the fix as the analyzer parses them" $
            failureText "record" (Failure BadInput "fuel" "set once" "state show")
                `shouldBe` "state record: fuel - set once\nfix: state show\n"

        it "explains a void that breaks the replay by what breaks, fixing it by voiding the later line first" $
            (\failure -> (failure.why, failure.fix)) (explain g Balanced (runAt fueled).at (VoidBreaks 0 NotStarted))
                `shouldBe` ("the log without it does not replay: the log - its first line is not started", "state void <the later line that needs it> <why>, then this one")

        it "fixes a question past the gather's questions by extending, or going back to the gather's pick" $
            (explain g Balanced (runAt interviewing).at (OutOfBudget (capOf "Interview questions") 30)).fix
                `shouldBe` "state record extend <why> | state record interview.asked"

        it "fixes a researcher past the cap at the research state by extending" $
            (explain g Balanced (runAt researching).at (OutOfBudget (capOf "Researchers") 5)).fix
                `shouldBe` "state record extend <why> | state record gather/research.spawned"

        it "fixes a plan round past the cap by confirming or stopping" $
            (explain g Balanced (runAt planned).at (OutOfBudget (capOf "Plan rounds") 3)).fix
                `shouldBe` "state record confirm.confirmed | state stop rounds <why>"

        it "fixes a re-review past the cap by the loop's exit alone" $
            (explain g Balanced (runAt picking).at (OutOfBudget (capOf "Re-reviews") 3)).fix
                `shouldBe` "state record pick.final [--row <label>]... [--verdict <requirement>=<met|not-met|unverified>]..."

        it "explains an extend where no budget asks the user to go on" $
            (explain g Balanced (runAt fueled).at NothingToExtend).fix `shouldBe` "state next"

        it "fixes an event with no arrow by the events out of the step the Fuel takes" $
            [ (explain g fuel (runAt skipping).at (NoEdge (runAt skipping).at (outcomeEvent (outcome (ReviewClean sha))))).fix
            | fuel <- [Balanced, Low]
            ]
                `shouldBe` ["state record skip_simplify_plan.run", "state record skip_simplify_plan.run | state record skip_simplify_plan.skip"]

        it "fixes an event with no arrow at the gather's pick by its picks, a researcher open or not: a hand-back is no pick" $
            [ (explain g Balanced (runAt events).at (NoEdge (runAt events).at (outcomeEvent (outcome (ReviewClean sha))))).fix
            | events <- [fueled, researched]
            ]
                `shouldBe` replicate 2 "state record gather.enough | state record gather.interview | state record gather.research"

    describe "input the run refuses" $ do
        it "lists the events a gather's pick takes for an unknown one, fixing it by state next among its picks" $
            (\failure -> (failure.what, failure.why, failure.fix)) (unknownEvent g (runAt fueled) "gather.bogus")
                `shouldBe` ("no event gather.bogus", "at gather the run takes gather.enough, gather.interview, gather.research, extend", "state next")

        it "fixes an unknown event by the one event of the step it names" $
            (unknownEvent g (runAt interviewing) "interview.bogus").fix `shouldBe` "state record interview.asked"

        it "fixes an unknown event by the only one the run takes" $
            (unknownEvent g (runAt simplifying) "nope").fix `shouldBe` "state record simplify_plan.done"

        it "fixes an unknown event matching no step by state next" $
            (unknownEvent g (runAt fueled) "nope").fix `shouldBe` "state next"

        it "lists every event with no run, fixed by the help" $
            (\failure -> (Text.isPrefixOf "the events are gap, research.spawned, " failure.why, failure.fix)) (anyEvent "nope") `shouldBe` (True, "state help")

        it "refuses a question id that is not open, malformed or not" $
            [(failure.what, failure.why, failure.fix) | raw <- ["q1", "r1:99"], Left failure <- [openQid (runAt fueled) raw]]
                `shouldBe` [(what, "no question is open", "state pending") | what <- ["question q1", "question r1:99"]]

    describe "help" $ do
        it "record's help lists every event the flow's arrows take" $
            -- An await's edges take no event; a scoped event is recorded by its step's bare name.
            [event | ((from, event), _) <- Map.toList g.edges, isNothing (unrecorded g from), not (snd (unqualify (eventText event)) `Text.isInfixOf` helpOf ["record", "--help"])] `shouldBe` []

        it "is what --help prints" $
            helpOf ["--help"] `shouldBe` help steps

        it "names the run's kinds" $
            help steps `shouldSatisfy` Text.isInfixOf "kinds: Fact|"

        it "of a surplus argument, is the usage of the command it follows" $
            map (take 3 . Text.lines . usageError "state" . parseCommand steps) [["record", "gather.enough", "nope"], ["show", "nope"]]
                `shouldBe` [["Invalid argument `nope'", "", "Usage: state record gather.enough"], ["Invalid argument `nope'", "", "Usage: state show"]]

        -- The text a reader sees, pinned whole.
        it "of state" $ golden "usage/state.txt" (help steps)
        it "of state record" $ golden "usage/state-record-help.txt" (helpOf ["record", "--help"])
        it "of an unknown command" $ golden "usage/state-nope.txt" (usageError "state" (parseCommand steps ["nope"]))
        it "of state rule" $ golden "usage/state-rule-help.txt" (helpOf ["rule", "--help"])
        it "of an unknown hook" $ golden "usage/state-hook-bad.txt" (usageError "state-hook" (parseHook ["bad"]))
  where
    -- At the gather, past the root's Fuel; then with a researcher open, at simplify_plan's skip, at simplify_plan, at confirm and at the fix loop's pick, past the happy path's first steps.
    fueled = [fuelSet Balanced]
    researched = fueled <> take 2 happyPath
    researching = fueled <> [Took mempty (pickOf "gather" "research")]
    interviewing = fueled <> [Took mempty (pickOf "gather" "interview")]
    skipping = fueled <> take 6 happyPath
    simplifying = fueled <> take 7 happyPath
    planned = fueled <> take 8 happyPath
    picking = fueled <> take 13 happyPath <> [stepTook (ReviewRows sha)]
    -- The engineer's cap of this meter.
    capOf :: Text -> Cap
    capOf meter = case [cap | cap <- Map.elems g.caps, someMeterName cap.meter == meter] of
        [cap] -> cap
        caps -> error ("no single cap of " <> show meter <> ": " <> show caps)
    -- optparse's text: help asked for on the right, a usage error on the left.
    usage :: String -> Usage -> Either Text Text
    usage program (Usage failure) = case Optparse.renderFailure failure program of
        (text, ExitSuccess) -> Right (optparseText text)
        (text, ExitFailure _) -> Left (optparseText text)
    usageError :: String -> Either Usage a -> Text
    usageError program = \case
        Left said -> fromLeft "no usage error" (usage program said)
        Right _ -> "no usage error"
    failureWhat :: Either Text a -> Maybe Text
    failureWhat = either Just (const Nothing)
    originOf :: Command -> Maybe Origin
    originOf = \case
        Init args -> Just args.origin
        _ -> Nothing
    dumped :: Command -> Maybe RunId
    dumped = \case
        Dump run -> Just run
        _ -> Nothing
    notesOf :: Command -> Maybe FilePath
    notesOf = \case
        Init args -> Just (shellPathText args.notes)
        _ -> Nothing
