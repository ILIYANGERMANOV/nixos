-- | A breakdown and a task file read as the 10x and the chief write them.
module State.Run.CodecSpec (spec) where

import Data.Text qualified as Text
import Hedgehog (forAll, (===))
import State.Run.Codec (
    decodeBreakdown,
    decodeTask,
    prStates,
    taskStateArgs,
    taskStateName,
 )
import State.Run.Event (
    Base (..),
    FlowName (..),
    Repo (..),
    Task (..),
    TaskId (..),
    TaskState (..),
    Url (..),
    taskList,
 )
import State.Run.EventGen (epicNamed, genTaskState, replacing, titled)
import State.Run.RunGen (breakdownJson, plainTask, roundTask, taskFileJson)
import State.Step.Artifact (shellPath)
import State.Step.Artifact qualified as Artifact (Task (..))
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Run.Codec" $ do
    {- @state record task <id> <state> <pr>@ reads its word off 'prStates';
    the advice writes it with 'taskStateName': the two lists name the same states. -}
    it "reads_back_every_state_naming_its_pr_as_the_cli_writes_it" . hedgehog $ do
        moved <- forAll genTaskState
        let (name, pr) = Text.breakOn " " (taskStateArgs moved)
        case lookup name prStates of
            Just state -> state (Url (Text.drop 1 pr)) === moved
            Nothing -> taskStateName moved === "parked"

    it "names delivered as the CLI writes it" $
        taskStateArgs (Delivered (Url "https://github.com/o/r/pull/7"))
            `shouldBe` "delivered https://github.com/o/r/pull/7"

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
                       , Left
                            "Error in $: unknown_task - task t1 depends on t2, which is not an earlier task"
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

    describe "a task's title and base" $ do
        it "reads the title and each base form" $ do
            let tasks =
                    [ (plainTask "t2" []) {base = OnDefault}
                    , (plainTask "t2" []) {base = OnEpic (epicNamed "payments")}
                    , (plainTask "t2" []) {base = OnTask (TaskId "t1")}
                    , (plainTask "t2" []) {title = titled "Pay by card"}
                    ]
            map (decodeTask . taskFileJson) tasks `shouldBe` map Right tasks

        it "refuses a title that is blank or more than one line" $
            map
                ( \raw ->
                    decodeTask (taskFileJson (plainTask "t1" []) `replacing` ("\"Task t1\"", raw))
                )
                ["\"\"", "\" \"", "\"a\\nb\""]
                `shouldBe` map
                    (\raw -> Left ("Error in $: a title is one line, not blank, not " <> raw))
                    ["\"\"", "\" \"", "\"a\\nb\""]

        it "refuses a bare branch name as a base, naming the three forms" $
            decodeTask
                ( taskFileJson (plainTask "t1" [])
                    `replacing` ("{\"kind\":\"on_default\"}", "\"main\"")
                )
                `shouldBe` Left
                    ( "Error in $: a base is "
                        <> "{\"kind\": \"on_default\"}, {\"kind\": \"on_epic\", \"epic\": \"<name>\"} "
                        <> "or {\"kind\": \"on_task\", \"task\": \"<earlier task id>\"}, not the bare name \"main\""
                    )

        it "refuses a base of no kind it knows, and an epic name that is no slug" $
            map
                ( \raw ->
                    decodeTask
                        (taskFileJson (plainTask "t1" []) `replacing` ("{\"kind\":\"on_default\"}", raw))
                )
                ["{\"kind\":\"on_branch\"}", "{\"kind\":\"on_epic\",\"epic\":\"a b\"}"]
                `shouldBe` [ Left "Error in $: unknown base \"on_branch\""
                           , Left "Error in $: unknown epic name \"a b\""
                           ]

        it "refuses the ids add and head, which state record task takes as words" $
            map (decodeTask . taskFileJson . (`plainTask` [])) ["add", "head"]
                `shouldBe` [ Left
                                "Error in $: task id \"add\" is taken by state record task add: name the task otherwise"
                           , Left
                                "Error in $: task id \"head\" is taken by state record task head: name the task otherwise"
                           ]

        it "refuses a breakdown whose task is based on a later task, or on itself" $
            map
                (either Left (const (Right ())) . decodeBreakdown . breakdownJson)
                [ [(plainTask "t1" []) {base = OnTask (TaskId "t2")}, plainTask "t2" []]
                , [(plainTask "t1" []) {base = OnTask (TaskId "t1")}]
                ]
                `shouldBe` [ Left
                                "Error in $: unknown_task - task t1 has base t2, which is not an earlier task"
                           , Left
                                "Error in $: unknown_task - task t1 has base t1, which is not an earlier task"
                           ]

-- | A task whose child runs the 10x flow.
ledBy10x :: Task
ledBy10x = (plainTask "t1" []) {Artifact.flow = TenXFlow}

-- | A task whose breakdown names its repo and worktree.
placed :: Task
placed = (plainTask "t1" []) {repo = Just (Repo "o" "r"), worktree = shellPath "/wt"}
