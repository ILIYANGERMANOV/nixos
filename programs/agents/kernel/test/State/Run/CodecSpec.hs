-- | A breakdown and a task file read as the 10x and the chief write them.
module State.Run.CodecSpec (spec) where

import State.Run.Codec (decodeBreakdown, decodeTask)
import State.Run.Event (
    FlowName (..),
    Repo (..),
    Task (..),
    TaskId (..),
    taskList,
 )
import State.Run.EventGen (replacing)
import State.Run.RunGen (breakdownJson, plainTask, roundTask, taskFileJson)
import State.Step.Artifact (shellPath)
import State.Step.Artifact qualified as Artifact (Task (..))
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec = describe "State.Run.Codec" $ do
    it "reads a breakdown's tasks in order" $
        map (.id) . taskList
            <$> decodeBreakdown (breakdownJson [plainTask "t1" [], plainTask "t2" ["t1"]])
            `shouldBe` Right [TaskId "t1", TaskId "t2"]

    it
        "refuses a breakdown that is empty, names a task twice or depends on a later task"
        $ map
            (either Left (const (Right ())) . decodeBreakdown . breakdownJson)
            [ []
            , [plainTask "t1" [], plainTask "t1" []]
            , [plainTask "t1" ["t2"], plainTask "t2" []]
            ]
            `shouldBe` [ Left "Error in $: a breakdown has a task at least"
                       , Left "Error in $: task t1 is named twice"
                       , Left "Error in $: task t1 depends on t2, which is not an earlier task"
                       ]

    it "reads a task file as a breakdown spells each task" $
        decodeTask (taskFileJson (plainTask "fix" ["t1"]))
            `shouldBe` Right (plainTask "fix" ["t1"])

    it "reads a round task's existing PR from its pr key" $
        decodeTask (taskFileJson (roundTask "t1" "https://pr/1"))
            `shouldBe` Right (roundTask "t1" "https://pr/1")

    it "reads a task's repo and worktree, each without the other" $
        map
            (\task -> decodeTask (taskFileJson task) == Right task)
            [placed, placed {worktree = Nothing}, placed {repo = Nothing}]
            `shouldBe` [True, True, True]

    it
        "reads a task's flow, an engineer's where the task names none, as a breakdown older than flows"
        $ map (fmap (.flow) . decodeTask . taskFileJson) [ledBy10x, plainTask "t1" []]
            `shouldBe` [Right TenXFlow, Right EngineerFlow]

    it "reads a task the chief leads by its flow's name" $
        fmap
            (.flow)
            (decodeTask (taskFileJson ledBy10x `replacing` ("\"10x\"", "\"chief\"")))
            `shouldBe` Right ChiefFlow

    it "refuses a task's flow no role leads" $
        decodeTask (taskFileJson ledBy10x `replacing` ("\"10x\"", "\"qa\""))
            `shouldBe` Left "Error in $: unknown flow \"qa\""

    it "refuses a repo not OWNER/REPO of shell-inert characters" $
        [ decodeTask (taskFileJson placed `replacing` ("\"o/r\"", hostile))
        | hostile <-
            [ "\"o/r/x\""
            , "\"/r\""
            , "\"o /r\""
            , "\"o;x/r\""
            , "\"o/$(x)\""
            , "\"o/r|x\""
            , "\"o/\\u00e9\""
            ]
        ]
            `shouldBe` map
                (\raw -> Left ("Error in $: unknown repo " <> raw))
                [ "\"o/r/x\""
                , "\"/r\""
                , "\"o /r\""
                , "\"o;x/r\""
                , "\"o/$(x)\""
                , "\"o/r|x\""
                , "\"o/\\233\""
                ]

    it "refuses a worktree not absolute or of characters a shell reads" $ do
        let hostile = ["\"wt\"", "\"/w t\"", "\"/w;x\"", "\"/w$(x)\"", "\"/w`x`\"", "\"/w|x\""]
        map
            (\raw -> decodeTask (taskFileJson placed `replacing` ("\"/wt\"", raw)))
            hostile
            `shouldBe` map
                ( \raw ->
                    Left
                        ( "Error in $: a worktree is an absolute path of ASCII letters, digits and ._/@+-, not "
                            <> raw
                        )
                )
                hostile

    it "refuses a malformed task file as the breakdown's decoder does" $
        map
            decodeTask
            [ "[]"
            , taskFileJson (plainTask "fix" [])
                `replacing` ("\"fuel\":\"balanced\"", "\"fuel\":\"huge\"")
            ]
            `shouldBe` [ Left "Error in $: parsing task failed, expected Object, but encountered Array"
                       , Left "Error in $: unknown fuel \"huge\""
                       ]

-- | A task whose child runs the 10x flow.
ledBy10x :: Task
ledBy10x = (plainTask "t1" []) {Artifact.flow = TenXFlow}

-- | A task whose breakdown names its repo and worktree.
placed :: Task
placed = (plainTask "t1" []) {repo = Just (Repo "o" "r"), worktree = shellPath "/wt"}
