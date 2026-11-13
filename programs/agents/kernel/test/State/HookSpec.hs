module State.HookSpec (spec) where

import Data.Aeson (Object, Value (..), eitherDecode, eitherDecodeFileStrict, encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import State.Advice (Readiness (..))
import State.Cap (stepName)
import State.Cap qualified as Cap
import State.Event (AgentRole (..), Branch (..), DraftPr (..), Envelope (..), Event (..), Outcome (..), Stop (..), StopReason (..), Url (..))
import State.EventGen (line, logOf, run, started)
import State.Graph (Node (..), Place (..))
import State.Hook
import State.RunGen (commit, loadSteps, runAt)
import System.Environment (getEnv)
import Test.Hspec (Spec, describe, it, runIO, shouldBe, shouldNotBe, shouldSatisfy)

spec :: Spec
spec = describe "the hooks" $ do
    steps <- runIO loadSteps
    vocabulary <- runIO (either fail pure =<< eitherDecodeFileStrict @Vocabulary =<< getEnv "HOOK_VOCABULARY")

    describe "reading an event" $ do
        it "reads a subagent's hand-back, its agent and its input" $
            parseHookEvent (beforeTool "handback" fixer (object ["message" .= ("READY" :: Text)]))
                `shouldBe` Right (BeforeTool (Call "s" "/w" (Just (Agent (Just "a1") (Just (AgentRole "fixer"))))) HandbackTool (message "READY"))

        it "reads the lead, whose agent is null" $
            parseHookEvent (sessionStart "startup") `shouldBe` Right (SessionStart (Call "s" "/w" Nothing) Startup)

        it "refuses an unknown event, tool or source" $
            map parseHookEvent [withField "event" "teardown" (sessionStart "startup"), beforeTool "teleport" Null (object []), sessionStart "reboot"]
                `shouldSatisfy` all isLeft

        it "refuses an afterTool with no output, as the contract requires one" $
            parseHookEvent (encodeObject (KeyMap.delete "output" (afterToolFields "ask"))) `shouldSatisfy` isLeft

        it "names the events, tools and sources of vocabulary.json, in its order" $ do
            map (\name -> eventOf <$> parseHookEvent (event name)) (vocabulary Map.! "events") `shouldBe` map Right ["sessionStart", "beforeTool", "afterTool"]
            map (\name -> toolOf <$> parseHookEvent (beforeTool name Null (object []))) (vocabulary Map.! "tools") `shouldBe` map (Right . Just) [minBound .. maxBound]
            map (\name -> sourceOf <$> parseHookEvent (sessionStart name)) (vocabulary Map.! "sources") `shouldBe` map (Right . Just) [minBound .. maxBound]

    describe "what a hook asks of the run" $ do
        it "resumes for the lead, and for an agent no flow knows" $
            map (\agent -> wants steps ResumeHook (SessionStart (Call "s" "/w" agent) Startup)) [Nothing, Just (Agent Nothing (Just (AgentRole "engineer")))]
                `shouldBe` [Right (Just ResumeRun), Right (Just ResumeRun)]

        it "ignores a subagent's spawn and question" $
            [ wants steps SpawnHook (BeforeTool (Call "s" "/w" (Just reviewLead)) Delegate KeyMap.empty)
            , wants steps AskedHook (AfterTool (Call "s" "/w" (Just reviewLead)) Ask)
            ]
                `shouldBe` [Right Nothing, Right Nothing]

        it "reads the role the lead spawns" $
            wants steps SpawnHook (BeforeTool (Call "s" "/w" Nothing) Delegate (KeyMap.fromList [("subagent_type", String "implementer")]))
                `shouldBe` Right (Just (SpawnRole (Just (AgentRole "implementer"))))

        it "records a step runner's hand-back, not a reviewer's" $
            [ wants steps HandbackHook (BeforeTool (Call "s" "/w" (Just agent)) HandbackTool (message "READY"))
            | agent <- [reviewLead, Agent (Just "a2") (Just (AgentRole "reviewer"))]
            ]
                `shouldBe` [Right (Just (HandedBack (message "READY") "READY" reviewLead (AgentRole "review-lead"))), Right Nothing]

        it "refuses a hook at an event it is not declared on" $
            wants steps SpawnHook (SessionStart (Call "s" "/w" Nothing) Startup) `shouldBe` Left "state-hook spawn does not run at sessionStart"

    describe "silence" $ do
        let drafted = Took (DraftDone (DraftPr (Url "https://github.com/o/r/pull/1") (Branch "main") (Branch "feat")))
        it "speaks on a run at a step" $
            silent (Just (Branch "feat")) Nothing (logOf (started :| [])) (runAt []) `shouldBe` False

        it "is silent on a stopped run" $
            let stop = Stopped (Stop Blocked "no access")
             in silent (Just (Branch "feat")) Nothing (logOf (started :| [stop])) (runAt [stop]) `shouldBe` True

        it "is silent when HEAD is off the branch the draft PR bound the run to" $
            [silent branch Nothing (logOf (started :| [drafted])) (runAt []) | branch <- [Just (Branch "feat"), Just (Branch "other"), Nothing]]
                `shouldBe` [False, True, True]

        it "is silent once GitHub reports the drafted PR merged or closed" $
            [silent (Just (Branch "feat")) (Just readiness) (logOf (started :| [drafted])) (runAt []) | readiness <- [IsDraft, IsReady, IsMerged, IsClosed]]
                `shouldBe` [False, False, True, True]

        it "speaks before the run drafts, whatever an old PR on the branch says" $
            [silent (Just (Branch "feat")) (Just readiness) (logOf (started :| [])) (runAt []) | readiness <- [IsMerged, IsClosed]]
                `shouldBe` [False, False]

    describe "a spawn off the advice" $ do
        let refactor = At (Place [] (stepName Cap.Refactor))
            role = AgentRole
        it "warns on a flow role that is not the one advised" $
            offAdvice steps refactor (role "refactorer") (role "fixer") `shouldBe` Just "state: the advice is SPAWN refactorer, not fixer"

        it "takes the advised role, one spawned beside it, a later implementer slice and a role outside the flows" $
            map (offAdvice steps refactor (role "refactorer") . role) ["refactorer", "reviewer", "checker", "implementer", "Explore"]
                `shouldBe` replicate 5 Nothing

    describe "hook record ids" $ do
        let ids = take 2 . hookSources run (Agent (Just "a1") (Just (AgentRole "fixer"))) (AgentRole "fixer")
        it "are the same for the same hand-back seen twice" $
            ids "READY" `shouldBe` ids "READY"

        it "differ between hand-backs" $
            ids "READY" `shouldNotBe` ids "READY abc"

        it "differ between one call's records" $
            nub (ids "READY") `shouldBe` ids "READY"

    describe "a hand-back logged already" $ do
        let sources = hookSources run (Agent (Just "a1") (Just (AgentRole "fixer"))) (AgentRole "fixer") "READY"
            -- The fixer's done, as the hook records it under its record's id.
            hooked n = case line 1 (Took (FixDone commit)) of
                Envelope _ seq' ts ofRun at session done -> Envelope (sources !! n) seq' ts ofRun at session done
            logWith = loggedAlready . (line 0 started :|)
        it "is the one whose first record the log holds" $
            logWith [hooked 0] sources `shouldBe` True

        it "is not one whose records the log lacks, or holds only past the first" $
            map (\more -> logWith more sources) [[], [hooked 1]] `shouldBe` [False, False]

    describe "the reply" $ do
        it "prints nothing with nothing to say" $
            encodeReply (replyOf ResumeRun "") `shouldBe` Nothing

        it "appends what a hand-back recorded to its message" $
            decoded (replyOf (HandedBack (message "READY") "READY" reviewLead (AgentRole "review-lead")) "state: recorded 9 review.rows -> pick\n")
                `shouldBe` Right (object ["decision" .= ("allow" :: Text), "updatedInput" .= message "READY\n\nstate: recorded 9 review.rows -> pick\n"])

        it "never denies: a spawn's error is context" $
            decoded (toldOf (SpawnRole Nothing) "state hook spawn: disk full") `shouldBe` Right (object ["decision" .= ("allow" :: Text), "context" .= ("state hook spawn: disk full" :: Text)])

        it "gives sessionStart and afterTool context alone" $
            decoded (replyOf AskedUser "state: record the user's answer") `shouldBe` Right (object ["context" .= ("state: record the user's answer" :: Text)])
  where
    decoded reply = maybe (Left "nothing printed") eitherDecode (encodeReply reply) :: Either String Value

fixer, reviewLeadJson :: Value
fixer = object ["id" .= ("a1" :: Text), "role" .= ("fixer" :: Text)]
reviewLeadJson = object ["id" .= ("a2" :: Text), "role" .= ("review-lead" :: Text)]

reviewLead :: Agent
reviewLead = Agent (Just "a2") (Just (AgentRole "review-lead"))

message :: Text -> Object
message text = KeyMap.fromList [("message", String text)]

sessionStart :: Text -> LBS.ByteString
sessionStart source = encodeObject (common Null <> KeyMap.fromList [("event", "sessionStart"), ("source", String source)])

beforeTool :: Text -> Value -> Value -> LBS.ByteString
beforeTool tool agent input =
    encodeObject (common agent <> KeyMap.fromList [("event", "beforeTool"), ("tool", String tool), ("input", input), ("history", Array mempty)])

afterToolFields :: Text -> Object
afterToolFields tool =
    common reviewLeadJson <> KeyMap.fromList [("event", "afterTool"), ("tool", String tool), ("input", object []), ("output", String "ok"), ("context", Null)]

-- | A whole event of this name, as a backend sends it.
event :: Text -> LBS.ByteString
event = \case
    "sessionStart" -> sessionStart "startup"
    "beforeTool" -> beforeTool "shell" Null (object [])
    _ -> encodeObject (afterToolFields "shell")

common :: Value -> Object
common agent = KeyMap.fromList [("session", "s"), ("cwd", "/w"), ("agent", agent)]

withField :: Text -> Text -> LBS.ByteString -> LBS.ByteString
withField key value raw = case eitherDecode raw of
    Right (Object o) -> encodeObject (KeyMap.insert (Key.fromText key) (String value) o)
    _ -> raw

encodeObject :: Object -> LBS.ByteString
encodeObject = encode . Object

eventOf :: HookEvent -> Text
eventOf = \case
    SessionStart _ _ -> "sessionStart"
    BeforeTool {} -> "beforeTool"
    AfterTool _ _ -> "afterTool"

toolOf :: HookEvent -> Maybe Tool
toolOf = \case
    BeforeTool _ tool _ -> Just tool
    AfterTool _ tool -> Just tool
    SessionStart _ _ -> Nothing

sourceOf :: HookEvent -> Maybe StartSource
sourceOf = \case
    SessionStart _ source -> Just source
    BeforeTool {} -> Nothing
    AfterTool _ _ -> Nothing

-- | @vocabulary.json@: each list of names.
type Vocabulary = Map Text [Text]
