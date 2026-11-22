module State.Protocol.AdviceSpec (spec) where

import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Doubles.Gh (printedPr)
import Hedgehog (Gen, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Category.Flow (scopePath)
import State.Category.Fuel (Fuel (..))
import State.Flow.Role.TenX (tenX)
import State.Protocol.Advice
import State.Protocol.Record (Option (..), commandOption)
import State.Role (Rung (Lead))
import State.Run.Ask (
    Above (..),
    Kind (..),
    OneLine,
    Proposal (..),
    QId (..),
    Question (..),
    Refusal (MustAnswer),
    Route (..),
 )
import State.Run.Event hiding (Stopped)
import State.Run.Event qualified as Event (Start (..))
import State.Run.EventGen (
    fuelSet,
    genStart,
    genText,
    logOf,
    oneLine,
    run,
    runId,
    start,
    started,
 )
import State.Run.Fold (RunState (..), Worker (..), replay)
import State.Run.RunGen (
    architectGraph,
    chiefGraph,
    childOf,
    commit,
    enoughIn,
    flowGraph,
    g,
    genAccepted,
    happyPath,
    loadSteps,
    pickOf,
    plainTask,
    runAt,
    runOf,
    runUnder,
    scopedIn,
    securityGraph,
    securityScope,
    sha,
    skipOf,
    spawnedIn,
    tenXAt,
    tenXGraph,
    ticketUrl,
    ticketWritten,
    within,
 )
import State.Step.Build (Outcome (..))
import State.Step.Catalog (outcome)
import State.Step.Gather (Outcome (..))
import State.Step.Plan (Outcome (..))
import State.Step.Request (Outcome (..))
import State.Step.Review (Outcome (..))
import State.Step.Ship (Outcome (..))
import Test.Hspec (
    Spec,
    describe,
    it,
    runIO,
    shouldBe,
    shouldNotSatisfy,
    shouldSatisfy,
 )
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Protocol.Advice" $ do
    steps <- runIO loadSteps
    let next facts state = commandsOnly (advise steps (flowGraph state.start.flow) facts state).action
        explainedAt state =
            explained state.start (advise steps (flowGraph state.start.flow) noFacts state)

    it "advice_is_equal_under_any_principal_of_one_task_shape_up_to_delivery"
        . hedgehog
        $ do
            events <- forAll genAccepted
            facts <- forAll genFacts
            one <- forAll genStart
            other <- forAll genStart
            -- One task shape for both: a round on an existing PR skips ready by its shape, not by who asks.
            let under from =
                    runUnder
                        start
                            { principal = confirming (shapedAs one.principal from.principal)
                            , interface = from.interface
                            }
                        events
                decided state = (due facts state, advise steps g facts state)
            decided (under one) === decided (under other)

    describe "pullRequestOf" $ do
        it "reads back the PR gh prints" . hedgehog $ do
            pr <- forAll genPullRequest
            pullRequestOf (printedPr pr) === Right (Just pr)

        it "reads gh's no-PR failure as no PR" $
            pullRequestOf (PrViewFailed "no pull requests found for branch \"b\"\n")
                `shouldBe` Right Nothing

        it "says why GitHub was not read" $
            map
                pullRequestOf
                [ PrViewTimedOut 10
                , PrViewFailed
                    "error connecting to api.github.com\ncheck your internet connection\n"
                , PrViewPrinted
                    "{\"url\":\"u\",\"baseRefName\":\"main\",\"headRefName\":\"b\",\"isDraft\":false,\"state\":\"LOCKED\"}"
                ]
                `shouldBe` [ Left "gh pr view timed out after 10s"
                           , Left "gh pr view: error connecting to api.github.com"
                           , Left "gh pr view printed no PR: Error in $: unknown PR state LOCKED"
                           ]

    describe "fuel" $ do
        it "advises a root's Fuel step first, the user asked only when no Fuel is given" $
            (\advice -> (commandsOnly advice.action, last (Text.lines advice.prompt)))
                (advise steps g noFacts (runAt []))
                `shouldBe` ( offering ["state record fuel.set <low|balanced|max>"]
                           , "No Fuel given yet: take your brief's or the request's Fuel line; with none, ask the user once."
                           )

        it
            "records a given Fuel at a whole flow's root as given, asking nothing: the chief's request gave it"
            $ last
                ( Text.lines
                    ( advise
                        steps
                        chiefGraph
                        noFacts
                        ( either
                            (error . show)
                            id
                            ( replay
                                chiefGraph
                                ( logOf
                                    ( Started (Event.Start ChiefFlow "notes" (ByUser OwnPr) Set.empty)
                                        :| [fuelSet Max, Took mempty (pickOf "route" "engineer")]
                                    )
                                )
                            )
                        )
                    ).prompt
                )
                `shouldBe` "The Fuel given: max. Record it, unless the request names another."

        it
            "names no target at the Fuel of a flow run on its own: only a chief request names one"
            $ (advise steps g noFacts (runAt [])).prompt
                `shouldNotSatisfy` Text.isInfixOf "target"

    describe "the chief" $ do
        let chiefAt events =
                either
                    (error . show)
                    id
                    ( replay
                        chiefGraph
                        ( logOf
                            (Started (Event.Start ChiefFlow "notes" (ByUser OwnPr) Set.empty) :| events)
                        )
                    )
            atChief events = advise steps chiefGraph noFacts (chiefAt events)
            -- A request's Fuel, then its pick.
            routed branch = [fuelSet Balanced, Took mempty (pickOf "route" branch)]
            onPr = Targeted (OnPr prUrl)
            designAsked =
                Asked
                    ( Asking
                        (Question (QId run 1) Design (oneLine "which store?"))
                        (StateName "engineer/gather")
                        Itself
                    )
            -- A whole flow's events in its scope, past its root's Fuel.
            inScope scope events = within scope (fuelSet Balanced : events)
            pickAsked =
                [ Asked
                    ( Asking
                        (Question (QId run 1) Pick (oneLine "which branch?"))
                        (StateName "route")
                        Itself
                    )
                , Forwarded (QId run 1) TheUser
                , Answered (QId run 1) (Chose "engineer") TheUser
                ]
        it "sets each request's Fuel first, its target named before it" $
            (\advice -> (commandsOnly advice.action, advice.at)) (atChief [])
                `shouldBe` ( offering ["state record fuel.set <low|balanced|max>"]
                           , "at fuel: a step you run - do the task below, run the option that fits its result, then state next"
                           )
        it "names the target a request may record before its Fuel" $
            (atChief []).prompt `shouldSatisfy` Text.isInfixOf "`target pr <url>`"
        it "then offers one pick per branch" $
            Set.fromList
                [ option.command
                | Run options <- [(atChief [fuelSet Balanced]).action]
                , option <- toList options
                ]
                `shouldBe` Set.fromList
                    [ "state record route." <> branch
                    | branch <-
                        ["architect", "engineer", "10x", "blocks", "discussion", "other", "delegate"]
                    ]
        it "names the pick a branch the agent picks" $
            (atChief [fuelSet Balanced]).at
                `shouldBe` "at route: a branch you pick - take one option below, then state next"
        it
            "tells the agent at the pick to guess the branch and ask the user once only when the request is ambiguous"
            $ (atChief [fuelSet Balanced]).prompt
                `shouldSatisfy` Text.isPrefixOf "Guess the branch from the request"
        it "asks no more once the user was asked the branch" $
            (atChief (fuelSet Balanced : pickAsked)).prompt
                `shouldBe` "The user was asked the branch once: record the branch the answer names."
        it
            "names the url the request recorded last at next, the PR an engineer request ended in"
            $ (atChief (routed "engineer" <> inScope "engineer" happyPath)).prompt
                `shouldSatisfy` Text.isSuffixOf "\nThe last result: u"
        it "names no url at next after a request that recorded none" $
            (atChief (routed "other" <> [stepTook (DirectDone "renamed a file")])).prompt
                `shouldSatisfy` Text.isSuffixOf "\nThe last result: none recorded"
        it
            "settles a targeted request's plan itself: skips its simplify and confirms it"
            $ map
                ( \n ->
                    due
                        noFacts
                        (chiefAt (onPr : routed "engineer" <> inScope "engineer" (take n happyPath)))
                )
                [6, 8]
                `shouldBe` [ Just (Took (scopePath "engineer") (skipOf "simplify_plan"))
                           , Just (Took (scopePath "engineer") (outcome ConfirmConfirmed))
                           ]
        it
            "leaves a targeted request's plan to the user once a Design question was asked"
            $ due
                noFacts
                ( chiefAt
                    ( onPr
                        : routed "engineer" <> [designAsked] <> inScope "engineer" (take 8 happyPath)
                    )
                )
                `shouldBe` Nothing
        it "asks the user to confirm a request's plan with no target, as before targets" $
            next
                noFacts
                (chiefAt (routed "engineer" <> inScope "engineer" (take 8 happyPath)))
                `shouldSatisfy` \case
                    Ask Confirm _ -> True
                    _ -> False
        it "skips ready on a targeted PR, as GitHub reads it by its url" $
            due
                withPr
                (chiefAt (onPr : routed "engineer" <> inScope "engineer" (take 17 happyPath)))
                `shouldBe` Just (Took (scopePath "engineer") (outcome (ReadySkipped prUrl)))
        it
            "explains each discussion question before it is asked, as the architect's discussion does"
            $ (atChief (routed "discussion")).prompt
                `shouldSatisfy` Text.isInfixOf "First send the Explain message"

    describe "gather" $ do
        it
            "offers each action and enough at the gather's pick, each by its pick and where it leads"
            $ explainedAt (runAt (knobs Balanced)) `shouldBe` gatherPick

        it
            "says the research pick spawns a researcher in the background where the interface can"
            $ last
                ( explained
                    start {interface = Set.insert Background start.interface}
                    (advise steps g noFacts (runAt (knobs Balanced)))
                )
                `shouldBe` "  state record gather.research - on to gather/research, which spawns a researcher in the background"

        it
            "advises a researcher's spawn at the research state, the hook recording it, as its SPAWN says"
            $ do
                explained
                    child
                    (advise steps g noFacts (runAt (knobs Balanced <> [pickResearch])))
                    `shouldBe` [ "at gather/research: a step a researcher subagent runs - spawn it with the task below; its spawn and hand-back are recorded by the hooks, best effort: with no recorded line after one, run state record gather/research.spawned, or pipe the hand-back into state handback researcher; then state next"
                               , "outcomes:"
                               , "  gather/research.spawned - back to gather, the gather loop's next round"
                               ]
                deliver child (Spawn (AgentRole "researcher") Nothing)
                    `shouldBe` "SPAWN researcher background: no"

        it
            "prints each action's task on its own line, so the researcher's reads apart from the interview's"
            $ length (Text.lines (advise steps g noFacts (runAt (knobs Balanced))).prompt)
                `shouldBe` 2

        it "advises the 10x's gather as the engineer's, with no Fuel ask" $
            next noFacts tenXStarted `shouldBe` choosing

        it "waits at the researchers' await after enough while a researcher is open" $
            next
                noFacts
                (runAt (knobs Balanced <> researched <> [Took mempty (pickOf "gather" "enough")]))
                `shouldBe` offering ["end your turn"]

        it "offers enough again once every researcher handed back" $
            explainedAt
                ( runAt
                    ( knobs Balanced
                        <> researched
                        <> [stepTook ResearchHandedBack, WorkerReturned (AgentRole "researcher") Nothing]
                    )
                )
                `shouldBe` explainedAt (runAt (knobs Balanced))

        it "asks the user whether to go on once the questions are used up" $
            next noFacts (runAt (knobs Balanced <> questions 30))
                `shouldBe` Ask Stuck "Interview questions: 30 of 30 used, none left: go on?"

        it
            "asks the user whether to go on at the questions' end, after a Stuck question before it"
            $ do
                let stuckFirst =
                        [ Asked (Asking goOn gathering Itself)
                        , Forwarded goOn.qid TheUser
                        , Answered goOn.qid (Chose "yes") TheUser
                        ]
                next noFacts (runAt (knobs Balanced <> stuckFirst <> questions 30))
                    `shouldBe` Ask Stuck "Interview questions: 30 of 30 used, none left: go on?"

        it "asks the user whether to go on once the researchers are used up" $
            next noFacts (runAt (knobs Low <> researched))
                `shouldBe` Ask Stuck "Researchers: 1 of 1 used, none left: go on?"

        it "extends on the user's yes, or ends the gather" $ do
            let onStuck =
                    knobs Balanced
                        <> questions 30
                        <> [ Asked (Asking goOn gathering Itself)
                           , Forwarded goOn.qid TheUser
                           , Answered goOn.qid (Chose "yes") TheUser
                           ]
            next noFacts (runAt onStuck)
                `shouldBe` offering
                    [ "state record gather.enough"
                    , "state record gather.research"
                    , "state record extend <why>"
                    ]
            next noFacts (runAt (onStuck <> [Extended "the user goes on"]))
                `shouldBe` choosing

    it "names where a spawned step's outcomes lead, for the hook records them" $
        explainedAt (runAt (knobs Balanced <> take 13 happyPath))
            `shouldBe` [ "at review: a step a review-lead subagent runs - spawn it with the task below; its hand-back is recorded by the hook, best effort: with no recorded line after it, pipe it into state handback review-lead; then state next"
                       , "outcomes:"
                       , "  review.clean - on to describe"
                       , "  review.rows - on to pick"
                       ]

    describe "pick" $ do
        it "offers pick.loop while a re-review is left" $
            next noFacts (atPick Balanced [])
                `shouldSatisfy` offers (any ("state record pick.loop" `Text.isPrefixOf`))

        it "offers only pick.final once no re-review is left" $
            next noFacts (atPick Low looped)
                `shouldSatisfy` offers (all ("state record pick.final" `Text.isPrefixOf`))

        it "offers pick.final beside the fixer at a stuck fix once Stuck was asked" $ do
            let stuckAt asked =
                    atPick
                        Balanced
                        ( looped
                            <> [stepTook (PickLoop (Picks (Set.singleton (Label "A")) Map.empty))]
                            <> asked
                        )
                finalLeads = filter ("pick.final" `Text.isInfixOf`) . explainedAt . stuckAt
            map
                finalLeads
                [ []
                ,
                    [ Asked (Asking goOn (StateName "fix") Itself)
                    , Forwarded goOn.qid TheUser
                    , Answered goOn.qid (Chose "stop") TheUser
                    ]
                ]
                `shouldBe` [ []
                           ,
                               [ "  state record pick.final [--row <label>]... [--verdict <requirement>=<met|not-met|unverified>]... - on to describe"
                               ]
                           ]

    describe "confirm" $ do
        it "asks Confirm at confirm" $
            next noFacts atConfirm `shouldSatisfy` \case
                Ask Confirm _ -> True
                _ -> False

        it "asks Confirm once, then advises its outcome" $ do
            let (question, asked, _) = byRow atConfirm Confirm (oneLine "the plan holds?")
                answered =
                    runAt
                        ( knobs Balanced
                            <> take 8 happyPath
                            <> asked
                            <> [Answered question.qid (Chose "confirmed") TheUser]
                        )
            next noFacts answered
                `shouldBe` offering ["state record confirm.confirmed", "state record confirm.adjusted"]

    describe "the architect" $ do
        let architectRun = architectOf . (knobs Balanced <>)
        it "asks the architect's Fuel first, as the engineer's" $
            next noFacts (architectOf []) `shouldBe` next noFacts (runAt [])

        it
            "offers research, the discussion's questions, the ticket and enough at its one pick"
            $ next noFacts (architectRun [])
                `shouldBe` offering
                    [ "state record architect.discuss"
                    , "state record architect.enough"
                    , "state record architect.research"
                    , "state record architect.ticket"
                    ]

        it "ends with no ticket on enough, naming its notes file" $
            next noFacts (architectRun (enoughIn "architect"))
                `shouldBe` Done (ArchitectEnd architectNotes Nothing)

        it "ends naming its notes file and the ticket's url it wrote" $
            next noFacts (architectRun (ticketWritten <> enoughIn "architect"))
                `shouldBe` Done (ArchitectEnd architectNotes (Just ticketUrl))

        it
            "tells the discussion to send its Explain message before each question, in the same turn"
            $ ( advise
                    steps
                    architectGraph
                    noFacts
                    (architectRun [Took mempty (pickOf "architect" "discuss")])
              ).prompt
                `shouldSatisfy` any
                    ( \line ->
                        "Discuss:" `Text.isPrefixOf` line
                            && "First send the Explain message" `Text.isInfixOf` line
                            && "then the question as text" `Text.isInfixOf` line
                            && "in the same turn" `Text.isInfixOf` line
                    )
                    . Text.lines

    it "names a subagent's role with its article" $
        map
            (Text.isPrefixOf "at implement: a step an implementer subagent runs")
            (take 1 (explainedAt (runAt (knobs Balanced <> take 10 happyPath))))
            `shouldBe` [True]

    it "advises a scoped step's outcomes under their qualified names" $ do
        let atSecurityPick =
                either (error . show) id . replay securityGraph . logOf $
                    started
                        :| [ stepTook (ReviewRows sha)
                           , stepTook (PickFinal (Picks Set.empty Map.empty))
                           , tookIn securityScope (ReviewRows sha)
                           ]
        commandsOnly (advise steps securityGraph noFacts atSecurityPick).action
            `shouldBe` offering
                [ "state record security/pick.final [--row <label>]... [--verdict <requirement>=<met|not-met|unverified>]..."
                , "state record security/pick.loop [--row <label>]... [--verdict <requirement>=<met|not-met|unverified>]..."
                ]

    describe "due" $ do
        it "records nothing at the gather's choice" $
            due noFacts (runAt (knobs Low)) `shouldBe` Nothing

        it "skips the refactor at or below its changed lines" $
            due noFacts {changedLines = Just 100} atRefactor
                `shouldBe` Just (Took mempty (skipOf "refactor"))

        it
            "runs the refactor above its changed lines, and leaves it to the agent when they are unknown"
            $ map
                (\changed -> due noFacts {changedLines = changed} atRefactor)
                [Just 101, Nothing]
                `shouldBe` [Just (Took mempty (runOf "refactor")), Nothing]

        it "says what decides the refactor when its changed lines are unknown" $
            skippable atRefactor
                `shouldBe` ["Balanced: skip it at or below 100 changed lines, else run it"]

        it "records the draft PR GitHub already has" $
            due
                withPr {pr = Just (PullRequest draftPr IsDraft)}
                (runAt (knobs Balanced <> take 9 happyPath))
                `shouldBe` Just (stepTook (DraftDone draftPr))

        it "takes a merged or closed PR on the branch for an old one, not the draft" $
            [ due
                withPr {pr = Just (PullRequest draftPr over)}
                (runAt (knobs Balanced <> take 9 happyPath))
            | over <- [IsMerged, IsClosed]
            ]
                `shouldBe` [Nothing, Nothing]

        it "records ready once GitHub says the PR is ready" $
            due withPr {pr = Just (PullRequest draftPr IsReady)} atReady
                `shouldBe` Just (stepTook (ReadyDone prUrl))

        it "asks the user to confirm a user's round's plan, as before targets" $ do
            let roundAtConfirm = runUnder userRound (knobs Balanced <> take 8 happyPath)
            (due withPr roundAtConfirm, next withPr roundAtConfirm)
                `shouldSatisfy` \case
                    (Nothing, Ask Confirm _) -> True
                    _ -> False

        it
            "records a user's round's PR in review as its draft, and skips ready though GitHub says it is ready"
            $ [ due
                    withPr {pr = Just (PullRequest draftPr IsReady)}
                    (runUnder userRound (knobs Balanced <> take n happyPath))
              | n <- [9, 17]
              ]
                `shouldBe` [Just (stepTook (DraftDone draftPr)), Just (stepTook (ReadySkipped prUrl))]

    describe "the 10x's fan-out" $ do
        let t1 = plainTask "t1" []
            t2 = plainTask "t2" []
            heavy name = (plainTask name []) {heavy = True}
            asks = Question (QId (runId "c1") 1) Design (oneLine "which store?")
            fromChild =
                [ Spawned (childOf "c1" "t1")
                , HandedBack (runId "c1") (AsksUp asks.qid)
                , Asked (Asking asks (StateName "engineers") (ChildRun (runId "c1")))
                ]
        it "spawns the next free task" $
            next noFacts (tenXAt (t1 :| [t2]) [Spawned (childOf "c1" "t1")])
                `shouldBe` Spawn (AgentRole "engineer") (Just (TaskId "t2"))
        it
            "has a child that ended unrecorded handed back first, one it holds finished never"
            $ [ next
                    noFacts {ended = [runId "c1"]}
                    (tenXAt (t1 :| [t2]) (Spawned (childOf "c1" "t1") : said))
              | said <- [[], [HandedBack (runId "c1") (Finished (oneLine "done"))]]
              ]
                `shouldBe` [ offering ["state handback engineer"]
                           , offering ["state record task t1 review <url>"]
                           ]
        it "spawns a second heavy task while one runs" $
            next noFacts (tenXAt (heavy "t1" :| [heavy "t2"]) [Spawned (childOf "c1" "t1")])
                `shouldBe` Spawn (AgentRole "engineer") (Just (TaskId "t2"))
        it "awaits a dependency's merge, not a park of its dependent" $ do
            let reviewed =
                    [ Spawned (childOf "c1" "t1")
                    , HandedBack (runId "c1") (Finished (oneLine "PR #1"))
                    , TaskMoved (TaskId "t1") (InReview prUrl)
                    ]
            map
                (next noFacts . tenXAt (t1 :| [plainTask "t2" ["t1"]]))
                [reviewed, reviewed <> [TaskMoved (TaskId "t1") (Merged prUrl)]]
                `shouldBe` [ AwaitMerge ((TaskId "t1", Just prUrl) :| [])
                           , Spawn (AgentRole "engineer") (Just (TaskId "t2"))
                           ]
        it "stops the run at merge once every task is parked" $
            next
                noFacts
                ( tenXAt
                    (t1 :| [t2])
                    [ TaskMoved (TaskId "t1") (Parked "out of scope" Nothing)
                    , TaskMoved (TaskId "t2") (Parked "not needed" Nothing)
                    ]
                )
                `shouldBe` offering ["state stop blocked \"all tasks parked\""]
        it "waits on the children while a task's dependencies run" $
            next
                noFacts
                (tenXAt (t1 :| [plainTask "t2" ["t1"]]) [Spawned (childOf "c1" "t1")])
                `shouldBe` AwaitChildren (TaskId "t1" :| [])
        it "spawns the next task once a spawn is recorded, never the same task twice" $
            map
                (next noFacts . tenXAt (t1 :| [t2]))
                [[Spawning (TaskId "t1")], [Spawning (TaskId "t1"), Spawning (TaskId "t2")]]
                `shouldBe` [ Spawn (AgentRole "engineer") (Just (TaskId "t2"))
                           , AwaitChildren (TaskId "t1" :| [TaskId "t2"])
                           ]
        it
            "resumes the next child once a resume is recorded, never the same child twice"
            $ do
                let asks2 = Question (QId (runId "c2") 1) Design (oneLine "which queue?")
                    both =
                        fromChild
                            <> [ RuledOn asks.qid ruling
                               , Spawned (childOf "c2" "t2")
                               , HandedBack (runId "c2") (AsksUp asks2.qid)
                               , Asked (Asking asks2 (StateName "engineers") (ChildRun (runId "c2")))
                               , RuledOn asks2.qid ruling
                               ]
                map
                    (next noFacts . tenXAt (t1 :| [t2]))
                    [ both <> [Resumed (runId "c1")]
                    , both <> [Resumed (runId "c1"), Resumed (runId "c2")]
                    ]
                    `shouldBe` [ Resume (runId "c2") "with the answer to c2:1: confirmed"
                               , AwaitChildren (TaskId "t1" :| [TaskId "t2"])
                               ]
        it "sends a child lost at a restart again, and waits on it once resumed" $ do
            let lost = [Spawned (childOf "c1" "t1"), Restarted]
            map (next noFacts . tenXAt (t1 :| [])) [lost, lost <> [Resumed (runId "c1")]]
                `shouldBe` [ Resume (runId "c1") "lost at a restart: a fresh engineer with its spawn prompt"
                           , AwaitChildren (TaskId "t1" :| [])
                           ]
        it "spawns a task added mid-run" $
            next
                noFacts
                (tenXAt (t1 :| []) [Spawned (childOf "c1" "t1"), TaskAdded (plainTask "fix" [])])
                `shouldBe` Spawn (AgentRole "engineer") (Just (TaskId "fix"))
        it "waits on CI no more once the child is resumed" $
            next
                noFacts
                ( tenXAt
                    (t1 :| [])
                    [ Spawned (childOf "c1" "t1")
                    , HandedBack (runId "c1") (Awaits Ci (oneLine "https://pr/1"))
                    , Resumed (runId "c1")
                    ]
                )
                `shouldBe` AwaitChildren (TaskId "t1" :| [])
        it "triages a child's stop before a retry, and retries once it is asked" $ do
            let stop = Stop Blocked "no access"
                stopped = [Spawned (childOf "c1" "t1"), HandedBack (runId "c1") (Ended stop)]
                triaged = Question (QId (runId "r7f2") 1) Stuck (oneLine "retry?")
            map
                (next noFacts . tenXAt (t1 :| []))
                [ stopped
                , stopped
                    <> [ Asked (Asking triaged (StateName "engineers") (ChildRun (runId "c1")))
                       , RuledOn triaged.qid ruling
                       ]
                ]
                `shouldBe` [ TriageStop (runId "c1") (Just (TaskId "t1")) stop
                           , Spawn (AgentRole "engineer") (Just (TaskId "t1"))
                           ]
        it "offers no retry of a task once its second child stops" $ do
            let stop = Stop Blocked "no access"
                triaged = Question (QId (runId "r7f2") 1) Stuck (oneLine "retry?")
                twice =
                    [ Spawned (childOf "c1" "t1")
                    , HandedBack (runId "c1") (Ended stop)
                    , Asked (Asking triaged (StateName "engineers") (ChildRun (runId "c1")))
                    , RuledOn triaged.qid ruling
                    , Spawned (childOf "c2" "t1")
                    , HandedBack (runId "c2") (Ended stop)
                    ]
            next noFacts (tenXAt (t1 :| []) twice)
                `shouldBe` TriageStop (runId "c2") Nothing stop
        it "waits on the user's answer to a stopped child's question before a retry" $ do
            let stuckOn = Question (QId (runId "r7f2") 1) Stuck (oneLine "retry?")
                forwarded =
                    [ Spawned (childOf "c1" "t1")
                    , HandedBack (runId "c1") (Ended (Stop Blocked "no access"))
                    , Asked (Asking stuckOn (StateName "engineers") (ChildRun (runId "c1")))
                    , Forwarded stuckOn.qid TheUser
                    ]
            map
                (next noFacts . tenXAt (t1 :| []))
                [forwarded, forwarded <> [Answered stuckOn.qid (Chose "retry") TheUser]]
                `shouldBe` [AwaitAnswer stuckOn, Spawn (AgentRole "engineer") (Just (TaskId "t1"))]
        it
            "waits on the merge loop at merge, and ends only once every task is merged or parked"
            $ do
                let inReview =
                        [ Spawned (childOf "c1" "t1")
                        , HandedBack (runId "c1") (Finished (oneLine "PR #1"))
                        , TaskMoved (TaskId "t1") (InReview prUrl)
                        ]
                map
                    (next noFacts . tenXAt (t1 :| []))
                    [inReview, inReview <> [TaskMoved (TaskId "t1") (Merged prUrl)]]
                    `shouldBe` [ AwaitMerge ((TaskId "t1", Just prUrl) :| [])
                               , offering ["state record merge.done <url>", "state record merge.next_round"]
                               ]
        {- parallel's identity law as a run sees it: @parallel g f@ is @traverse f@,
        so its results come back in the items' order, whatever order the
        children hand back in.
        -}
        it
            "parallel_identity_gives_the_merge_the_prs_in_fork_order_whatever_order_the_engineers_hand_back_in"
            . hedgehog
            $ do
                n <- forAll (Gen.int (Range.linear 1 4))
                let indices = map (Text.pack . show) [1 .. n]
                    task i = "t" <> i
                    back i =
                        [ HandedBack (runId ("c" <> i)) (Finished (oneLine "PR"))
                        , TaskMoved (TaskId (task i)) (InReview (Url ("pr" <> i)))
                        ]
                handBacks <- forAll (Gen.shuffle indices)
                next
                    noFacts
                    ( tenXAt
                        (NonEmpty.fromList [plainTask (task i) [] | i <- indices])
                        ( [Spawned (childOf ("c" <> i) (task i)) | i <- indices]
                            <> concatMap back handBacks
                        )
                    )
                    === AwaitMerge
                        (NonEmpty.fromList [(TaskId (task i), Just (Url ("pr" <> i))) | i <- indices])
        it "spawns a task added at the merge" $ do
            let merged =
                    [ Spawned (childOf "c1" "t1")
                    , HandedBack (runId "c1") (Finished (oneLine "PR #1"))
                    , TaskMoved (TaskId "t1") (Merged prUrl)
                    ]
            next noFacts (tenXAt (t1 :| []) (merged <> [TaskAdded (plainTask "fix" [])]))
                `shouldBe` Spawn (AgentRole "engineer") (Just (TaskId "fix"))
        it "resumes a ruled child while the user holds another child's question" $ do
            let asks2 = Question (QId (runId "c2") 1) Security (oneLine "token in env?")
                forwarded =
                    fromChild
                        <> [ RuledOn asks.qid ruling
                           , Spawned (childOf "c2" "t2")
                           , HandedBack (runId "c2") (AsksUp asks2.qid)
                           , Asked (Asking asks2 (StateName "engineers") (ChildRun (runId "c2")))
                           , Forwarded asks2.qid TheUser
                           ]
            map
                (next noFacts . tenXAt (t1 :| [t2]))
                [forwarded, forwarded <> [Resumed (runId "c1")]]
                `shouldBe` [Resume (runId "c1") "with the answer to c1:1: confirmed", AwaitAnswer asks2]
        it "records a finished task's PR when the child's READY named none" $
            map
                ( next noFacts
                    . tenXAt (t1 :| [t2])
                    . ( [ Spawned (childOf "c1" "t1")
                        , HandedBack (runId "c1") (Finished (oneLine "done"))
                        ]
                            <>
                      )
                )
                [[], [TaskMoved (TaskId "t1") (InReview prUrl)]]
                `shouldBe` [ offering ["state record task t1 review <url>"]
                           , Spawn (AgentRole "engineer") (Just (TaskId "t2"))
                           ]
        it "states a child's question no more once it is answered" $
            filter
                ("task " `Text.isPrefixOf`)
                ( factLines
                    tenXGraph
                    noFacts
                    (tenXAt (t1 :| []) (fromChild <> [RuledOn asks.qid ruling]))
                )
                `shouldBe` ["task t1: child c1 waits to resume, tries 1"]
        it "triages a child's question before anything else" $
            next noFacts (tenXAt (t1 :| [t2]) fromChild) `shouldBe` Triage asks
        it "resumes a child with the ruling on its question" $
            next noFacts (tenXAt (t1 :| []) (fromChild <> [RuledOn asks.qid ruling]))
                `shouldBe` Resume (runId "c1") "with the answer to c1:1: confirmed"
        it "resumes a child with the answer that came down for its question" $
            next
                noFacts
                ( tenXAt
                    (t1 :| [])
                    ( fromChild
                        <> [Forwarded asks.qid TheUser, Answered asks.qid (Chose "postgres") TheUser]
                    )
                )
                `shouldBe` Resume (runId "c1") "with the answer to c1:1: postgres"
        it "waits on the CI or merge a child handed back" $
            [ next
                noFacts
                ( tenXAt
                    (t1 :| [])
                    [ Spawned (childOf "c1" "t1")
                    , HandedBack (runId "c1") (Awaits on (oneLine "https://pr/1"))
                    ]
                )
            | on <- [Ci, Merge]
            ]
                `shouldBe` [AwaitOn Ci "https://pr/1", AwaitOn Merge "https://pr/1"]
        it "waits on a finished task's CI, recording nothing" $ do
            let inCi =
                    [ Spawned (childOf "c1" "t1")
                    , TaskMoved (TaskId "t1") (InCi prUrl)
                    , HandedBack (runId "c1") (Finished (oneLine "PR #1"))
                    ]
            (next noFacts (tenXAt (t1 :| []) inCi), due noFacts (tenXAt (t1 :| []) inCi))
                `shouldBe` (AwaitOn Ci "https://pr/1", Nothing)
        it "advises each other task's own action beside the most urgent, one per task" $ do
            let ruled = fromChild <> [RuledOn asks.qid ruling]
                advice = advise steps tenXGraph noFacts (tenXAt (t1 :| [t2, plainTask "t3" []]) ruled)
            (advice.action, advice.more)
                `shouldBe` ( Resume (runId "c1") "with the answer to c1:1: confirmed"
                           ,
                               [ Spawn (AgentRole "engineer") (Just (TaskId "t2"))
                               , Spawn (AgentRole "engineer") (Just (TaskId "t3"))
                               ]
                           )
        it "advises nothing beside a task's action when no other task has one" $
            (advise steps tenXGraph noFacts (tenXAt (t1 :| [plainTask "t2" ["t1"]]) [])).more
                `shouldBe` []
        it "states each task's child, PR and tries" $
            filter
                ("task " `Text.isPrefixOf`)
                ( factLines
                    tenXGraph
                    noFacts
                    (tenXAt (t1 :| [t2]) (fromChild <> [TaskMoved (TaskId "t1") (InCi prUrl)]))
                )
                `shouldBe` [ "task t1: child c1 asks c1:1, PR ci https://pr/1, tries 1"
                           , "task t2: not started, tries 0"
                           ]
        it "states a task's agent at work and its held wakes" $
            filter
                ("task " `Text.isPrefixOf`)
                ( factLines
                    tenXGraph
                    noFacts
                    ( tenXAt
                        (t1 :| [])
                        ( fromChild
                            <> [ RuledOn asks.qid ruling
                               , Resumed (runId "c1")
                               , Held (TaskId "t1") (Url "https://pr/1#c")
                               ]
                        )
                    )
                )
                `shouldBe` ["task t1: child c1 running, agent at work, tries 1, held https://pr/1#c"]

    describe "deliver" $ do
        it "spawns in the background only where the interface can" $
            map
                ( \ops ->
                    deliver
                        start {interface = Set.fromList ops}
                        (Spawn (AgentRole "implementer") Nothing)
                )
                [[], [Background]]
                `shouldBe` ["SPAWN implementer background: no", "SPAWN implementer background: yes"]

        it "names a basis in the triage line of a Security question only" $
            map
                (\kind -> deliver start (Triage (Question which.qid kind which.text)))
                [Design, Security]
                `shouldBe` [ "RUN state rule r7f2:1 --answer <a> --why <w> --cost <c> | state forward r7f2:1 - Design r7f2:1: which store?"
                           , "RUN state rule r7f2:1 --answer <a> --why <w> --cost <c> --basis <event-id>|obvious:<why> | state forward r7f2:1 - Security r7f2:1: which store?"
                           ]

        it "asks the user a forwarded question, or hands it back to a parent run" $
            map (`deliver` AwaitAnswer which) [start, child]
                `shouldBe` [ "ASK Design r7f2:1: which store? - " <> asText
                           , "HANDBACK NEEDS_DECISION Design r7f2:1: which store?"
                           ]

        it "names the task an engineer is spawned for" $
            deliver
                start {interface = Set.fromList [Background]}
                (Spawn (AgentRole "engineer") (Just (TaskId "t1")))
                `shouldBe` "SPAWN engineer --task t1 background: yes"

        it "resumes a child, or waits on the children" $
            map
                (deliver start {interface = Set.singleton Await})
                [ Resume (runId "c1") "with the answer to c1:1: postgres"
                , AwaitChildren (TaskId "t1" :| [TaskId "t2"])
                , AwaitMerge ((TaskId "t1", Just prUrl) :| [])
                ]
                `shouldBe` [ "RESUME c1 with the answer to c1:1: postgres"
                           , "AWAIT children t1 t2"
                           , "AWAIT merge t1"
                           ]

        it
            "hands the merges it awaits up by their PRs where the interface cannot wait, a task with none by its id"
            $ deliver
                child
                (AwaitMerge ((TaskId "t1", Just prUrl) :| [(TaskId "t2", Nothing)]))
                `shouldBe` "HANDBACK AWAIT merge https://pr/1 t2"

        it
            "puts a child's stop to triage as a retry of its task while one is left, else as a question from the child"
            $ [ deliver start (TriageStop (runId "c1") task (Stop Blocked "no access"))
              | task <- [Just (TaskId "t1"), Nothing]
              ]
                `shouldBe` [ "RUN state retry t1 --why <w> | state ask --kind <kind> --from c1 <question> - triage: BLOCKED no access"
                           , "RUN state ask --kind <kind> --from c1 <question> - triage: BLOCKED no access"
                           ]

        it "waits on CI or a merge itself only where the interface can" $
            [ deliver from (AwaitOn on "u")
            | on <- [Ci, Merge]
            , from <- [start {interface = Set.singleton Await}, start]
            ]
                `shouldBe` ["AWAIT ci u", "HANDBACK AWAIT ci u", "AWAIT merge u", "HANDBACK AWAIT merge u"]

        it "delivers the other tasks' actions under the first, never under a hand-back" $ do
            let beside first =
                    Advice
                        first
                        [Spawn (AgentRole "engineer") (Just (TaskId "t2"))]
                        ""
                        []
                        []
                        ""
                        False
            [ deliverMore from (beside first)
              | (from, first) <-
                    [ (start, AwaitAnswer which)
                    , (child, AwaitAnswer which)
                    , (child, Resume (runId "c1") "go")
                    ]
              ]
                `shouldBe` [ ["SPAWN engineer --task t2 background: no"]
                           , []
                           , ["SPAWN engineer --task t2 background: no"]
                           ]

        it
            "notifies at ready only where the interface can, so a child run leaves it to its parent"
            $ do
                let ready = advise steps g noFacts atReady
                map (`deliverPrompt` ready) [start {interface = Set.singleton Notify}, child]
                    `shouldBe` [ready.prompt <> " Then notify.", ready.prompt]
        it "ends as DONE for the user, READY for a parent run" $
            map (`deliver` Done (OutputEnd (Just (Url "https://pr/1")))) [start, child]
                `shouldBe` ["DONE https://pr/1", "HANDBACK READY https://pr/1"]

        it "stops for the user, or hands the stop back to a parent run" $
            map (`deliver` Stopped (Stop OutOfRounds "review")) [start, child]
                `shouldBe` ["STOP rounds review", "HANDBACK BLOCKED out of rounds: review"]

    describe "heldBy" $ do
        let fixer = [Worker (AgentRole "fixer") (AgentId "a1") 7]
            finished =
                Advice
                    (Done (OutputEnd (Just (Url "https://pr/1"))))
                    []
                    "at the end: the flow is done"
                    [commandOption "state record x" ""]
                    ["fuel: balanced"]
                    ""
                    False
        it
            "holds a hand-back to a parent while a worker is at work, naming it in house format"
            $ heldBy child fixer finished
                `shouldBe` finished
                    { action = AwaitWorker (AgentRole "fixer") (AgentId "a1")
                    , leads = []
                    , facts =
                        [ "state handback: fixer a1 is still at work - its hand-back is not recorded"
                        , "fix: wait for it, or state handback fixer for its report, or state void 7 \"<why>\" for a lost one"
                        , "fuel: balanced"
                        ]
                    }
        it
            "lets the hand-back go with no worker at work, and holds a line that hands nothing back"
            $ [ heldBy child [] finished
              , heldBy start fixer finished
              , heldBy child fixer finished {action = Spawn (AgentRole "fixer") Nothing}
              ]
                `shouldBe` [finished, finished, finished {action = Spawn (AgentRole "fixer") Nothing}]
        it "awaits the worker by its role and id" $
            deliver child (AwaitWorker (AgentRole "fixer") (AgentId "a1"))
                `shouldBe` "AWAIT worker fixer a1"

    describe "ownAsk" $ do
        it "forwards a Design question to the user" $
            byRow atImplement Design (oneLine "which store?")
                `shouldBe` askedUp askUser TheUser

        it "hands a Design question back to a parent run" $
            byRow
                (runUnder child (knobs Balanced <> take 10 happyPath))
                Design
                (oneLine "which store?")
                `shouldBe` askedUp "HANDBACK NEEDS_DECISION Design r7f2:1: which store?" (ParentRun parent)

        it "forwards the Confirm to whoever started the run, at every Fuel" $
            [ line
            | fuel <- [minBound .. maxBound]
            , from <- [start, child]
            , let (_, _, line) =
                    byRow
                        (runUnder from (knobs fuel <> take 8 happyPath))
                        Confirm
                        (oneLine "the plan holds?")
            ]
                `shouldBe` concat
                    (replicate 3 [askUser, "HANDBACK NEEDS_DECISION Confirm r7f2:1: the plan holds?"])

        it
            "answers a Design question itself inside a 10x scope, where the unscoped run forwards it"
            $ [ line
              | state <- [atImplement, inTenXScope]
              , let (_, _, line) = byRow state Design (oneLine "which store?")
              ]
                `shouldBe` [askUser, "ANSWER yourself"]

        it "leaves a Pick question to the run itself" $
            byRow atImplement Pick (oneLine "which rows?")
                `shouldBe` ( Question (QId run 1) Pick (oneLine "which rows?")
                           ,
                               [ Asked
                                    (Asking (Question (QId run 1) Pick (oneLine "which rows?")) implement Itself)
                               ]
                           , "ANSWER yourself"
                           )

        it
            "sends a question its row answers to the user at once, asked and forwarded: up to a parent from a child"
            $ [ ownAsk state ToUser Pick (oneLine "which rows?")
              | state <- [atImplement, runUnder child (knobs Balanced <> take 10 happyPath)]
              ]
                `shouldBe` [ Right (askedPick askUser TheUser)
                           , Right
                                (askedPick "HANDBACK NEEDS_DECISION Pick r7f2:1: which rows?" (ParentRun parent))
                           ]

        it "refuses to send the user a question the run's row must answer itself" $
            ownAsk atImplement ToUser Fact (oneLine "which file?")
                `shouldBe` Left (MustAnswer Lead Fact)
  where
    -- The user reads the question as the turn's last text, so no tool call may follow it;
    -- the line names how to record the answer, under the question's id.
    asText =
        "notify the user, then write the question as your final text, with no tool call after it; then state answer r7f2:1 <answer>"
    askUser = "ASK user: " <> asText
    noFacts = Facts Nothing Nothing []
    withPr = noFacts {pr = Just (PullRequest draftPr IsDraft)}
    prUrl = Url "https://pr/1"
    draftPr = DraftPr prUrl (Branch "main") (Branch "b")
    userRound = start {principal = ByUser (RoundOn prUrl)}
    parent = runId "p1"
    child =
        start
            { principal =
                ByRole (Parent parent (InFan (Tasked (TaskId "t1")))) OwnPr ChildConfirms
            , interface = Set.empty
            }
    which = Question (QId run 1) Design (oneLine "which store?")
    ruling =
        Proposal
            (oneLine "confirmed")
            (oneLine "the plan holds")
            (oneLine "none")
            Nothing
    implement = StateName "implement"
    atImplement = runAt (knobs Balanced <> take 10 happyPath)
    -- An engineer run inlining 10x, at the scope's first state.
    inTenXScope =
        either (error . show) id (replay (scopedIn "10x" tenX) (logOf (started :| [])))
    atConfirm = runAt (knobs Balanced <> take 8 happyPath)
    atRefactor = runAt (knobs Balanced <> take 11 happyPath)
    tenXRun events =
        either
            (error . show)
            id
            (replay tenXGraph (logOf (Started start {Event.flow = TenXFlow} :| events)))
    -- As init starts a 10x: at Balanced, given.
    tenXStarted = tenXRun [fuelSet Balanced]
    gathering = StateName "gather"
    -- A researcher spawned and bound to its agent: open in the ledger until it returns.
    researched = spawnedIn "gather" <> [WorkerSpawned (AgentRole "researcher") (AgentId "r1")]
    pickResearch = Took mempty (pickOf "gather" "research")
    -- Each put to the user at the interview and answered, then back at the gather's pick.
    questions n =
        Took mempty (pickOf "gather" "interview")
            : concat
                [ [ Asked
                        ( Asking
                            (Question (QId run i) Design (oneLine "a question"))
                            (StateName "interview")
                            Itself
                        )
                  , Forwarded (QId run i) TheUser
                  , Answered (QId run i) (Chose "yes") TheUser
                  ]
                | i <- [1 .. n]
                ]
                <> [stepTook InterviewAsked]
    goOn = Question (QId run 100) Stuck (oneLine "go on?")
    -- What @state next@ explains at the gather's pick.
    gatherPick =
        [ "at gather: a branch you pick - take one option below, then state next"
        , "options:"
        , "  state record gather.enough - on to gather/researchers"
        , "  state record gather.interview - on to interview"
        , "  state record gather.research - on to gather/research, which spawns a researcher in the foreground"
        ]
    choosing =
        offering
            [ "state record gather.enough"
            , "state record gather.interview"
            , "state record gather.research"
            ]
    atReady = runAt (knobs Balanced <> take 17 happyPath)
    -- One review round with a row, fixed, and the next round's rows.
    looped =
        [ stepTook (PickLoop (Picks (Set.singleton (Label "A")) Map.empty))
        , stepTook (FixDone commit)
        , stepTook (ReReviewRows sha)
        ]
    atPick fuel rest =
        runAt (knobs fuel <> take 13 happyPath <> [stepTook (ReviewRows sha)] <> rest)
    -- A Design question the run's own row forwards: asked, then forwarded at once.
    askedUp line above =
        ( which
        , [Asked (Asking which implement Itself), Forwarded which.qid above]
        , line
        )
    -- A Pick question the run's own row answers, sent to the user at once.
    askedPick line above =
        let rows = Question (QId run 1) Pick (oneLine "which rows?")
         in (rows, [Asked (Asking rows implement Itself), Forwarded rows.qid above], line)

-- | The run's own question as its row sends it, which no row refuses.
byRow :: RunState -> Kind -> OneLine -> (Question, [Event], Text)
byRow state kind text = either (error . show) id (ownAsk state ByRow kind text)

knobs :: Fuel -> [Event]
knobs fuel = [fuelSet fuel]

-- | An architect run of these events.
architectOf :: [Event] -> RunState
architectOf events =
    either
        (error . show)
        id
        ( replay
            architectGraph
            (logOf (Started start {Event.flow = ArchitectFlow} :| events))
        )

-- | The notes file an architect run of 'start' names at its end.
architectNotes :: FilePath
architectNotes = "notes/notes.md"

-- | Whether the commands a 'Run' offers hold.
offers :: ([Text] -> Bool) -> Action -> Bool
offers holds = \case
    Run options -> holds (map (.command) (toList options))
    _ -> False

-- | A 'Run' of these commands, each meaning left to the specs that pin it.
offering :: [Text] -> Action
offering = Run . fmap (`commandOption` "") . NonEmpty.fromList

-- | The action with each option's meaning and spawn dropped: most specs pin only the commands.
commandsOnly :: Action -> Action
commandsOnly = \case
    Run options -> Run (fmap (\option -> commandOption option.command "") options)
    other -> other

genFacts :: Gen Facts
genFacts =
    Facts
        <$> Gen.maybe (Gen.integral (Range.linear 0 300))
        <*> Gen.maybe genPullRequest
        <*> pure []

genPullRequest :: Gen PullRequest
genPullRequest =
    PullRequest
        <$> (DraftPr . Url <$> genText <*> pure (Branch "main") <*> pure (Branch "b"))
        <*> Gen.element [IsDraft, IsReady, IsMerged, IsClosed]

{- | The principal with the plan left to its run: a plan its parent decided is advice of its own.
| The second principal with the first's task shape.
-}
shapedAs :: Principal -> Principal -> Principal
shapedAs like = \case
    ByRole parent _ plan -> ByRole parent shape plan
    ByUser _ -> ByUser shape
    ByCaller _ -> ByCaller shape
  where
    shape = case like of
        ByRole _ s _ -> s
        ByUser s -> s
        ByCaller s -> s

confirming :: Principal -> Principal
confirming = \case
    ByRole parent shape _ -> ByRole parent shape ChildConfirms
    ByUser shape -> ByUser shape
    ByCaller shape -> ByCaller shape
