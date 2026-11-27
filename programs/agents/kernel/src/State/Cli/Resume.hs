{- | @state resume@'s packet (#552's Appendix B section E): what a fresh
agent needs to take a run up again, key facts inline and large content as a
reference with the command that loads it. A pure function of the run's log,
so the same log prints the same bytes, and the log cut at @--until k@ prints
the packet as it was after line @k@.

Each section is one function of the 'Input', in the order Appendix E prints
them: a section a later slice adds is one more entry in 'sections'.
-}
module State.Cli.Resume (
    Input (..),
    packet,
) where

import Data.Foldable (toList)
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import State.Artifact (
    Artifact (..),
    FileArtifact (..),
    FileRef (..),
    Size (..),
    absPathText,
    digestText,
    fileKindText,
    newest,
    snapshotted,
    uriText,
    urlKindText,
 )
import State.Category.Fuel (fuelName)
import State.Category.Graph (Node (..))
import State.Category.Step (stateNameText)
import State.Cli.View (answerLine, gapHeadline, pendingLines, section)
import State.Protocol.Advice (recordedPr)
import State.Run.Ask (Principal (..), Question (..), qidText, rulingLine)
import State.Run.Codec (
    flowText,
    handoverReasonText,
    repoText,
    stopToken,
    taskIdText,
    taskStateName,
    tokenWordName,
    urlText,
 )
import State.Run.Event (
    Asking (..),
    Child (..),
    ChildTask (..),
    Envelope (..),
    Event (..),
    Handover (..),
    Harness (..),
    RunId,
    Said (..),
    Session (..),
    SessionId (..),
    Start (..),
    Stop (..),
    Task (..),
    TaskState (Parked),
    TokenWord (..),
    artifactsOf,
    placeOf,
    runIdText,
    spansOf,
 )
import State.Run.Fan (ChildRun (..), Fan (..), latest, pullRequest)
import State.Run.Fold (
    Answer (..),
    Pending (..),
    RunState (..),
    Waits (..),
    askedAt,
    fuelOf,
    unvoided,
 )
import State.Run.Gap (
    Gap (..),
    Severity (Blocker),
    Tracked (..),
    isOpen,
 )
import State.Run.Id (numberedText)
import State.Show (timeText, tshow)

{- | A run's log as the packet reads it. The shell cuts the log at
@--until@ before it replays it, so this one log feeds every section.
-}
data Input = Input
    { state :: RunState
    -- ^ The run, replayed over 'logged'.
    , logged :: NonEmpty Envelope
    -- ^ The run's log, voids and the lines they name still in.
    , notesDirs :: Map RunId FilePath
    -- ^ Each child run's notes dir, from its own first line.
    }

-- | The packet's lines, as @state resume@ prints them.
packet :: Input -> Text
packet input = Text.unlines (concatMap ($ input) sections)

-- | The packet's sections in Appendix E's order; an empty one prints nothing.
sections :: [Input -> [Text]]
sections =
    [ header
    , goal
    , place
    , pr
    , next
    , owed
    , tasks
    , heldWakes
    , openQuestions
    , decisions
    , openGaps
    , notesByTopic
    , \input ->
        ""
            : "context map (load on demand, or in a subagent):"
            : concatMap ($ input) contextMap
    , liveState
    ]

-- | The context map's parts, in Appendix E's order: each lists every item, uncapped.
contextMap :: [Input -> [Text]]
contextMap = [files, urls, childRuns, sessions, spans, rawLog]

header :: Input -> [Text]
header input =
    [ "resume run "
        <> runIdText input.state.run
        <> " ("
        <> flowText input.state.start.flow
        <> "), "
        <> standing
        <> " at "
        <> stateNameText (askedAt input.state)
        <> ": "
        <> tshow (length (sessionsOf input))
        <> " sessions, "
        <> tshow (length (kept input))
        <> " events, "
        <> case lastHandover input of
            Just (n, handover) ->
                "last handover "
                    <> here input n
                    <> " ("
                    <> handoverReasonText handover.reason
                    <> ")"
            Nothing -> "no handover yet"
    ]
  where
    standing = case (input.state.stopped, input.state.at) of
        (Just _, _) -> "stopped"
        (Nothing, At _) -> "active"
        (Nothing, Out) -> "finished"
        (Nothing, Exit) -> "finished"

goal :: Input -> [Text]
goal input = ["goal: " <> text | Just text <- [input.state.start.goal]]

place :: Input -> [Text]
place input =
    [ "worktree: "
        <> Text.pack (absPathText worktree)
        <> "   repo: "
        <> maybe "none" repoText repo
        <> "   fuel: "
        <> fuelName (fuelOf input.state)
    ]
  where
    (worktree, repo) = placeOf input.state.start (kept input)

pr :: Input -> [Text]
pr input =
    [ "pr: "
        <> maybe "none yet" urlText (recordedPr input.state)
        <> "   notes dir: "
        <> Text.pack input.state.start.notes
    ]

-- | The next steps the latest handover named.
next :: Input -> [Text]
next input = case lastHandover input of
    Nothing -> []
    Just (n, handover) ->
        ("next (handover " <> here input n <> "):")
            : zipWith
                (\i step -> "  " <> tshow i <> ". " <> step)
                [1 :: Int ..]
                (toList handover.next)

-- | The questions forwarded to the user that wait for the answer: only a run the user started forwards to the user.
owed :: Input -> [Text]
owed input = case input.state.start.principal of
    ByUser _ ->
        section
            "owed to the user:"
            ( capped
                "state pending"
                [ "- answer " <> qidText p.asking.question.qid
                | p <- reverse input.state.pending
                , ForAnswer <- [p.waits]
                ]
            )
    ByRole {} -> []
    ByCaller _ -> []

-- | The tasks of each fan-out, in its breakdown's order, with the columns the fold knows.
tasks :: Input -> [Text]
tasks input = case rows of
    [] -> []
    _ ->
        "tasks:"
            : map ("  " <>) (table (["id", "status", "at_work", "pr", "child run"] : rows))
  where
    rows = [taskRow fan task | fan <- fans input, task <- fan.tasks]

taskRow :: Fan -> Task -> [Text]
taskRow fan task =
    [ taskIdText task.id
    , status
    , if task.id `elem` fan.atWork then "yes" else "no"
    , maybe "-" urlText (pullRequest fan task.id)
    , maybe "-" (runIdText . (.child.run)) (lastMaybe children)
    ]
        <> extra
  where
    moved = Map.lookup task.id fan.moves
    children = [c | c <- fan.children, c.child.task == Tasked task.id]
    status = case (moved, children) of
        (Just state, _) -> taskStateName state
        (Nothing, []) -> "planned"
        (Nothing, _ : _) -> "spawned"
    extra =
        ["reason: " <> why | Just (Parked why _) <- [moved]]
            <> [ "after " <> Text.unwords (map taskIdText task.deps)
               | null children
               , not (null task.deps)
               , Nothing <- [moved]
               ]

heldWakes :: Input -> [Text]
heldWakes input =
    section
        ("held wakes (" <> tshow (length held) <> "):")
        (capped ("state dump " <> runIdText input.state.run) (reverse held))
  where
    held =
        [ taskIdText task <> " " <> urlText url
        | fan <- fans input
        , (task, url) <- fan.held
        ]

openQuestions :: Input -> [Text]
openQuestions input =
    section
        ("open questions (" <> tshow (length open) <> "):")
        (capped "state pending" (reverse open))
  where
    open = pendingLines input.state

-- | The run's rulings and the answers that came down, newest first, by the line that decided each.
decisions :: Input -> [Text]
decisions input =
    section
        ("decisions (" <> tshow (length decided) <> ", newest first):")
        (capped "state show" decided)
  where
    decided =
        mapMaybe
            (`Map.lookup` lines')
            (dedupe (reverse (concatMap decidedBy (kept input))))
    lines' =
        Map.fromList
            ( [(ruling.qid, rulingLine ruling) | ruling <- input.state.rulings]
                <> [(answer.about.qid, answerLine answer) | answer <- input.state.answers]
            )
    decidedBy line =
        [qid | RuledOn qid _ <- [line.event]]
            <> [qid | Answered qid _ _ <- [line.event]]
    -- The same answer logged again is no news: the newest line names it.
    dedupe = foldr (\qid rest -> qid : filter (/= qid) rest) []

{- | The gaps still open, a fix proposed counting as open: blockers first,
then slowdowns, then papercuts, each oldest first. The header counts them
all, and the blockers among them.
-}
openGaps :: Input -> [Text]
openGaps input =
    section
        ( "open gaps ("
            <> tshow (length open)
            <> ", "
            <> tshow (length [() | (_, gap) <- open, gap.severity == Blocker])
            <> " blocker):"
        )
        ( capped
            "state show"
            [ here input n <> " " <> gapHeadline gap
            | (n, gap) <- open
            ]
        )
  where
    open =
        sortOn
            (\(n, gap) -> (gap.severity, n))
            [(n, tracked.gap) | (n, tracked) <- input.state.gaps, isOpen tracked.status]

-- | Each topic's count of notes and its newest, newest topic first, with the command that loads its texts.
notesByTopic :: Input -> [Text]
notesByTopic input = case topics of
    [] -> []
    _ ->
        ( "notes by topic: "
            <> Text.intercalate
                ", "
                [ topic <> " " <> tshow count <> " (last " <> here input n <> ")"
                | (topic, count, n) <- topics
                ]
        )
            : [ "  load: "
                    <> sqlLoad
                        ( "select text from notes where run_id = '"
                            <> runIdText input.state.run
                            <> "' and topic = "
                            <> sqlText topic
                        )
              | (topic, _, _) <- topics
              ]
  where
    topics =
        sortOn
            (\(_, _, n) -> Down n)
            [ (topic, length ns, maximum ns)
            | (topic, ns) <-
                Map.toList
                    ( Map.fromListWith
                        (<>)
                        [(topic, line.seq :| []) | line <- kept input, Noted topic _ <- [line.event]]
                    )
            ]

-- | The newest snapshot of each file the run registered, oldest first, with the count of older ones.
files :: Input -> [Text]
files input =
    subsection
        "files"
        (concatMap fileLines (sortOn fst (Map.elems (newest registered))))
  where
    registered = artifactsOf (kept input)
    fileLines (n, file) =
        Text.unwords
            [ fileKindText file.kind
            , here input n
            , Text.pack (absPathText file.ref.path)
            , digestText file.ref.sha256
            , tshow file.ref.size.bytes
            , "bytes"
            , if stored file then "stored" else "path only"
            ]
            : ["  load: state artifact show " <> here input n | stored file]
                <> [ "  older: "
                        <> tshow older
                        <> "  load: "
                        <> sqlLoad
                            ( "select id, sha256, size_bytes from artifacts where run_id = '"
                                <> runIdText input.state.run
                                <> "' and path = "
                                <> sqlText (Text.pack (absPathText file.ref.path))
                                <> " order by id"
                            )
                   | let older = length [() | (_, File f) <- registered, f.ref.path == file.ref.path] - 1
                   , older > 0
                   ]
    stored file = snapshotted file.kind file.ref.size

urls :: Input -> [Text]
urls input =
    subsection
        "urls"
        [ Text.unwords [urlKindText kind, here input n, uriText uri]
        | (n, Url kind uri) <- artifactsOf (kept input)
        ]

-- | Every child run of the run's fan-outs, with its notes dir and the command that resumes it.
childRuns :: Input -> [Text]
childRuns input =
    subsection
        "child runs"
        ( concat
            [ [ Text.unwords
                    [ runIdText childRun.child.run
                    , case childRun.child.task of
                        Tasked task -> taskIdText task
                        Untasked -> "-"
                    , standing
                    , token
                    , "notes dir"
                    , maybe "-" Text.pack (Map.lookup childRun.child.run input.notesDirs)
                    ]
              , "  load: state resume " <> runIdText childRun.child.run
              ]
            | fan <- fans input
            , childRun <- fan.children
            , let (standing, token) = said (latest childRun)
            ]
        )
  where
    said = \case
        Nothing -> ("active", "-")
        Just (Finished _) -> ("finished", word ReadyWord)
        Just (AsksUp _) -> ("active", word NeedsDecisionWord)
        Just (Awaits _ _) -> ("active", word AwaitWord)
        Just (Ended stop) -> ("stopped", Text.toLower (fst (stopToken stop.reason)))
    word = tokenWordName

-- | Each harness session, as @v_sessions@ has it: from its first line in the run to its last.
sessions :: Input -> [Text]
sessions input =
    subsection
        "sessions"
        [ Text.unwords
            [ sid
            , maybe "-" (\s -> let Harness name = s.harness in name) started
            , timeText (minimum (fmap (.ts) lines'))
            , "to"
            , timeText (maximum (fmap (.ts) lines'))
            , "transcript"
            , maybe "-" (Text.pack . absPathText) ((.transcript) =<< started)
            ]
        | (SessionId sid, lines') <- sessionsOf input
        , let started = lastMaybe [s | line <- toList lines', SessionStarted s <- [line.event]]
        ]

-- | How many spans the run started, and the SQL that loads their briefs and hand-backs: too long to print.
spans :: Input -> [Text]
spans input = case spansOf (kept input) of
    [] -> []
    started ->
        [ "  spans: " <> tshow (length started) <> " (briefs and hand-backs)"
        , "    load: "
            <> sqlLoad
                ( "select id, agent_role, handback_token, brief, handback from spans where run_id = '"
                    <> runIdText input.state.run
                    <> "'"
                )
        ]

rawLog :: Input -> [Text]
rawLog input = ["  raw log: state dump " <> runIdText input.state.run]

-- | CI and mergeable state are live GitHub reads: the run's own PR's commands.
liveState :: Input -> [Text]
liveState input = case recordedPr input.state of
    Nothing -> []
    Just url ->
        [ ""
        , "live state (not in the log): gh pr checks "
            <> urlText url
            <> "; gh pr view "
            <> urlText url
            <> " --json mergeable"
        ]

-- | The lines replay keeps: every fact of the packet reads these alone.
kept :: Input -> [Envelope]
kept input = fst (unvoided (toList input.logged))

-- | A line of this run, as @<run>:<seq>@.
here :: Input -> Natural -> Text
here input = numberedText input.state.run

fans :: Input -> [Fan]
fans input = Map.elems input.state.fans

lastHandover :: Input -> Maybe (Natural, Handover)
lastHandover input = lastMaybe [(line.seq, h) | line <- kept input, HandedOver h <- [line.event]]

-- | The run's lines of each session, in the order each session first wrote one.
sessionsOf :: Input -> [(SessionId, NonEmpty Envelope)]
sessionsOf input = grouped [(sid, line) | line <- kept input, Just sid <- [line.session]]
  where
    grouped = \case
        [] -> []
        (sid, line) : rest ->
            (sid, line :| [other | (s, other) <- rest, s == sid])
                : grouped [p | p@(s, _) <- rest, s /= sid]

{- | At most 'cap' items, newest first as given, then how many more and the
command that lists them all (Appendix E's inline caps).
-}
capped :: Text -> [Text] -> [Text]
capped load items = case drop cap items of
    [] -> items
    rest -> take cap items <> ["... " <> tshow (length rest) <> " more: " <> load]

-- | Ten items of a capped section (ruling a4057991:1).
cap :: Int
cap = 10

-- | A part of the context map, its items under it; none when it has none.
subsection :: Text -> [Text] -> [Text]
subsection title = map ("  " <>) . section title

{- | Columns padded to their widest cell, two spaces apart; a row's cells
past the header's columns trail it unpadded.
-}
table :: [[Text]] -> [Text]
table rows =
    [ Text.stripEnd
        (Text.intercalate "  " (zipWith pad widths row <> drop (length widths) row))
    | row <- rows
    ]
  where
    widths =
        [ maximum (map (Text.length . cell i) rows)
        | i <- [0 .. length (concat (take 1 rows)) - 1]
        ]
    cell i row = fromMaybe "" (lookup i (zip [0 ..] row))
    pad width = Text.justifyLeft width ' '

{- | @state sql "<query>"@, quoted for a POSIX shell's double quotes: the
query's own quotes stay SQL's single ones.
-}
sqlLoad :: Text -> Text
sqlLoad query = "state sql \"" <> Text.concatMap escape query <> "\""
  where
    escape c
        | c `elem` ['"', '\\', '$', '`'] = Text.pack ['\\', c]
        | otherwise = Text.singleton c

-- | A SQL string literal: single quotes, one doubled inside.
sqlText :: Text -> Text
sqlText raw = "'" <> Text.replace "'" "''" raw <> "'"

lastMaybe :: [a] -> Maybe a
lastMaybe = listToMaybe . reverse
