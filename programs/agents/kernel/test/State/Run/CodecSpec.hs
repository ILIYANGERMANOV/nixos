module State.Run.CodecSpec (spec) where

import Data.Aeson (Value, encode, withObject, (.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.Entity.Event (EventRow (..))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Payload.Event (Decoded (..), decodeRow, dumpLine, eventRow)
import Data.Payload.Upcast (shipped)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Lazy qualified as Lazy
import Data.Text.Lazy.Encoding qualified as Lazy
import Data.Time (UTCTime (..))
import Data.Time.Calendar (fromGregorian)
import Hedgehog (forAll, tripping)
import State.Category.Flow (scopePath)
import State.Run.Ask (Basis (..), Proposal (..), QId (..))
import State.Run.Codec (decodeBreakdown, decodeTask)
import State.Run.Event (
    Branch (..),
    ChildTask (..),
    Envelope (..),
    Event (..),
    EventId (..),
    FlowName (..),
    Judgement (..),
    Label (..),
    Link (..),
    Parent (..),
    Picks (..),
    PlanCall (..),
    Principal (..),
    Repo (..),
    Requirement (..),
    Said (..),
    Sha (..),
    Shape (..),
    Source (..),
    Start (..),
    Stop (..),
    StopReason (..),
    Target (..),
    Task (..),
    TaskId (..),
    Url (..),
    Waiting (..),
    stepTook,
    taskList,
    tookIn,
 )
import State.Run.EventGen (genEnvelope, oneLine, runId, tasksOf)
import State.Run.RunGen (
    breakdownJson,
    pickOf,
    plainTask,
    roundTask,
    securityScope,
    taskFileJson,
 )
import State.Step.Artifact (shellPath)
import State.Step.Artifact qualified as Artifact (Task (..))
import State.Step.Catalog (outcome)
import State.Step.Fan (Outcome (..), engineers)
import State.Step.Request (Outcome (..))
import State.Step.Review (Outcome (..))
import State.Step.Ticket (Outcome (..))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Run.Codec" $ do
    it "codec_round_trips" . hedgehog $ do
        envelope <- forAll genEnvelope
        tripping envelope encodeLine decodeLine

    it "dumps the row #360 documents, its columns in the table's order" $
        encodeLine reviewRows
            `shouldBe` "{\"run_id\":\"r7f2\",\"seq\":12,\"schema_version\":1,\"type\":\"review.rows\",\"time\":\"2026-11-12T10:00:00.000Z\",\"session_id\":null,\"head_sha\":\"0123456789abcdef0123456789abcdef01234567\",\"hook_digest\":null,\"data\":{\"head_sha\":\"abc123\"}}"

    it "reads a row of run h, whose CLI ids read as hook ids, as unknown" $
        decodeLine
            (encodeLine reviewRows `replacing` ("\"run_id\":\"r7f2\"", "\"run_id\":\"h\""))
            `shouldSatisfy` malformed

    it "refuses a parent run h" $
        decodeLine
            ( encodeLine parentRun
                `replacing` ("\"run\":\"r7f2\",\"link\"", "\"run\":\"h\",\"link\"")
            )
            `shouldSatisfy` malformed

    it "refuses an unknown event type" $
        decodeLine (encodeLine reviewRows `replacing` ("review.rows", "review.maybe"))
            `shouldSatisfy` malformed

    it "reads a step's outcome inside a scope under its qualified type" $
        decodeLine
            ( encodeLine reviewRows
                `replacing` ("\"type\":\"review.rows\"", "\"type\":\"security/review.rows\"")
            )
            `shouldBe` Right reviewRows {event = tookIn securityScope (ReviewRows (Sha "abc123"))}

    it "reads a choice's enough inside a scope under its qualified type" $
        decodeLine
            ( encodeLine reviewRows {event = Took mempty (pickOf "gather" "enough")}
                `replacing` ("\"type\":\"gather.enough\"", "\"type\":\"x/gather.enough\"")
            )
            `shouldBe` Right reviewRows {event = Took (scopePath "x") (pickOf "gather" "enough")}

    it
        "writes and reads the chief's picks by their route's and branch's names, a block's inside the blocks' route"
        $ do
            let picks =
                    [ reviewRows {event = Took mempty (pickOf "route" "engineer")}
                    , reviewRows {event = Took mempty (pickOf "block" "shipping")}
                    ]
            and
                ( zipWith
                    Text.isInfixOf
                    ["\"type\":\"route.engineer\"", "\"type\":\"block.shipping\""]
                    (map encodeLine picks)
                )
                `shouldBe` True
            map (fmap (.event) . decodeLine . encodeLine) picks
                `shouldBe` map (Right . (.event)) picks

    it "writes and reads a request's outcomes with what each carries" $ do
        let recorded =
                map
                    (\o -> reviewRows {event = Took (scopePath "shipping") o})
                    [ outcome (OpenPrDone (Url "https://github.com/o/r/pull/7"))
                    , outcome (OpenPlanDone (Url "https://github.com/o/r/issues/3"))
                    , outcome (OpenBranchDone (Branch "feature"))
                    , outcome (DirectDone "renamed the README's title")
                    , outcome NextRequest
                    , outcome NextDone
                    ]
        map (fmap (.event) . decodeLine . encodeLine) recorded
            `shouldBe` map (Right . (.event)) recorded

    it "writes a request's target as one key, its kind, holding its url or branch" $ do
        let targets =
                [ OnPr (Url "https://github.com/o/r/pull/7")
                , OnBranch (Branch "feature")
                , OnTicket (Url "https://github.com/o/r/issues/3")
                ]
            lines' = map (\target -> encodeLine reviewRows {event = Targeted target}) targets
        and
            ( zipWith
                Text.isInfixOf
                [ "\"data\":{\"pr\":\"https://github.com/o/r/pull/7\"}"
                , "\"data\":{\"branch\":\"feature\"}"
                , "\"data\":{\"ticket\":\"https://github.com/o/r/issues/3\"}"
                ]
                lines'
            )
            `shouldBe` True
        map (fmap (.event) . decodeLine) lines'
            `shouldBe` map (Right . Targeted) targets

    it "refuses a run's event inside a scope: only a step's outcome is named so" $
        decodeLine
            ( encodeLine reviewRows {event = Extended "why"}
                `replacing` ("\"type\":\"extend\"", "\"type\":\"security/extend\"")
            )
            `shouldSatisfy` malformed

    it "refuses a red CI result with no failing check" $
        decodeLine
            ( encodeLine reviewRows
                `replacing` ("review.rows", "await_ci.red")
                `replacing` ("{\"head_sha\":\"abc123\"}", "{\"head_sha\":\"abc123\",\"failing\":[]}")
            )
            `shouldSatisfy` malformed

    it "refuses picks naming a row twice" $
        decodeLine
            (encodeLine picked `replacing` ("\"rows\":[\"A\"]", "\"rows\":[\"A\",\"A\"]"))
            `shouldSatisfy` malformed

    it "writes a ruling's answer, reason, cost and basis under the question's id" $
        encodeLine
            reviewRows
                { event =
                    RuledOn
                        (QId (runId "c1") 3)
                        ( Proposal
                            (oneLine "v2")
                            (oneLine "the docs say so")
                            (oneLine "an hour")
                            (Just (AnsweredBy (Numbered (runId "r7f2") 4)))
                        )
                }
            `shouldBe` "{\"run_id\":\"r7f2\",\"seq\":12,\"schema_version\":1,\"type\":\"ruled\",\"time\":\"2026-11-12T10:00:00.000Z\",\"session_id\":null,\"head_sha\":\"0123456789abcdef0123456789abcdef01234567\",\"hook_digest\":null,\"data\":{\"qid\":\"c1:3\",\"answer\":\"v2\",\"reason\":\"the docs say so\",\"cost\":\"an hour\",\"basis\":{\"kind\":\"event\",\"event\":\"r7f2:4\"}}}"

    it "writes a void as the seq of the line it voids, and its reason" $
        encodeLine reviewRows {event = Voided 7 "logged in the wrong run"}
            `shouldSatisfy` Text.isInfixOf
                "\"data\":{\"seq\":7,\"reason\":\"logged in the wrong run\"}"

    it "reads a voided seq under 2^53, and one at 2^53 as unknown (I-JSON)" $
        [ (.event)
            <$> decodeLine
                ( encodeLine reviewRows {event = Voided 7 "r"}
                    `replacing` ("\"seq\":7", "\"seq\":" <> Text.pack (show n))
                )
        | n <- [2 ^ (53 :: Int) - 1, 2 ^ (53 :: Int) :: Integer]
        ]
            `shouldSatisfy` \case
                [Right (Voided 9007199254740991 "r"), unread] -> malformed unread
                _ -> False

    it "refuses a ruling whose answer breaks the line" $
        decodeLine
            ( encodeLine
                reviewRows
                    { event =
                        RuledOn
                            (QId (runId "c1") 3)
                            (Proposal (oneLine "v2") (oneLine "why") (oneLine "cost") Nothing)
                    }
                `replacing` ("\"answer\":\"v2\"", "\"answer\":\"v2\\nREADY\"")
            )
            `shouldSatisfy` malformed

    it "writes a child's stop as ended, with the stop's reason and detail" $
        encodeLine
            reviewRows {event = HandedBack (runId "c1") (Ended (Stop Blocked "no access"))}
            `shouldSatisfy` Text.isInfixOf
                "\"data\":{\"child\":\"c1\",\"kind\":\"ended\",\"reason\":\"blocked\",\"detail\":\"no access\"}"

    it "writes a child's AWAIT with what it awaits, ci or merge" $
        [ encodeLine
            reviewRows
                { event = HandedBack (runId "c1") (Awaits on (oneLine "https://pr/1"))
                }
        | on <- [Ci, Merge]
        ]
            `shouldSatisfy` \case
                [ci, merge] ->
                    "\"data\":{\"child\":\"c1\",\"kind\":\"awaits\",\"on\":\"ci\",\"summary\":\"https://pr/1\"}"
                        `Text.isInfixOf` ci
                        && "\"kind\":\"awaits\",\"on\":\"merge\"," `Text.isInfixOf` merge
                _ -> False

    it
        "writes the user as a principal tagged user, its PR's shape tagged by its kind"
        $ [ encodeLine
                reviewRows {event = Started (Start EngineerFlow "/n" (ByUser shape) Set.empty)}
          | shape <- [OwnPr, RoundOn (Url "https://github.com/o/r/pull/7")]
          ]
            `shouldSatisfy` \case
                [own, round'] ->
                    "\"principal\":{\"kind\":\"user\",\"shape\":{\"kind\":\"own_pr\"}}"
                        `Text.isInfixOf` own
                        && "\"principal\":{\"kind\":\"user\",\"shape\":{\"kind\":\"round_on\",\"pr_url\":\"https://github.com/o/r/pull/7\"}}"
                            `Text.isInfixOf` round'
                _ -> False

    it
        "writes the caller as a principal tagged caller, its PR's shape tagged by its kind"
        $ [ encodeLine
                reviewRows
                    { event = Started (Start EngineerFlow "/n" (ByCaller shape) Set.empty)
                    }
          | shape <- [OwnPr, RoundOn (Url "https://github.com/o/r/pull/7")]
          ]
            `shouldSatisfy` \case
                [own, round'] ->
                    "\"principal\":{\"kind\":\"caller\",\"shape\":{\"kind\":\"own_pr\"}}"
                        `Text.isInfixOf` own
                        && "\"principal\":{\"kind\":\"caller\",\"shape\":{\"kind\":\"round_on\",\"pr_url\":\"https://github.com/o/r/pull/7\"}}"
                            `Text.isInfixOf` round'
                _ -> False

    it "refuses an AWAIT that names nothing it awaits" $
        decodeLine
            ( encodeLine
                reviewRows
                    { event = HandedBack (runId "c1") (Awaits Merge (oneLine "https://pr/1"))
                    }
                `replacing` (",\"on\":\"merge\"", "")
            )
            `shouldSatisfy` malformed

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
        "writes no repo, worktree or flow key for an engineer's task the breakdown places nowhere"
        $ encodeLine
            reviewRows
                { event = stepTook (BreakdownDone engineers (tasksOf (plainTask "t1" [] :| [])))
                }
            `shouldSatisfy` ( \line -> not (any (`Text.isInfixOf` line) ["\"repo\"", "\"worktree\"", "\"flow\""])
                            )

    it
        "reads a task's flow, an engineer's where the task names none, as a breakdown older than flows"
        $ map (fmap (.flow) . decodeTask . taskFileJson) [ledBy10x, plainTask "t1" []]
            `shouldBe` [Right TenXFlow, Right EngineerFlow]

    it "writes a 10x task's flow under the key a breakdown names it by" $
        encodeLine
            reviewRows
                { event = stepTook (BreakdownDone engineers (tasksOf (ledBy10x :| [])))
                }
            `shouldSatisfy` Text.isInfixOf "\"flow\":\"10x\""

    it
        "writes and reads an architect run's start by its flow's name, and its ticket by its url"
        $ do
            let architectStart =
                    reviewRows {event = Started (Start ArchitectFlow "/n" (ByUser OwnPr) Set.empty)}
                confirmed =
                    reviewRows
                        { event = stepTook (TicketWritten (Url "https://github.com/o/r/issues/1"))
                        }
            (encodeLine architectStart, encodeLine confirmed) `shouldSatisfy` \(start, ticket) ->
                "\"flow\":\"architect\"" `Text.isInfixOf` start
                    && "\"url\":\"https://github.com/o/r/issues/1\"" `Text.isInfixOf` ticket
            map (fmap (.event) . decodeLine . encodeLine) [architectStart, confirmed]
                `shouldBe` map (Right . (.event)) [architectStart, confirmed]

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

    it "refuses a retag to any kind but security" $
        decodeLine
            ( encodeLine reviewRows {event = RetaggedSecurity (QId (runId "c1") 3)}
                `replacing` ("\"question_kind\":\"security\"", "\"question_kind\":\"design\"")
            )
            `shouldSatisfy` malformed

    it "refuses picks judging a requirement twice" $
        decodeLine
            ( encodeLine picked
                `replacing` (metR1, metR1 <> ",{\"requirement\":\"R1\",\"outcome\":\"not_met\"}")
            )
            `shouldSatisfy` malformed

-- | #360's example line.
reviewRows :: Envelope
reviewRows =
    Envelope
        { source = Cli
        , seq = 12
        , ts = UTCTime (fromGregorian 2026 11 12) 36000
        , run = runId "r7f2"
        , head = Just (Sha "0123456789abcdef0123456789abcdef01234567")
        , session = Nothing
        , event = stepTook (ReviewRows (Sha "abc123"))
        }

-- | Picks of row A, with R1 met.
picked :: Envelope
picked =
    reviewRows
        { event =
            stepTook
                ( PickLoop
                    (Picks (Set.singleton (Label "A")) (Map.singleton (Requirement "R1") Met))
                )
        }

metR1 :: Text
metR1 = "{\"requirement\":\"R1\",\"outcome\":\"met\"}"

-- | A started line naming parent run r7f2.
parentRun :: Envelope
parentRun =
    reviewRows
        { event =
            Started
                ( Start
                    EngineerFlow
                    "notes"
                    ( ByRole
                        (Parent (runId "r7f2") (InFan (Tasked (TaskId "t1"))))
                        OwnPr
                        ChildConfirms
                    )
                    mempty
                )
        }

{- | Errors when @old@ is absent, so a stale pattern fails its test instead of
quietly checking the unchanged line.
-}
replacing :: Text -> (Text, Text) -> Text
replacing whole (old, new)
    | old `Text.isInfixOf` whole = Text.replace old new whole
    | otherwise = error ("replacing: " <> show old <> " is not in " <> show whole)

-- | An envelope's row as @state dump@ prints it.
encodeLine :: Envelope -> Text
encodeLine = dumpLine . eventRow

-- | A dumped row read back: its envelope, or the row this kernel does not read.
decodeLine :: Text -> Either Decoded Envelope
decodeLine raw =
    either (error . ("not a dumped row: " <>)) known $
        Aeson.eitherDecodeStrictText raw >>= parseEither (withObject "row" rowOf)
  where
    rowOf o =
        EventRow
            <$> o .: "run_id"
            <*> o .: "seq"
            <*> o .: "schema_version"
            <*> o .: "type"
            <*> o .: "time"
            <*> o .: "session_id"
            <*> o .: "head_sha"
            <*> o .: "hook_digest"
            <*> (payloadOf <$> o .: "data")
    payloadOf :: Value -> Text
    payloadOf = Lazy.toStrict . Lazy.decodeUtf8 . encode
    known row = case decodeRow shipped row of
        Known e -> Right e
        other -> Left other

malformed :: Either Decoded a -> Bool
malformed = \case
    Left (Unknown _) -> True
    Left (Retired _) -> False
    Left (Known _) -> False
    Right _ -> False

-- | A task whose child runs the 10x flow.
ledBy10x :: Task
ledBy10x = (plainTask "t1" []) {Artifact.flow = TenXFlow}

-- | A task whose breakdown names its repo and worktree.
placed :: Task
placed = (plainTask "t1" []) {repo = Just (Repo "o" "r"), worktree = shellPath "/wt"}
