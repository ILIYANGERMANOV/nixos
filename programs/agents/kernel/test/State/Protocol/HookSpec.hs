module State.Protocol.HookSpec (spec) where

import Data.Aeson (
    Object,
    Value (..),
    eitherDecode,
    eitherDecodeFileStrict,
    encode,
    object,
    toJSON,
    (.=),
 )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import State.Artifact (absPath)
import State.Category.Graph (Node (..), Place (..))
import State.Category.Step (stepName)
import State.Protocol.Advice (Readiness (..))
import State.Protocol.Binding (AgentId (..), Binding (..), Key (..), slotOf)
import State.Protocol.Hook
import State.Run.Event (
    AgentRole (..),
    Branch (..),
    DraftPr (..),
    Envelope (..),
    Event (Restarted, Spawned, Stopped, Voided, WorkerSpawned),
    Session (..),
    SessionId (..),
    Stop (..),
    StopReason (..),
    Url (..),
    stepTook,
 )
import State.Run.EventGen (line, logOf, run, runId, started)
import State.Run.RunGen (childOf, commit, loadSteps, plainTask, runAt, tenXAt)
import State.Step.Build (Outcome (..), Sing (Refactor))
import State.Step.Review (Outcome (..))
import System.Environment (getEnv)
import Test.Hspec (
    Spec,
    describe,
    expectationFailure,
    it,
    runIO,
    shouldBe,
    shouldNotBe,
    shouldSatisfy,
 )

spec :: Spec
spec = describe "the hooks" $ do
    steps <- runIO loadSteps
    vocabulary <-
        runIO
            ( either fail pure
                =<< eitherDecodeFileStrict @Vocabulary
                =<< getEnv "HOOK_VOCABULARY"
            )

    describe "reading an event" $ do
        it "reads a subagent's hand-back, its agent and its input" $
            parseHookEvent
                (beforeTool "handback" fixer (object ["message" .= ("READY" :: Text)]))
                `shouldBe` Right
                    ( BeforeTool
                        ( Call
                            (Just (SessionId "s"))
                            "/w"
                            (Just (Agent (Just (AgentId "a1")) (Just (AgentRole "fixer"))))
                        )
                        HandbackTool
                        (message "READY")
                    )

        it "reads the lead, whose agent is null" $
            parseHookEvent (sessionStart "startup")
                `shouldBe` Right
                    (SessionStart (Call (Just (SessionId "s")) "/w" Nothing) (claudeOpened Startup))

        it "reads an empty session as none" $
            parseHookEvent (withField "session" "" (sessionStart "startup"))
                `shouldBe` Right (SessionStart (Call Nothing "/w" Nothing) (claudeOpened Startup))

        it "reads a session start that names no transcript or model" $
            parseHookEvent
                ( withNull "request_model"
                    . withNull "transcript_path"
                    . withField "harness" "opencode"
                    $ sessionStart "resume"
                )
                `shouldBe` Right
                    ( SessionStart
                        (Call (Just (SessionId "s")) "/w" Nothing)
                        (Opened Resumed "opencode" Nothing Nothing)
                    )

        it "refuses a session start whose transcript path is not absolute" $
            parseHookEvent
                (withField "transcript_path" "p/s.jsonl" (sessionStart "startup"))
                `shouldSatisfy` isLeft

        it "refuses a session start that names no harness" $
            parseHookEvent (without "harness" (sessionStart "startup"))
                `shouldSatisfy` isLeft

        it "keeps the session as its run logs it, its source by the hook's own word" $
            sessionOf (claudeOpened Resumed)
                `shouldBe` Session
                    { harness = "claude-code"
                    , transcript = absPath transcriptFile
                    , trigger = "resume"
                    , model = Just "claude-opus-5-5"
                    }

        it "reads a subagent's start, by its agent" $
            parseHookEvent (agentStart "engineer")
                `shouldBe` Right
                    ( AgentStart
                        ( Call
                            (Just (SessionId "s"))
                            "/w"
                            (Just (Agent (Just (AgentId "a1")) (Just (AgentRole "engineer"))))
                        )
                    )

        it "reads a typed prompt's expansion, by the skill it names" $
            parseHookEvent (promptExpansion "10x-engineer")
                `shouldBe` Right
                    (PromptExpansion (Call (Just (SessionId "s")) "/w" Nothing) "10x-engineer")

        it "reads an agent's stop, with the agents still running" $
            map parseHookEvent [agentStop fixer ["a1", "b2"], agentStop Null []]
                `shouldBe` [ Right
                                ( AgentStop
                                    ( Call
                                        (Just (SessionId "s"))
                                        "/w"
                                        (Just (Agent (Just (AgentId "a1")) (Just (AgentRole "fixer"))))
                                    )
                                    [AgentId "a1", AgentId "b2"]
                                )
                           , Right (AgentStop (Call (Just (SessionId "s")) "/w" Nothing) [])
                           ]

        it "refuses an agent's stop that lists no agents running" $
            parseHookEvent
                (encodeObject (common Null <> KeyMap.fromList [("event", "agentStop")]))
                `shouldSatisfy` isLeft

        it "refuses a prompt expansion that names no skill" $
            parseHookEvent
                (encodeObject (common Null <> KeyMap.fromList [("event", "promptExpansion")]))
                `shouldSatisfy` isLeft

        it "refuses an unknown event, tool or source" $
            map
                parseHookEvent
                [ withField "event" "teardown" (sessionStart "startup")
                , beforeTool "teleport" Null (object [])
                , sessionStart "reboot"
                ]
                `shouldSatisfy` all isLeft

        it "reads an afterTool's input and output" $
            parseHookEvent (encodeObject (afterToolFields "delegate"))
                `shouldBe` Right
                    ( AfterTool
                        (Call (Just (SessionId "s")) "/w" (Just reviewLead))
                        Delegate
                        KeyMap.empty
                        (String "ok")
                    )

        it "refuses an afterTool with no output, as the contract requires one" $
            parseHookEvent (encodeObject (KeyMap.delete "output" (afterToolFields "shell")))
                `shouldSatisfy` isLeft

        it "names the events, tools and sources of vocabulary.json, in its order" $ do
            map
                (\name -> eventOf <$> parseHookEvent (event name))
                (vocabulary Map.! "events")
                `shouldBe` map
                    Right
                    [ "sessionStart"
                    , "beforeTool"
                    , "afterTool"
                    , "agentStart"
                    , "promptExpansion"
                    , "agentStop"
                    ]
            map
                (\name -> toolOf <$> parseHookEvent (beforeTool name Null (object [])))
                (vocabulary Map.! "tools")
                `shouldBe` map (Right . Just) [minBound .. maxBound]
            map
                (\name -> sourceOf <$> parseHookEvent (sessionStart name))
                (vocabulary Map.! "sources")
                `shouldBe` map (Right . Just) [minBound .. maxBound]

    describe "what a hook asks of the run" $ do
        it "resumes for the lead, and for an agent no flow knows" $
            map
                ( \agent ->
                    wants
                        steps
                        ResumeHook
                        (SessionStart (Call (Just (SessionId "s")) "/w" agent) (claudeOpened Startup))
                )
                [Nothing, Just (Agent Nothing (Just (AgentRole "engineer")))]
                `shouldBe` [ Right (Just (Asks (ResumeRun (claudeOpened Startup))))
                           , Right (Just (Asks (ResumeRun (claudeOpened Startup))))
                           ]

        it "ignores a subagent's spawn" $
            wants
                steps
                SpawnHook
                ( BeforeTool
                    (Call (Just (SessionId "s")) "/w" (Just reviewLead))
                    Delegate
                    KeyMap.empty
                )
                `shouldBe` Right Nothing

        it "reads the role the lead spawns" $
            wants
                steps
                SpawnHook
                ( BeforeTool
                    (Call (Just (SessionId "s")) "/w" Nothing)
                    Delegate
                    (KeyMap.fromList [("subagent_type", String "implementer")])
                )
                `shouldBe` Right (Just (Asks (SpawnRole (Just (AgentRole "implementer")))))

        it "records a step runner's hand-back, not a checker's or a child run's" $
            [ wants
                steps
                HandbackHook
                ( BeforeTool
                    (Call (Just (SessionId "s")) "/w" (Just agent))
                    HandbackTool
                    (message "READY")
                )
            | agent <-
                [ reviewLead
                , Agent (Just (AgentId "a2")) (Just (AgentRole "checker"))
                , Agent (Just (AgentId "a3")) (Just (AgentRole "engineer"))
                ]
            ]
                `shouldBe` [ Right (Just (Asks (HandedBack "READY" reviewLead (AgentRole "review-lead"))))
                           , Right Nothing
                           , Right Nothing
                           ]

        it
            "ends the stopping agent with the agents still running, the lead by its own key"
            $ [ wants
                    steps
                    StopHook
                    (AgentStop (Call (Just (SessionId "s")) "/w" (Just reviewLead)) [AgentId "a2"])
              , wants steps StopHook (AgentStop (Call (Just (SessionId "s")) "/w" Nothing) [])
              ]
                `shouldBe` [ Right (Just (Ends (Stops (AgentKey (AgentId "a2")) [AgentId "a2"])))
                           , Right (Just (Ends (Stops Main [])))
                           ]

        it "ends the agent a stop call names, and nothing at another tool" $
            [ wants
                steps
                StopHook
                ( AfterTool
                    (Call (Just (SessionId "s")) "/w" Nothing)
                    tool
                    (KeyMap.fromList [("task_id", String "c1")])
                    (object [])
                )
            | tool <- [StopAgent, Shell]
            ]
                `shouldBe` [Right (Just (Ends (StopsAgent (AgentId "c1")))), Right Nothing]

        it "refuses a hook at an event it is not declared on" $
            wants
                steps
                SpawnHook
                (SessionStart (Call (Just (SessionId "s")) "/w" Nothing) (claudeOpened Startup))
                `shouldBe` Left "state-hook spawn does not run at sessionStart"

    describe "what a call routes" $ do
        let shell agent tool command =
                wants
                    steps
                    RouteHook
                    ( BeforeTool
                        (Call (Just (SessionId "s")) "/w" agent)
                        tool
                        (KeyMap.fromList [("command", String command)])
                    )
        it "routes any agent's shell command" $
            map (\agent -> shell agent Shell "state next") [Nothing, Just reviewLead]
                `shouldBe` replicate 2 (Right (Just (Routes (RunsShell "state next"))))

        it "routes an edit, a write and a spawn, for the gate to weigh" $
            map (\tool -> shell Nothing tool "") [Edit, Write, Delegate]
                `shouldBe` map (Right . Just . Routes) [Edits Nothing, Writes Nothing, Spawns]

        it
            "routes an edit or write with its file, joined to the caller's directory when relative"
            $ [ wants
                    steps
                    RouteHook
                    ( BeforeTool
                        (Call (Just (SessionId "s")) "/w" Nothing)
                        tool
                        (KeyMap.fromList [("file_path", String file)])
                    )
              | (tool, file) <- [(Edit, "a/notes.md"), (Write, "/n/notes.md")]
              ]
                `shouldBe` map
                    (Right . Just . Routes)
                    [Edits (Just "/w/a/notes.md"), Writes (Just "/n/notes.md")]

        it "routes no read, research or other call" $
            map (\tool -> shell Nothing tool "state next") [Read, Web, Skill, Other]
                `shouldBe` replicate 4 (Right Nothing)

    describe "how work begins" $ do
        let startOf role =
                wants
                    steps
                    BeginHook
                    ( AgentStart
                        ( Call
                            (Just (SessionId "s"))
                            "/w"
                            (Just (Agent (Just (AgentId "a1")) (AgentRole <$> role)))
                        )
                    )
            called tool skill =
                wants
                    steps
                    BeginHook
                    ( BeforeTool
                        (Call (Just (SessionId "s")) "/w" Nothing)
                        tool
                        (KeyMap.fromList [("skill", String skill)])
                    )
        it "begins a spawned lead's run, and a step runner's brief" $
            map (startOf . Just) ["engineer", "10x", "implementer", "review-lead"]
                `shouldBe` map
                    (Right . Just . Begins)
                    [ SpawnedLead
                    , SpawnedLead
                    , SpawnedWorker (AgentRole "implementer")
                    , SpawnedWorker (AgentRole "review-lead")
                    ]

        it "says nothing to an agent the flows do not spawn, or one with no role" $
            map startOf [Just "checker", Just "Explore", Nothing]
                `shouldBe` replicate 3 (Right Nothing)

        it "begins the engineer's and the 10x's skills, typed or called" $
            [ wants
                steps
                BeginHook
                (PromptExpansion (Call (Just (SessionId "s")) "/w" Nothing) "engineer")
            , called Skill "10x-engineer"
            ]
                `shouldBe` [ Right (Just (Begins (TypedSkill EngineerSkill)))
                           , Right (Just (Begins (CalledSkill TenXSkill)))
                           ]

        it "says nothing at another skill, or another tool naming a lead skill" $
            [ wants
                steps
                BeginHook
                (PromptExpansion (Call (Just (SessionId "s")) "/w" Nothing) "qa")
            , called Skill "refactor"
            , called Shell "engineer"
            ]
                `shouldBe` replicate 3 (Right Nothing)

    describe "what a tool's result binds" $ do
        let ran command stdout =
                wants
                    steps
                    BindHook
                    ( AfterTool
                        (Call (Just (SessionId "s")) "/w" Nothing)
                        Shell
                        (KeyMap.fromList [("command", String command)])
                        (object ["stdout" .= (stdout :: Text), "stderr" .= ("" :: Text)])
                    )
            spawnedOf role =
                wants
                    steps
                    BindHook
                    ( AfterTool
                        (Call (Just (SessionId "s")) "/w" Nothing)
                        Delegate
                        (KeyMap.fromList [("subagent_type", String role)])
                        (object ["status" .= ("completed" :: Text), "agentId" .= ("c1" :: Text)])
                    )
        it "binds the caller to the run its state init printed" $
            ran "cd /wt && state init --notes /n" "started 0a1b2c3d\nrun 0a1b2c3d /n /wt\n"
                `shouldBe` Right (Just (Binds (BindSelf (Binding (runId "0a1b2c3d") "/n" "/wt"))))

        it
            "binds nothing off a command that ran no init, or an init that printed no run"
            $ [ran "cat log" "run 0a1b2c3d /n /wt\n", ran "state init --notes /n" ""]
                `shouldBe` [Right Nothing, Right Nothing]

        it "binds a worker spawned, not a lead nor an agent no flow knows" $
            map spawnedOf ["implementer", "engineer", "Explore"]
                `shouldBe` [ Right (Just (Binds (BindChild (AgentId "c1") (AgentRole "implementer"))))
                           , Right Nothing
                           , Right Nothing
                           ]

    describe "where a want goes" $ do
        let worker = AgentKey (AgentId "a2")
            slot = slotOf "/bindings" (SessionId "s") worker
            binding = Binding (runId "0a1b2c3d") "/n" "/wt"
            handedBack = HandedBack "READY" reviewLead (AgentRole "review-lead")
        it "stashes an unbound worker's hand-back in its slot" $
            case slot of
                Just at -> delivery handedBack worker slot Nothing `shouldBe` Stash at
                Nothing -> expectationFailure "no slot for the worker"

        it "sends a bound worker's hand-back, and the session's own agent's, to the run" $
            [ delivery handedBack worker slot (Just binding)
            , delivery handedBack Main slot Nothing
            ]
                `shouldBe` [ToRun, ToRun]

        it
            "sends an unbound worker's hand-back with no store to the run, which has none for it"
            $ delivery handedBack worker Nothing Nothing `shouldBe` ToRun

        it "never stashes a want that is no hand-back" $
            [ delivery want worker slot Nothing
            | want <- [ResumeRun (claudeOpened Startup), SpawnRole Nothing]
            ]
                `shouldBe` [ToRun, ToRun]

    describe "silence" $ do
        let drafted =
                stepTook
                    ( DraftDone
                        (DraftPr (Url "https://github.com/o/r/pull/1") (Branch "main") (Branch "feat"))
                    )
        it "speaks on a run at a step" $
            silent (Just (Branch "feat")) Nothing (logOf (started :| [])) (runAt [])
                `shouldBe` False

        it "is silent on a stopped run" $
            let stop = Stopped (Stop Blocked "no access")
             in silent (Just (Branch "feat")) Nothing (logOf (started :| [stop])) (runAt [stop])
                    `shouldBe` True

        it "is silent when HEAD is off the branch the draft PR bound the run to" $
            [ silent branch Nothing (logOf (started :| [drafted])) (runAt [])
            | branch <- [Just (Branch "feat"), Just (Branch "other"), Nothing]
            ]
                `shouldBe` [False, True, True]

        it "speaks off the branch of a voided draft PR" $
            silent
                (Just (Branch "other"))
                Nothing
                (logOf (started :| [drafted, Voided 1 "wrong branch"]))
                (runAt [])
                `shouldBe` False

        it "is silent once GitHub reports the drafted PR merged or closed" $
            [ silent
                (Just (Branch "feat"))
                (Just readiness)
                (logOf (started :| [drafted]))
                (runAt [])
            | readiness <- [IsDraft, IsReady, IsMerged, IsClosed]
            ]
                `shouldBe` [False, False, True, True]

        it "speaks before the run drafts, whatever an old PR on the branch says" $
            [ silent
                (Just (Branch "feat"))
                (Just readiness)
                (logOf (started :| []))
                (runAt [])
            | readiness <- [IsMerged, IsClosed]
            ]
                `shouldBe` [False, False]

    describe "a spawn off the advice" $ do
        let refactor = At (Place [] mempty (stepName Refactor))
            role = AgentRole
        it "warns on a flow role that is not the one advised" $
            offAdvice steps refactor (role "refactorer") (role "fixer")
                `shouldBe` Just "state: the advice is SPAWN refactorer, not fixer"

        it
            "takes the advised role, one spawned beside it, a later implementer slice and a role outside the flows"
            $ map
                (offAdvice steps refactor (role "refactorer") . role)
                ["refactorer", "reviewer", "checker", "implementer", "Explore"]
                `shouldBe` replicate 5 Nothing

    describe "hook record ids" $ do
        let ids =
                take 2
                    . hookSources
                        run
                        (Agent (Just (AgentId "a1")) (Just (AgentRole "fixer")))
                        (AgentRole "fixer")
        it "differ between hand-backs" $
            ids "READY" `shouldNotBe` ids "READY abc"

        it "differ between one call's records" $
            nub (ids "READY") `shouldBe` ids "READY"

    describe "a hand-back logged already" $ do
        let sources =
                hookSources
                    run
                    (Agent (Just (AgentId "a1")) (Just (AgentRole "fixer")))
                    (AgentRole "fixer")
                    "READY"
            -- The fixer's done, as the hook records it under its record's id.
            hooked n = case line 1 (stepTook (FixDone commit)) of
                Envelope _ seq' ts ofRun at session done -> Envelope (sources !! n) seq' ts ofRun at session done
            logWith = loggedAlready . (line 0 started :|)
        it "is the one whose first record the log holds" $
            logWith [hooked 0] sources `shouldBe` True

        it "is not one whose records the log lacks, or holds only past the first" $
            map (`logWith` sources) [[], [hooked 1]] `shouldBe` [False, False]

    describe "a session start" $ do
        let atWork = tenXAt (plainTask "t1" [] :| []) [Spawned (childOf "c1" "t1")]
        it "records a restart when a fresh or resumed session lost an agent at work" $
            map (`restartOf` atWork) [Startup, Resumed]
                `shouldBe` [Just Restarted, Just Restarted]

        it "records nothing after a compaction, which keeps the agents" $
            restartOf Compact atWork `shouldBe` Nothing

        it "records a restart when the lead lost a worker at work" $
            restartOf Startup (runAt [WorkerSpawned (AgentRole "fixer") (AgentId "a1")])
                `shouldBe` Just Restarted

        it "records nothing on a run with no agent at work" $
            map (`restartOf` runAt []) [Startup, Resumed] `shouldBe` [Nothing, Nothing]

    describe "the reply" $ do
        it "names the run a hook's text is about, and says nothing for nothing" $
            map
                (aboutRun (runId "0a1b2c3d"))
                ["state: recorded 9 implement.done -> refactor\n", ""]
                `shouldBe` ["run 0a1b2c3d: state: recorded 9 implement.done -> refactor\n", ""]

        it "names a run when one is known, and none before" $
            [ aboutKnown run' "state hook resume: gone\n"
            | run' <- [Just (runId "0a1b2c3d"), Nothing]
            ]
                `shouldBe` ["run 0a1b2c3d: state hook resume: gone\n", "state hook resume: gone\n"]

        it "prints nothing with nothing to say" $
            encodeReply (replyOf (Asks (ResumeRun (claudeOpened Startup))) "")
                `shouldBe` Nothing

        it "tells what a hand-back recorded as context, never rewriting the call" $
            decoded
                ( replyOf
                    (Asks (HandedBack "READY" reviewLead (AgentRole "review-lead")))
                    "state: recorded 9 review.rows -> pick\n"
                )
                `shouldBe` Right
                    ( object
                        [ "decision" .= ("allow" :: Text)
                        , "context" .= ("state: recorded 9 review.rows -> pick\n" :: Text)
                        ]
                    )

        it "never denies: a spawn's error is context" $
            decoded (toldOf (Asks (SpawnRole Nothing)) "state hook spawn: disk full")
                `shouldBe` Right
                    ( object
                        [ "decision" .= ("allow" :: Text)
                        , "context" .= ("state hook spawn: disk full" :: Text)
                        ]
                    )

        it "denies a routed call, with why" $
            decoded (Deny "state next: the run at /a is not this agent's")
                `shouldBe` Right
                    ( object
                        [ "decision" .= ("deny" :: Text)
                        , "reason" .= ("state next: the run at /a is not this agent's" :: Text)
                        ]
                    )

        it
            "gives a spawned agent's and a typed skill's begin context alone, a called skill's beside the call"
            $ map
                (\begin -> decoded (replyOf (Begins begin) "state: begins"))
                [SpawnedLead, TypedSkill EngineerSkill, CalledSkill EngineerSkill]
                `shouldBe` [ Right (object ["context" .= ("state: begins" :: Text)])
                           , Right (object ["context" .= ("state: begins" :: Text)])
                           , Right
                                (object ["decision" .= ("allow" :: Text), "context" .= ("state: begins" :: Text)])
                           ]

        it "gives sessionStart and afterTool context alone" $
            map
                (\job -> decoded (replyOf job "state: noted"))
                [ Asks (ResumeRun (claudeOpened Startup))
                , Binds (BindChild (AgentId "a1") (AgentRole "researcher"))
                ]
                `shouldBe` replicate 2 (Right (object ["context" .= ("state: noted" :: Text)]))
  where
    decoded reply =
        maybe (Left "nothing printed") eitherDecode (encodeReply reply) ::
            Either String Value

fixer, reviewLeadJson :: Value
fixer = object ["id" .= ("a1" :: Text), "role" .= ("fixer" :: Text)]
reviewLeadJson = object ["id" .= ("a2" :: Text), "role" .= ("review-lead" :: Text)]

reviewLead :: Agent
reviewLead = Agent (Just (AgentId "a2")) (Just (AgentRole "review-lead"))

message :: Text -> Object
message text = KeyMap.fromList [("message", String text)]

-- | The lead's Claude Code session starting for this reason.
sessionStart :: Text -> LBS.ByteString
sessionStart source =
    encodeObject
        ( common Null
            <> KeyMap.fromList
                [ ("event", "sessionStart")
                , ("source", String source)
                , ("harness", "claude-code")
                , ("transcript_path", String (Text.pack transcriptFile))
                , ("request_model", "claude-opus-5-5")
                ]
        )

-- | What 'sessionStart' tells, for this reason.
claudeOpened :: StartSource -> Opened
claudeOpened source = Opened source "claude-code" (absPath transcriptFile) (Just "claude-opus-5-5")

transcriptFile :: FilePath
transcriptFile = "/home/u/.claude/projects/p/s.jsonl"

beforeTool :: Text -> Value -> Value -> LBS.ByteString
beforeTool tool agent input =
    encodeObject
        ( common agent
            <> KeyMap.fromList
                [ ("event", "beforeTool")
                , ("tool", String tool)
                , ("input", input)
                , ("history", Array mempty)
                ]
        )

afterToolFields :: Text -> Object
afterToolFields tool =
    common reviewLeadJson
        <> KeyMap.fromList
            [ ("event", "afterTool")
            , ("tool", String tool)
            , ("input", object [])
            , ("output", String "ok")
            , ("context", Null)
            ]

-- | A whole event of this name, as a backend sends it.
event :: Text -> LBS.ByteString
event = \case
    "sessionStart" -> sessionStart "startup"
    "beforeTool" -> beforeTool "shell" Null (object [])
    "agentStart" -> agentStart "implementer"
    "promptExpansion" -> promptExpansion "engineer"
    "agentStop" -> agentStop fixer ["a1"]
    _ -> encodeObject (afterToolFields "shell")

-- | This agent stopping, these agents running.
agentStop :: Value -> [Text] -> LBS.ByteString
agentStop agent running =
    encodeObject
        ( common agent
            <> KeyMap.fromList [("event", "agentStop"), ("running", toJSON running)]
        )

-- | A subagent of this role starting.
agentStart :: Text -> LBS.ByteString
agentStart role =
    encodeObject
        ( common (object ["id" .= ("a1" :: Text), "role" .= role])
            <> KeyMap.fromList [("event", "agentStart")]
        )

-- | The lead's typed @/<skill>@ expanding.
promptExpansion :: Text -> LBS.ByteString
promptExpansion skill =
    encodeObject
        ( common Null
            <> KeyMap.fromList [("event", "promptExpansion"), ("skill", String skill)]
        )

common :: Value -> Object
common agent = KeyMap.fromList [("session", "s"), ("cwd", "/w"), ("agent", agent)]

withField :: Text -> Text -> LBS.ByteString -> LBS.ByteString
withField key value = edited (KeyMap.insert (Key.fromText key) (String value))

withNull :: Text -> LBS.ByteString -> LBS.ByteString
withNull key = edited (KeyMap.insert (Key.fromText key) Null)

without :: Text -> LBS.ByteString -> LBS.ByteString
without key = edited (KeyMap.delete (Key.fromText key))

edited :: (Object -> Object) -> LBS.ByteString -> LBS.ByteString
edited change raw = case eitherDecode raw of
    Right (Object o) -> encodeObject (change o)
    _ -> raw

encodeObject :: Object -> LBS.ByteString
encodeObject = encode . Object

eventOf :: HookEvent -> Text
eventOf = \case
    SessionStart _ _ -> "sessionStart"
    BeforeTool {} -> "beforeTool"
    AfterTool {} -> "afterTool"
    AgentStart _ -> "agentStart"
    PromptExpansion _ _ -> "promptExpansion"
    AgentStop _ _ -> "agentStop"

toolOf :: HookEvent -> Maybe Tool
toolOf = \case
    BeforeTool _ tool _ -> Just tool
    AfterTool _ tool _ _ -> Just tool
    SessionStart _ _ -> Nothing
    AgentStart _ -> Nothing
    PromptExpansion _ _ -> Nothing
    AgentStop _ _ -> Nothing

sourceOf :: HookEvent -> Maybe StartSource
sourceOf = \case
    SessionStart _ opened -> Just opened.source
    BeforeTool {} -> Nothing
    AfterTool {} -> Nothing
    AgentStart _ -> Nothing
    PromptExpansion _ _ -> Nothing
    AgentStop _ _ -> Nothing

-- | @vocabulary.json@: each list of names.
type Vocabulary = Map Text [Text]
