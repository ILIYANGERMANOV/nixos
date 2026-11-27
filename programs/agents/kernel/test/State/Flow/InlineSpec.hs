{- | A whole flow run inline, as a branch of a larger one: the 10x under a
'Scope' named after it. Its skill names its events bare, as in a run of
its own; the run records them in the scope it sits in.
-}
module State.Flow.InlineSpec (spec) where

import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import State.Category.Flow (ScopePath, scopePath)
import State.Category.Graph (Node (..), OpenGraph)
import State.Category.Step (StateName (..))
import State.Cli.Command (Command (OnRun), RunCommand (Record), parseCommand)
import State.Cli.Shell (recordedEvent)
import State.Flow.Role.TenX (tenX)
import State.Protocol.Advice (Action (..), Advice (..), Facts (..), advise)
import State.Protocol.Record (Option (..))
import State.Role (AgentRole (..), FlowName (TenXFlow))
import State.Run.Event (
    Event (..),
    Said (Finished),
    Task (..),
    TaskId (..),
    Url (..),
 )
import State.Run.Event qualified as Event (Start (..))
import State.Run.EventGen (logOf, oneLine, runId, start)
import State.Run.Fan (Fan (..), lookupTask)
import State.Run.Fold (
    Refusal,
    RunState (..),
    ScopedFan (..),
    currentFan,
    fanAt,
    replay,
 )
import State.Run.RunGen (
    breakdownJson,
    childOf,
    loadSteps,
    plainTask,
    refTo,
    scopedIn,
 )
import State.Step.Fan (engineers)
import State.Table (Steps)
import Test.Hspec (Spec, describe, it, runIO, shouldBe)

spec :: Spec
spec = describe "a 10x run inline under a Scope" $ do
    steps <- runIO loadSteps
    let walked = walk steps
        actionAt events = (\state -> (advise steps inline noFacts state).action) <$> walked events

    it "takes its bare breakdown in its scope, at its scoped fan-out" $
        fanAt . (.at) <$> walked toFanOut
            `shouldBe` Right (Just (ScopedFan tenXScope engineers))

    it "finds a child's task at the scoped fan-out, as a child's init does" $
        fmap (.id) . (`lookupTask` t1) . currentFan <$> walked toFanOut
            `shouldBe` Right (Just t1)

    it "spawns the task's engineer at the scoped fan-out" $
        actionAt toFanOut `shouldBe` Right (Spawn (AgentRole "engineer") (Just t1))

    it
        "resumes a child lost at a restart, and waits on it once its resume is recorded bare"
        $ map actionAt [lost, lost <> [bare ["resumed", "c1"]]]
            `shouldBe` [ Right
                            (Resume (runId "c1") "lost at a restart: a fresh engineer with its spawn prompt")
                       , Right (AwaitChildren (t1 :| []))
                       ]

    it "holds a wake recorded bare in the scoped fan-out, until it is acted on" $
        map
            (fmap ((.held) . currentFan) . walked)
            [handedBack <> [held], handedBack <> [held, bare ["acted", "t1", wake]]]
            `shouldBe` [Right [(t1, Url wake)], Right []]

    it
        "goes on to its merge once every task is settled, advised by its qualified name"
        $ optionCommands <$> actionAt merged
            `shouldBe` Right ["state record 10x/merge.done <url>", "state record 10x/merge.next_round"]

    it "ends the run through a bare merge, every outcome in its scope" $
        (\state -> (state.at, Map.keys state.fans))
            <$> walked (merged <> [bare ["merge.done", pr]])
            `shouldBe` Right (Out, [ScopedFan tenXScope engineers])
  where
    t1 = TaskId "t1"
    toFanOut =
        [ logged (Overridden (StateName "10x/breakdown") "the plan is agreed")
        , bareFile
            ["breakdown.done", "--tasks", "tasks.json"]
            (breakdownJson [plainTask "t1" []])
        ]
    lost = toFanOut <> [logged (Spawned (childOf "c1" "t1")), logged Restarted]
    handedBack =
        toFanOut
            <> [ logged (Spawned (childOf "c1" "t1"))
               , logged
                    (HandedBack (runId "c1") (Just (refTo "t1")) (Finished (oneLine "PR #1")))
               ]
    held = bare ["held", "t1", wake]
    merged = handedBack <> [bare ["task", "t1", "merged", pr]]
    pr = "https://github.com/o/r/pull/1"
    wake = "https://github.com/o/r/pull/1#issuecomment-1"
    noFacts = Facts Nothing Nothing []
    optionCommands = \case
        Run options -> map (.command) (toList options)
        _ -> []

-- | The 10x, run inline under a scope named after it.
inline :: OpenGraph
inline = scopedIn "10x" tenX

tenXScope :: ScopePath
tenXScope = scopePath "10x"

-- | One step of the run: the event it appends, decided where the run is.
type Step = Steps -> RunState -> Event

{- | The run after these steps, each one's event appended to the log the
steps before it wrote, by the user, of the 10x flow.
-}
walk :: Steps -> [Step] -> Either Refusal RunState
walk steps = go []
  where
    go events = \case
        [] -> replayed events
        next : rest -> replayed events >>= \state -> go (events <> [next steps state]) rest
    replayed events = replay inline (logOf (Started start {Event.flow = TenXFlow} :| events))

-- | An event the shell or a hook appends as it is: no name to resolve.
logged :: Event -> Step
logged event _ _ = event

-- | @state record <words>@, a bare name recorded where the run is, as the shell records it.
bare :: [Text] -> Step
bare words' = recorded words' Nothing

-- | 'bare' for an event read from a file that holds this text.
bareFile :: [Text] -> Text -> Step
bareFile words' = recorded words' . Just

{- | The seq passed is the one a @task add@ takes as its breakdown when the
run has none: no recording here adds a task.
-}
recorded :: [Text] -> Maybe Text -> Step
recorded words' file steps state = case parseCommand steps ("record" : words') of
    Right (_, Right (OnRun (Record recording))) | Right event <- recordedEvent inline state Nothing file 0 recording -> event
    _ -> error ("not a recording of this test: " <> show words')
