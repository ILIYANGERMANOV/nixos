module State.AskSpec (spec) where

import Data.Maybe (isJust)
import Data.Text qualified as Text
import Hedgehog (Gen, PropertyT, assert, cover, forAll, tripping, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Ask
import State.EventGen (genOneLine, genProposal, genQId, genQuestion, genReading, oneLine, runId)
import State.Id (TaskId (..), breaksLine)
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Ask" $ do
    it "authority_table_is_total" $
        [(kind, map (`authority` kind) [Worker, Engineer, TenX, User]) | kind <- [minBound .. maxBound]]
            `shouldBe` table

    it "forward_all_handler_changes_nothing" . hedgehog $ do
        handler <- forAll genRung
        question <- forAll genQuestion
        (forwardAll `andThen` rung handler) question === rung handler question
        (rung handler `andThen` forwardAll) question === rung handler question

    -- #360's law Chain: the parent judges what the child forwards, as raised.
    -- Stated on the child's reading, not on its verdict: a child that rules or
    -- refuses decides alone; one that passes on, and may, hands the parent the
    -- question raised to its reading.
    it "handlers_compose" . hedgehog $ do
        (child@(_, reading), parent) <- forAll ((,) <$> genRung <*> genRung)
        question <- forAll genQuestion
        let raised = Question question.qid (raise question.kind reading.kind) question.text
            expected = case (reading.choice, rung child question) of
                (RuleOn _, alone) -> alone
                (PassOn, Left refusal) -> Left refusal
                (PassOn, Right _) -> rung parent raised
        cover 2 "the child raises what it forwards" (raisedBy (rung child question) question)
        (rung child `andThen` rung parent) question === expected

    it "andThen_is_associative" . hedgehog $ do
        (first, next, last') <- forAll ((,,) <$> genRung <*> genRung <*> genRung)
        question <- forAll genQuestion
        ((rung first `andThen` rung next) `andThen` rung last') question
            === (rung first `andThen` (rung next `andThen` rung last')) question

    it "no_event_retags_security" . hedgehog $ do
        rungs <- forAll (Gen.list (Range.linear 1 4) genRung)
        question <- forAll genSecurity
        case chain rungs question of
            Left _ -> pure ()
            Right (Ruled ruling) -> ruling.kind === Security
            Right (Forward forwarded) -> forwarded.kind === Security

    it "security_ruling_needs_basis" . hedgehog $ do
        handler <- forAll genRung
        question <- forAll genSecurity
        let verdict = rung handler question
        cover 5 "ruled" (isRuled verdict)
        cover 1 "refused for no basis" (verdict == Left (NoBasis question.qid))
        holdsBasis verdict

    describe "triage" $ do
        it "refuses a ruling where the row forwards" $
            triage Engineer (Reading Design (RuleOn proposal)) (asking Design)
                `shouldBe` Left (MayNotRule Engineer Design)

        it "refuses a Security ruling with no basis" $
            triage TenX (Reading Security (RuleOn proposal)) (asking Security)
                `shouldBe` Left (NoBasis qid)

        it "accepts a Security ruling that names its basis" $
            fmap ruledBasis (triage TenX (Reading Security (RuleOn based)) (asking Security))
                `shouldBe` Right (Just (Obvious (oneLine "the user named the key")))

        it "never re-tags away from Security" $
            triage TenX (Reading Pick PassOn) (asking Security)
                `shouldBe` Right (Forward (asking Security))

        it "raises a question to Security, so the raised row decides" $
            triage Engineer (Reading Security PassOn) (asking Design)
                `shouldBe` Right (Forward (asking Security))

        it "refuses a forward of a Fact at the 10x, so no Fact reaches the user" $
            triage TenX (Reading Fact PassOn) (asking Fact)
                `shouldBe` Left (MustAnswer TenX Fact)

        it "lets the engineer and the 10x forward a Pick, so the user's may cell is reachable" $
            map (\role -> triage role (Reading Pick PassOn) (asking Pick)) [Engineer, TenX]
                `shouldBe` [Right (Forward (asking Pick)), Right (Forward (asking Pick))]

        it "refuses a forward at the user, the top of the chain" $
            triage User (Reading Pick PassOn) (asking Pick)
                `shouldBe` Left (MustAnswer User Pick)

        it "refuses any choice on a kind the row never sees" $
            triage User (Reading Fact (RuleOn proposal)) (asking Fact)
                `shouldBe` Left (NeverAskedOf User Fact)

        it "lets the LLM rule or forward where the row answers under a condition" $
            map (\choice -> isRuled (triage TenX (Reading Design choice) (asking Design))) [RuleOn proposal, PassOn]
                `shouldBe` [True, False]

    describe "andThen" $ do
        it "lets the parent rule on what the child forwards" $
            fmap ruledQid ((triage Engineer (Reading Design PassOn) `andThen` triage TenX (Reading Design (RuleOn proposal))) (asking Design))
                `shouldBe` Right (Just qid)

        it "stops at the first ruling, so the parent never sees it" $
            fmap ruledQid ((triage Engineer (Reading Fact (RuleOn proposal)) `andThen` triage User (Reading Fact PassOn)) (asking Fact))
                `shouldBe` Right (Just qid)

    describe "ask" $ do
        it "sends a role's own question its row forwards to the user who started the run" $
            ask ByUser Engineer Design `shouldBe` Up TheUser

        it "hands a forwarded question back to the parent run" $
            ask (ByRole (Parent (runId "p1") "parent/events.jsonl" (TaskId "t1"))) Engineer Design `shouldBe` Up (ParentRun (runId "p1"))

        it "leaves a question the role's row may answer to the role" $
            map (ask ByUser Engineer) [Fact, Confirm] `shouldBe` [AnswerSelf, AnswerSelf]

    it "spells the hand-back line as #360's wire format" $
        needsDecision (Question qid Design (oneLine "change the data model?"))
            `shouldBe` "NEEDS_DECISION Design r7f2:3: change the data model?"

    it "writes a hand-back's first line, its run, then a line per ruling" $
        fmap (\ruling -> handback "READY https://example.test/pr/1" (runId "r7f2") [ruling]) (rule TenX Security (asking Security) based)
            `shouldBe` Right "READY https://example.test/pr/1\nRun: r7f2\nRuling r7f2:3 Security: yes - reversible - an hour - basis: obvious: the user named the key\n"

    it "keeps every hand-back line one line" . hedgehog $ do
        question <- forAll genQuestion
        ruling <- forAll (Gen.mapMaybe (either (const Nothing) Just) (rule TenX Pick <$> genQuestion <*> genProposal))
        assert (not (Text.any breaksLine (needsDecision question)))
        let handbackLines = Text.lines (handback "READY ref" (runId "r7f2") [ruling])
        length handbackLines === 3
        filter (Text.any breaksLine) handbackLines === []

    it "refuses a line break in a line of text" $
        map (parseOneLine . ("a" <>) . Text.singleton) ['\n', '\v', '\f', '\r', '\x85', '\x2028', '\x2029'] `shouldBe` replicate 7 Nothing

    it "parses a line back" . hedgehog $ do
        text <- forAll genOneLine
        tripping text oneLineText parseOneLine

    it "parses a question id back" . hedgehog $ do
        questionId <- forAll genQId
        tripping questionId qidText parseQId

    it "refuses a question id with no number, a bad number or a bad run" $
        map parseQId ["r7f2", "r7f2:", "r7f2:3x", "h:3", ":3"] `shouldBe` replicate 5 Nothing

    it "parses a kind's wire name back" . hedgehog $ do
        kind <- forAll Gen.enumBounded
        tripping kind kindName parseKind
  where
    qid = QId (runId "r7f2") 3
    asking kind = Question qid kind (oneLine "a question")
    proposal = Proposal (oneLine "yes") (oneLine "reversible") (oneLine "an hour") Nothing
    based = proposal {basis = Just (Obvious (oneLine "the user named the key"))}

-- | #360's table, a row per kind: Worker, Engineer, 10x, User.
table :: [(Kind, [Rule])]
table =
    [ (Fact, [Forwards, Answers, Answers, NeverAsked])
    , (Pick, [Forwards, Answers, Answers, Answers])
    , (Design, [Forwards, Forwards, AnswersIf RuleTest, Answers])
    , (Scope, [Forwards, Forwards, AnswersIf RuleTest, Answers])
    , (Confirm, [Forwards, AnswersIf TrivialSize, AnswersIf FitsBreakdown, Answers])
    , (Security, [Forwards, Forwards, AnswersIf ObviousOrAnswered, Answers])
    , (Stuck, [Forwards, Forwards, AnswersIf OneRetry, Answers])
    ]

genSecurity :: Gen Question
genSecurity = (\q -> Question q.qid Security q.text) <$> genQuestion

-- | A role and how it reads every question it gets: a handler, shown.
genRung :: Gen (Role, Reading)
genRung = (,) <$> Gen.enumBounded <*> genReading

rung :: (Role, Reading) -> Handler
rung (role, reading) = triage role reading

-- | A question climbing these rungs, the asker's own first.
chain :: [(Role, Reading)] -> Handler
chain = foldr (andThen . rung) forwardAll

holdsBasis :: Either Refusal Verdict -> PropertyT IO ()
holdsBasis = \case
    Right (Ruled ruling) -> assert (isJust ruling.proposal.basis)
    Right (Forward _) -> pure ()
    Left _ -> pure ()

raisedBy :: Either Refusal Verdict -> Question -> Bool
raisedBy verdict question = case verdict of
    Right (Forward forwarded) -> forwarded /= question
    Right (Ruled _) -> False
    Left _ -> False

isRuled :: Either Refusal Verdict -> Bool
isRuled = \case
    Right (Ruled _) -> True
    Right (Forward _) -> False
    Left _ -> False

ruledBasis :: Verdict -> Maybe Basis
ruledBasis = \case
    Ruled ruling -> ruling.proposal.basis
    Forward _ -> Nothing

ruledQid :: Verdict -> Maybe QId
ruledQid = \case
    Ruled ruling -> Just ruling.qid
    Forward _ -> Nothing
