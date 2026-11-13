module State.CliSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import State.Ask (Kind (..), oneLineText)
import State.Cap (eventText)
import State.Cli (Command (..), Exit (..), Failure (..), InitArgs (..), Recording (..), RunCommand (..), explain, failureText, help, parseCommand)
import State.Event (Asker (..), Commit (..), Event (..), Outcome (..), Stop (..), StopReason (..), outcomeEvent)
import State.Fold (Refusal (..), RunState (..))
import State.Graph (OpenGraph (..))
import State.Mode (Quality (..), Size (..))
import State.RunGen (g, loadSteps, runAt, sha)
import Test.Hspec (Spec, describe, expectationFailure, it, runIO, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "State.Cli" $ do
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
            recorded ["implement.done", "--touches", "none"] `shouldBe` Right (Took (ImplementDone (Commit sha Set.empty)))

        it "reads an implementer's unstated touches as every area" $
            recorded ["implement.done"] `shouldBe` Right (Took (ImplementDone (Commit sha (Set.fromList [minBound .. maxBound]))))

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
            (failureWhat . parse) ["init", "--notes", "/n", "--parent", "r1", "--parent-log", "/p/other.jsonl"]
                `shouldBe` Just "--parent-log /p/other.jsonl"

        it "keeps an absolute parent log" $
            case parse ["init", "--notes", "/n", "--parent", "r1", "--parent-log", "/p/events.jsonl"] of
                Right (Init args) -> fmap snd args.parent `shouldBe` Just "/p/events.jsonl"
                _ -> expectationFailure "not an init"

        it "refuses --parent without its log" $
            (failureWhat . parse) ["init", "--notes", "/n", "--parent", "r1"] `shouldBe` Just "--parent and --parent-log go together"

    describe "failures" $ do
        it "prints what, why and the fix as the analyzer parses them" $
            failureText "record" (Failure BadInput "size" "set once" "state show")
                `shouldBe` "state record: size - set once\nfix: state show\n"

        it "fixes a second size with grew" $
            (explain g (runAt []).at (SizeSetOnce Normal)).fix `shouldBe` "state record grew <why>"

        it "fixes an event with no arrow by the events out of the step" $
            (explain g (runAt []).at (NoEdge (runAt []).at (outcomeEvent (ReviewClean sha)))).fix
                `shouldBe` "state record research.done | state record research.skipped"

        it "help lists every event the flow's arrows take" $
            [event | (_, event) <- Map.keys g.edges, not (eventText event `Text.isInfixOf` help steps)] `shouldBe` []

        it "help starts with the usage line" $
            help steps `shouldSatisfy` Text.isPrefixOf "usage: state"
  where
    failureWhat :: Either Failure a -> Maybe Text
    failureWhat = either (Just . (.what)) (const Nothing)
