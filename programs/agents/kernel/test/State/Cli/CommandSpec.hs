module State.Cli.CommandSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import State.Category.Graph (OpenGraph (..))
import State.Category.Mode (Mode (..), Quality (..), Size (..))
import State.Category.Step (eventText)
import State.Cli.Command (Command (..), Exit (..), Failure (..), InitArgs (..), RunCommand (..), explain, failureText, help, parseCommand)
import State.Protocol.Record (Recording (..))
import State.Run.Ask (Kind (..), Parent (..), oneLineText)
import State.Run.Event (Asker (..), Commit (..), Event (..), Stop (..), StopReason (..), stepTook)
import State.Run.Fold (Refusal (..), RunState (..))
import State.Run.RunGen (g, loadSteps, runAt, sha)
import State.Step.Build (Outcome (..))
import State.Step.Catalog (outcome, outcomeEvent)
import State.Step.Review (Outcome (..))
import Test.Hspec (Spec, describe, expectationFailure, it, runIO, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "State.Cli.Command" $ do
    steps <- runIO loadSteps
    let parse = snd . parseCommand steps
        -- The event @record@ appends, at HEAD 'sha' when it records one.
        recorded argv = case parse ("record" : argv) of
            Right (OnRun (Record (Plain event))) -> Right event
            Right (OnRun (Record (AtHead event))) -> Right (event sha)
            Right _ -> Left "not a record"
            Left failure -> Left failure.what

    describe "record" $ do
        it "parses a stay event's argument" $
            recorded ["quality", "Balanced"] `shouldBe` Right (QualitySet Balanced)

        it "records a commit event at HEAD with its touched areas" $
            recorded ["implement.done", "--touches", "none"] `shouldBe` Right (stepTook (ImplementDone (Commit sha Set.empty)))

        it "reads an implementer's unstated touches as every area" $
            recorded ["implement.done"] `shouldBe` Right (stepTook (ImplementDone (Commit sha (Set.fromList [minBound .. maxBound]))))

        it "refuses an event the table lacks, naming it" $
            recorded ["deploy.done"] `shouldBe` Left "no event deploy.done"

        it "refuses an option the event does not take" $
            recorded ["size", "Normal", "--touches", "none"] `shouldBe` Left "--touches"

    describe "other commands" $ do
        it "takes a question's words as one line, asked by the run itself" $
            case parse ["ask", "--kind", "Scope", "include", "docs?"] of
                Right (OnRun (AskQuestion kind from question)) -> (kind, from, oneLineText question) `shouldBe` (Scope, Itself, "include docs?")
                _ -> expectationFailure "not a question"

        it "takes a stop's reason and the rest as why" $
            case parse ["stop", "blocked", "no", "access"] of
                Right (OnRun (StopRun stop)) -> stop `shouldBe` Stop Blocked "no access"
                _ -> expectationFailure "not a stop"

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
            failureText "record" (Failure BadInput "size" "set once" "state show")
                `shouldBe` "state record: size - set once\nfix: state show\n"

        it "fixes a second size with grew" $
            (explain g (Mode Balanced Normal) (runAt []).at (SizeSetOnce Normal)).fix `shouldBe` "state record grew <why>"

        it "fixes an event with no arrow by the events out of the step the mode takes" $
            [ (explain g mode (runAt []).at (NoEdge (runAt []).at (outcomeEvent (outcome (ReviewClean sha))))).fix
            | mode <- [Mode Balanced Normal, Mode Poc Trivial]
            ]
                `shouldBe` ["state record research.done <n>", "state record research.done <n> | state record research.skipped"]

        it "help lists every event the flow's arrows take" $
            [event | (_, event) <- Map.keys g.edges, not (eventText event `Text.isInfixOf` help steps)] `shouldBe` []

        it "help starts with the usage line" $
            help steps `shouldSatisfy` Text.isPrefixOf "usage: state"
  where
    failureWhat :: Either Failure a -> Maybe Text
    failureWhat = either (Just . (.what)) (const Nothing)
