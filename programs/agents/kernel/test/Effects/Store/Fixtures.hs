{- | A store in a temp dir and the logs the store specs write to it: the
same open, appends and runs for the projection, report and SQL specs.
-}
module Effects.Store.Fixtures (
    opened,
    raw,
    atStore,
    atStoreWith,
    appended,
    appendedAll,
    shippedProjections,
    contextRun,
    fileRef,
    asking,
    stopgapPool,
) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Payload.Event (eventRow, runRow)
import Data.Payload.Upcast (Upcasts, shipped)
import Data.Projection (Projections)
import Database.SQLite.Simple (Connection)
import Database.SQLite.Simple qualified as SQLite
import Doubles.Environment (runEnvironmentGiven)
import Effectful (Eff, runEff, (:>))
import Effectful.Error.Static (runErrorNoCallStack)
import Effects.Log (Log, projected, runLogIO)
import Effects.Store.Connection (
    Durability (Full, Unsynced),
    OpenRefusal,
    Store,
    withStore,
 )
import Effects.Store.Events (Batch (..), Write (..))
import Effects.Store.Events qualified as Store
import Hedgehog (Gen)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Artifact (
    Artifact (File),
    FileArtifact (..),
    FileRef (..),
    Size (..),
    sha256Of,
 )
import State.Artifact qualified as Artifact
import State.Category.Fuel (Fuel (Balanced))
import State.Category.Step (StateName (..))
import State.Role (AgentRole (..))
import State.Run.Ask (Above (..), QId (..), Question (..))
import State.Run.Event (
    Asker (..),
    Asking (..),
    Envelope (..),
    Event (
        Answered,
        ArtifactLogged,
        Asked,
        Forwarded,
        GapMoved,
        Gapped,
        HandedOver,
        Noted,
        Overridden,
        QuestionParked,
        RuledOn,
        SessionStarted,
        SpanEnded,
        SpanStarted,
        StopgapSet,
        StopgapUnset
    ),
    Handover (..),
    HandoverReason (Context),
    Harness (..),
    Session (..),
    SessionId (..),
    SpanEnding (..),
    SpanStart (..),
    Stop (..),
    StopReason (..),
    TaskId (..),
    TaskRef (..),
    TokenWord (ReadyWord),
    runIdText,
    unreported,
 )
import State.Run.Event qualified as Event
import State.Run.EventGen (
    absolutePath,
    fuelSet,
    genArtifact,
    genGap,
    genGapMove,
    genIJson,
    genNonBlank,
    genOneLine,
    genProposal,
    genReply,
    genSpanEnding,
    genText,
    genUsage,
    ijson,
    line,
    run,
    started,
    stopgapKey,
    titled,
    uri,
 )
import State.Run.Fold (Origin (..), Pending (..), RunState (..), Worker (..))
import State.Run.Fold qualified as Fold
import State.Run.Id (SpanId (..))
import State.Run.RunGen (g)
import State.Run.Stopgap (StopgapAt (..))
import System.FilePath ((</>))

{- | The log of these events with questions and context put between them.
A question asked, retagged, ruled on, forwarded, answered or parked; a
note, an artifact (from an earlier one, by an earlier span), a hand-over, a
span started or ended, a gap logged or moved, a stopgap set or unset: each
where the fold takes it, and at times a stop at its end. An event the fold
refuses after one put between ends the log there.
-}
asking :: [Event] -> Gen (NonEmpty Envelope)
asking events = do
    let first = line 1 started
    (rest, ended) <- go (replayed (first :| [])) [first] 2 events
    stop <- Gen.element [[], [Event.Stopped (Stop Blocked "stuck")]]
    pure (first :| rest <> [line (ended + 1) event | ended > 1, event <- stop])
  where
    replayed = either (error . show) id . Fold.replay g
    -- @before@: the lines so far, newest first.
    go state before n pending' = do
        between <-
            Gen.frequency
                [ (2, pure Nothing)
                , (1, Just <$> questionOn state n)
                , (1, Just <$> contextOn state before)
                ]
        case (between, pending') of
            (Just event, _)
                | Right (Fold.Appended next) <- Fold.append g state (line n event) ->
                    first' (line n event :) <$> go next (line n event : before) (n + 1) pending'
            (_, event : rest) -> case Fold.append g state (line n event) of
                Right (Fold.Appended next) ->
                    first' (line n event :) <$> go next (line n event : before) (n + 1) rest
                Right Fold.AlreadyLogged -> pure ([], n - 1)
                Left _ -> pure ([], n - 1)
            (_, []) -> pure ([], n - 1)
    first' f (xs, n) = (f xs, n)
    questionOn state n =
        Gen.choice
            ( ( ( \kind text from ->
                    Asked (Asking (Question (QId run n) kind text) (Fold.nodeName state.at) from)
                )
                    <$> Gen.enumBounded
                    <*> genOneLine
                    <*> Gen.element [Itself, Subagent (AgentRole "researcher")]
              )
                : [ Gen.choice
                        [ pure (Event.RetaggedSecurity qid)
                        , RuledOn qid <$> genProposal
                        , pure (Forwarded qid TheUser)
                        , (\reply -> Answered qid reply TheUser) <$> genReply
                        , QuestionParked qid <$> genOneLine
                        ]
                  | open <- take 1 (reverse state.pending)
                  , let qid = open.asking.question.qid
                  ]
            )
    contextOn state before =
        Gen.choice
            ( [ Noted <$> genText <*> genText
              , ArtifactLogged
                    <$> genArtifact
                    <*> Gen.maybe (Gen.element (dangling : artifacts))
                    <*> Gen.maybe (SpanId <$> Gen.element (dangling : spans'))
              , HandedOver
                    <$> ( Handover
                            <$> Gen.enumBounded
                            <*> genText
                            <*> Gen.nonEmpty (Range.linear 1 3) genText
                        )
              , SpanStarted
                    <$> ( SpanStart (AgentRole "researcher") (Harness "claude-code")
                            <$> genText
                            <*> Gen.maybe (SpanId <$> Gen.element (dangling : spans'))
                            <*> Gen.maybe genText
                        )
              , Gapped <$> genGap
              , StopgapSet
                    <$> Gen.element stopgapPool
                    <*> genIJson
                    <*> genNonBlank
              ]
                <> [ SpanEnded (SpanId open) <$> genSpanEnding <*> genUsage
                   | open <- take 1 [w.spawnedAt | w <- state.workers, SpanLine <- [w.origin]]
                   ]
                <> [ GapMoved gap <$> genGapMove
                   | (gap, _) <- take 1 (reverse state.gaps)
                   ]
                <> [ StopgapUnset place <$> genNonBlank
                   | place <- take 1 (Map.keys state.stopgaps)
                   ]
            )
      where
        -- No line of a generated log has this seq: a reference the trace does not hold.
        dangling = 100000
        artifacts = [e.seq | e <- before, ArtifactLogged {} <- [e.event]]
        spans' = [e.seq | e <- before, SpanStarted _ <- [e.event]]

-- | Where the generated stopgaps live: few, so a set often replaces one.
stopgapPool :: [StopgapAt]
stopgapPool =
    [ StopgapAt Nothing (stopgapKey "deploy.window")
    , StopgapAt (Just (TaskRef (TaskId "t1") 1)) (stopgapKey "deploy.window")
    , StopgapAt Nothing (stopgapKey "a.b")
    ]

shippedProjections :: Projections
shippedProjections = projected shipped

-- | A store under this directory, open with these projections for one action.
opened :: FilePath -> Projections -> (Store -> IO a) -> IO a
opened dir ps act =
    withStore Unsynced (dir </> "kernel-v2.db") ps act >>= either (fail . show) pure

-- | A connection to the store's file past the kernel, as an admin opens one.
raw :: FilePath -> (Connection -> IO a) -> IO a
raw dir = SQLite.withConnection (dir </> "kernel-v2.db")

-- | One line appended, as the kernel's write appends it.
appended :: Store -> Envelope -> IO ()
appended store e =
    Store.locked
        store
        (runIdText e.run)
        (const (Just (Batch (writeOf (e :| [])) []), ()))

-- | Every line appended in one write.
appendedAll :: Store -> NonEmpty Envelope -> IO ()
appendedAll store logged@(first :| _) =
    Store.locked
        store
        (runIdText first.run)
        (const (Just (Batch (writeOf logged) []), ()))

writeOf :: NonEmpty Envelope -> Write
writeOf logged@(first :| _) = case runRow first of
    Just started' -> Start started' (fmap eventRow logged)
    Nothing -> Append (fmap eventRow logged)

{- | An engineer run, by the seq of each line: two spans, one under the
other, each making an artifact, the second from the first; a note, a
hand-over, a gap moved on, stopgaps set, replaced and unset, a visit left,
and a stop. Session s1 writes three lines, the hand-over among them.
-}
contextRun :: NonEmpty Envelope
contextRun =
    NonEmpty.zipWith
        (\n (session, event) -> (line n event) {session})
        (1 :| [2 ..])
        ( (Nothing, started)
            :| [ (Nothing, fuelSet Balanced)
               , (Nothing, SpanStarted (spanStart Nothing))
               , (Nothing, SpanStarted (spanStart (Just (SpanId 3))))
               ,
                   ( Nothing
                   , ArtifactLogged
                        (File (FileArtifact Artifact.Plan fileRef))
                        Nothing
                        (Just (SpanId 3))
                   )
               ,
                   ( Nothing
                   , ArtifactLogged
                        (Artifact.Url Artifact.Doc (uri "https://example.com/d"))
                        (Just 5)
                        (Just (SpanId 4))
                   )
               , (Nothing, SpanEnded (SpanId 3) (WithHandback ReadyWord "READY") unreported)
               , (Nothing, SpanEnded (SpanId 4) NoHandback unreported)
               , (s1, SessionStarted (Session (Harness "claude-code") Nothing "startup" Nothing))
               , (s1, Noted "traps" "cold cache")
               ,
                   ( Nothing
                   , StopgapSet
                        (StopgapAt Nothing (stopgapKey "a.b"))
                        (ijson "\"x\"")
                        (titled "older")
                   )
               ,
                   ( Nothing
                   , StopgapSet
                        (StopgapAt Nothing (stopgapKey "deploy.window"))
                        (ijson "1")
                        (titled "r")
                   )
               ,
                   ( Nothing
                   , StopgapSet
                        (StopgapAt Nothing (stopgapKey "a.b"))
                        (ijson "\"y\"")
                        (titled "newer")
                   )
               ,
                   ( Nothing
                   , StopgapUnset (StopgapAt Nothing (stopgapKey "deploy.window")) (titled "done")
                   )
               ,
                   ( s1
                   , HandedOver (Handover Context "half done" ("state next" :| ["state resume"]))
                   )
               , (Nothing, Overridden (StateName "plan") "the research is in")
               , (Nothing, Event.Stopped (Stop Blocked "out of options"))
               ]
        )
  where
    s1 = Just (SessionId "s1")
    spanStart parent =
        SpanStart
            (AgentRole "researcher")
            (Harness "claude-code")
            "a brief"
            parent
            Nothing

-- | The file the fixtures' plan artifact registers.
fileRef :: FileRef
fileRef = FileRef (absolutePath "/w/plan.md") (sha256Of "plan") (Size 4)

-- | A program on the run store under this @XDG_STATE_HOME@, which it must open.
atStore :: FilePath -> (forall es. (Log :> es) => Eff es a) -> IO a
atStore = atStoreWith shipped

atStoreWith ::
    Upcasts -> FilePath -> (forall es. (Log :> es) => Eff es a) -> IO a
atStoreWith upcasts dir program =
    runEff
        ( runErrorNoCallStack @OpenRefusal
            . runEnvironmentGiven (Map.fromList [("XDG_STATE_HOME", dir)])
            . runLogIO upcasts Full
            $ program
        )
        >>= either (fail . show) pure
