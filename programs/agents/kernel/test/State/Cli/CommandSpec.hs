module State.Cli.CommandSpec (spec) where

import Data.Either (fromLeft, fromRight)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Options.Applicative qualified as Opt
import State.Category.Fuel (Fuel (..))
import State.Category.Graph (OpenGraph (..))
import State.Category.Step (eventText)
import State.Cli.Command (Command (..), Exit (..), Failure (..), InitArgs (..), RunCommand (..), Usage (..), explain, failureText, help, optparseText, parseCommand, parseHook)
import State.Golden (golden)
import State.Protocol.Record (Recording (..))
import State.Run.Ask (Above (..), Kind (..), Parent (..), oneLineText)
import State.Run.Event (Asker (..), Commit (..), Event (..), Label (..), Picks (..), Stop (..), StopReason (..), stepTook)
import State.Run.Fold (Refusal (..), RunState (..))
import State.Run.Fold qualified as Fold
import State.Run.RunGen (g, loadSteps, runAt, sha)
import State.Step.Build (Outcome (..))
import State.Step.Catalog (outcome, outcomeEvent)
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

        it "refuses an event the table lacks, naming it" $
            recorded ["deploy.done"] `shouldBe` Left "Invalid argument `deploy.done'"

        it "refuses an option the event does not take" $
            recorded ["implement.done", "--row", "R1"] `shouldBe` Left "Invalid option `--row'"

        it "takes a repeated flag once per time it is given" $
            recorded ["pick.final", "--row", "R1", "--row", "R2"] `shouldBe` Right (stepTook (PickFinal (Picks (Set.fromList [Label "R1", Label "R2"]) Map.empty)))

        it "keeps an event's free words that start with a dash" $
            recorded ["refactor.skipped", "-x", "--flag", "added"] `shouldBe` Right (stepTook (RefactorSkipped "-x --flag added"))

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

        it "needs the free words" $
            failureWhat (parse ["override", "review"]) `shouldBe` Just "Missing: <why>"

        it "refuses a parent log that is not an absolute events.jsonl" $
            (failureWhat . parse) ["init", "--notes", "/n", "--parent", "r1", "--parent-log", "/p/other.jsonl", "--task", "t1"]
                `shouldBe` Just "--parent-log /p/other.jsonl"

        it "keeps an absolute parent log" $
            case parse ["init", "--notes", "/n", "--parent", "r1", "--parent-log", "/p/events.jsonl", "--task", "t1"] of
                Right (Init args) -> fmap (.log) args.parent `shouldBe` Just "/p/events.jsonl"
                _ -> expectationFailure "not an init"

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
            (\failure -> (failure.why, failure.fix)) (explain g Balanced (runAt []).at (FuelSetOnce Max))
                `shouldBe` ("it is max already, set once", "state show")

        it "fixes a question past the gather's questions by ending or extending the interview" $
            (explain g Balanced (runAt []).at (OutOfAsks 30)).fix
                `shouldBe` "state record interview.enough | state record extend <why> when the user goes on"

        it "fixes a research round past the gather's rounds by ending or extending the interview" $
            (explain g Balanced (runAt []).at (Fold.OutOfRounds "gather" 9)).fix
                `shouldBe` "state record interview.enough | state record extend <why> when the user goes on"

        it "fixes a round past another loop's rounds by leaving it or stopping" $
            (explain g Balanced (runAt []).at (Fold.OutOfRounds "review" 4)).fix
                `shouldSatisfy` Text.isSuffixOf " | state stop rounds <why>"

        it "fixes an event with no arrow by the events out of the step the Fuel takes" $
            [ (explain g fuel (runAt []).at (NoEdge (runAt []).at (outcomeEvent (outcome (ReviewClean sha))))).fix
            | fuel <- [Balanced, Low]
            ]
                `shouldBe` ["state record research.done <n>", "state record research.done <n> | state record research.skipped"]

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
        it "of an unknown event" $ golden "usage/state-record-nope.txt" (usageError "state" (parseCommand steps ["record", "nope"]))
        it "of an unknown hook" $ golden "usage/state-hook-bad.txt" (usageError "state-hook" (parseHook ["bad"]))
  where
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
