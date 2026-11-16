module State.Cli.CommandSpec (spec) where

import Data.Either (fromLeft, fromRight)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Options.Applicative qualified as Opt
import State.Category.Fuel (Fuel (..))
import State.Category.Graph (Cap (..), OpenGraph (..))
import State.Category.Meter (someMeterName)
import State.Category.Step (eventText)
import State.Cli.Command (Command (..), Exit (..), Failure (..), InitArgs (..), RunCommand (..), Usage (..), anyEvent, explain, failureText, help, openQid, optparseText, parseCommand, parseHook, unknownEvent)
import State.Golden (golden)
import State.Protocol.Record (Recording (..))
import State.Run.Ask (Above (..), Kind (..), Parent (..), Proposal (..), oneLineText)
import State.Run.Event (Asker (..), Commit (..), Event (..), Label (..), Picks (..), Stop (..), StopReason (..), stepTook, tookIn)
import State.Run.Fold (Refusal (..), RunState (..))
import State.Run.RunGen (g, happyPath, loadSteps, runAt, securityScope, sha)
import State.Step.Artifact (shellPathText)
import State.Step.Build (Outcome (..))
import State.Step.Catalog (outcome, outcomeEvent)
import State.Step.Plan (Outcome (..))
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

    describe "record" $ do
        it "parses a stay event's argument" $
            recorded ["fuel", "low"] `shouldBe` Right (FuelSet Low)

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
            recorded ["refactor.skipped", "-x", "--flag", "added"] `shouldBe` Right (stepTook (RefactorSkipped "-x --flag added"))

        it "records a step's outcome named inside a scope in that scope" $
            recorded ["security/review.rows"] `shouldBe` Right (tookIn securityScope (ReviewRows sha))

        it "refuses a run's event named inside a scope" $
            case parseCommand steps ["record", "security/fuel", "low"] of
                Right (_, Left failure) -> (failure.what, failure.why) `shouldBe` ("record security/fuel", "only a step's outcome is named inside a scope")
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
                Right (OnRun (AskQuestion kind from question)) -> (kind, from, oneLineText question) `shouldBe` (Scope, Itself, "include docs?")
                _ -> expectationFailure "not a question"

        it "takes a stop's reason and the rest as why" $
            case parse ["stop", "blocked", "no", "access"] of
                Right (OnRun (StopRun stop)) -> stop `shouldBe` Stop Blocked "no access"
                _ -> expectationFailure "not a stop"

        it "keeps free words that start with a dash, an option it takes aside" $
            case (parse ["stop", "blocked", "-x", "--force", "failed"], parse ["ask", "--kind", "Scope", "-v", "or", "--verbose?"], parse ["answer", "r1:1", "use", "-f", "--by", "user"]) of
                (Right (OnRun (StopRun stop)), Right (OnRun (AskQuestion _ _ question)), Right (OnRun (Answer _ answer by))) ->
                    (stop.why, oneLineText question, answer, by) `shouldBe` ("-x --force failed", "-v or --verbose?", "use -f", Just TheUser)
                _ -> expectationFailure "not a stop, a question and an answer"

        it "takes a question's kind in any case" $
            [kind | kindName <- ["design", "DESIGN", "Design"], Right (OnRun (AskQuestion kind _ _)) <- [parse ["ask", "--kind", kindName, "q?"]]]
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

        it "refuses a parent log that is not an absolute events.jsonl" $
            (failureWhat . parse) ["init", "--notes", "/n", "--parent", "r1", "--parent-log", "/p/other.jsonl", "--task", "t1"]
                `shouldBe` Just "--parent-log /p/other.jsonl"

        it "keeps an absolute parent log" $
            case parse ["init", "--notes", "/n", "--parent", "r1", "--parent-log", "/p/events.jsonl", "--task", "t1"] of
                Right (Init args) -> fmap (.log) args.parent `shouldBe` Just "/p/events.jsonl"
                _ -> expectationFailure "not an init"

        it "refuses a notes dir that is relative or holds what a shell reads" $
            map (failureWhat . parse . (["init", "--notes"] <>) . pure) ["rel/dir", ".", "/a b", "/a;b", "/a$(b)"]
                `shouldBe` [Just "--notes rel/dir", Just "--notes .", Just "--notes /a b", Just "--notes /a;b", Just "--notes /a$(b)"]

        it "keeps a notes dir in one spelling, with no trailing separator" $
            map (fmap notesOf . parse . (["init", "--notes"] <>) . pure) ["/n/", "/n", "/./n//"]
                `shouldBe` replicate 3 (Right (Just "/n"))

        it "refuses --parent, its log or its task without the other two" $
            map
                (failureWhat . parse . (["init", "--notes", "/n"] <>))
                [["--parent", "r1", "--task", "t1"], ["--parent", "r1", "--parent-log", "/p/events.jsonl"], ["--task", "t1"], ["--parent", "r1"]]
                `shouldBe` replicate 4 (Just "--parent, --parent-log and --task go together")

    describe "failures" $ do
        it "prints what, why and the fix as the analyzer parses them" $
            failureText "record" (Failure BadInput "fuel" "set once" "state show")
                `shouldBe` "state record: fuel - set once\nfix: state show\n"

        it "explains a second Fuel by the one set" $
            (\failure -> (failure.why, failure.fix)) (explain g Balanced (runAt []).at (runAt []).meters (FuelSetOnce Max))
                `shouldBe` ("it is max already, set once", "state show")

        it "fixes a question past the gather's questions by extending or ending the gather" $
            (explain g Balanced (runAt researched).at (runAt researched).meters (OutOfBudget (capOf "Interview questions") 30)).fix
                `shouldBe` "state record extend <why> | state record gather.enough"

        it "fixes a researcher past the cap by extending or ending the gather" $
            (explain g Balanced (runAt []).at (runAt []).meters (OutOfBudget (capOf "Researchers") 5)).fix
                `shouldBe` "state record extend <why> | state record gather.enough"

        it "fixes a plan round past the cap by confirming or stopping" $
            (explain g Balanced (runAt planned).at (runAt planned).meters (OutOfBudget (capOf "Plan rounds") 3)).fix
                `shouldBe` "state record confirm.confirmed | state stop rounds <why>"

        it "fixes a re-review past the cap by the loop's exit alone" $
            (explain g Balanced (runAt picking).at (runAt picking).meters (OutOfBudget (capOf "Re-reviews") 3)).fix
                `shouldBe` "state record pick.final [--row <label>]... [--verdict <requirement>=<met|not-met|unverified>]..."

        it "explains an extend where no budget asks the user to go on" $
            (explain g Balanced (runAt []).at (runAt []).meters NothingToExtend).fix `shouldBe` "state next"

        it "fixes an event with no arrow by the events out of the step the Fuel takes" $
            [ (explain g fuel (runAt simplifying).at (runAt simplifying).meters (NoEdge (runAt simplifying).at (outcomeEvent (outcome (ReviewClean sha))))).fix
            | fuel <- [Balanced, Low]
            ]
                `shouldBe` ["state record simplify_plan.done", "state record simplify_plan.done | state record simplify_plan.skipped"]

        it "names a choice's hand-back in the fix only while a child is open" $
            [ (explain g Balanced (runAt events).at (runAt events).meters (NoEdge (runAt events).at (outcomeEvent (outcome (ReviewClean sha))))).fix
            | events <- [[], researched]
            ]
                `shouldBe` [ "state record research.spawned | state record gather.enough"
                           , "state record research.spawned | state record research.handed_back | state record gather.enough"
                           ]

    describe "input the run refuses" $ do
        it "lists the events a gather takes for an unknown one, fixing it by its step's" $
            (\failure -> (failure.what, failure.why, failure.fix)) (unknownEvent g (runAt []) "gather.bogus")
                `shouldBe` ("no event gather.bogus", "at gather the run takes research.spawned, research.handed_back, gather.enough, extend", "state record gather.enough")

        it "fixes an unknown event by the only one the run takes" $
            (unknownEvent g (runAt simplifying) "nope").fix `shouldBe` "state record simplify_plan.done"

        it "fixes an unknown event matching no step by state next" $
            (unknownEvent g (runAt []) "nope").fix `shouldBe` "state next"

        it "lists every event with no run, fixed by the help" $
            (\failure -> (Text.isPrefixOf "the events are fuel, research.spawned, " failure.why, failure.fix)) (anyEvent "nope") `shouldBe` (True, "state help")

        it "refuses a question id that is not open, malformed or not" $
            [(failure.what, failure.why, failure.fix) | raw <- ["q1", "r1:99"], Left failure <- [openQid (runAt []) raw]]
                `shouldBe` [(what, "no question is open", "state pending") | what <- ["question q1", "question r1:99"]]

    describe "help" $ do
        it "record's help lists every event the flow's arrows take" $
            [event | (_, event) <- Map.keys g.edges, not (eventText event `Text.isInfixOf` helpOf ["record", "--help"])] `shouldBe` []

        it "is what --help prints" $
            helpOf ["--help"] `shouldBe` help steps

        it "names the run's kinds" $
            help steps `shouldSatisfy` Text.isInfixOf "kinds: Fact|"

        -- The text a reader sees, pinned whole.
        it "of state" $ golden "usage/state.txt" (help steps)
        it "of state record" $ golden "usage/state-record-help.txt" (helpOf ["record", "--help"])
        it "of an unknown command" $ golden "usage/state-nope.txt" (usageError "state" (parseCommand steps ["nope"]))
        it "of state rule" $ golden "usage/state-rule-help.txt" (helpOf ["rule", "--help"])
        it "of an unknown hook" $ golden "usage/state-hook-bad.txt" (usageError "state-hook" (parseHook ["bad"]))
  where
    -- At the gather with a researcher open, at simplify_plan, at confirm and at the fix loop's pick, past the happy path's first steps.
    researched = map (Took mempty) (take 1 happyPath)
    simplifying = map (Took mempty) (take 4 happyPath)
    planned = map (Took mempty) (take 5 happyPath)
    picking = map (Took mempty) (take 9 happyPath) <> [stepTook (ReviewRows sha)]
    -- The engineer's cap of this meter.
    capOf :: Text -> Cap
    capOf meter = case [cap | cap <- Map.elems g.caps, someMeterName cap.meter == meter] of
        [cap] -> cap
        caps -> error ("no single cap of " <> show meter <> ": " <> show caps)
    -- optparse's text: help asked for on the right, a usage error on the left.
    usage :: String -> Usage -> Either Text Text
    usage program (Usage failure) = case Opt.renderFailure failure program of
        (text, ExitSuccess) -> Right (optparseText text)
        (text, ExitFailure _) -> Left (optparseText text)
    usageError :: String -> Either Usage a -> Text
    usageError program = \case
        Left said -> fromLeft "no usage error" (usage program said)
        Right _ -> "no usage error"
    failureWhat :: Either Text a -> Maybe Text
    failureWhat = either Just (const Nothing)
    notesOf :: Command -> Maybe FilePath
    notesOf = \case
        Init args -> Just (shellPathText args.notes)
        _ -> Nothing
