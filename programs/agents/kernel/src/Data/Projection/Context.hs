{- | The context projection (#552 Appendix A and c3): what a run keeps for
a later session to read. Its notes (@notes@), the files and URLs it
registered (@artifacts@), its hand-overs (@handovers@,
@handover_next_steps@), each born of one line of the trace and keyed by its
seq; and the stopgaps in force (@stopgaps@), the last state's.
-}
module Data.Projection.Context (
    projection,
    rows,
    NoteRow (..),
    ArtifactRow (..),
    HandoverRow (..),
    StopgapRow (..),
    noteInsert,
    artifactInsert,
    handoverInserts,
    stopgapInsert,
) where

import Control.Monad (mfilter)
import Data.Foldable (toList)
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Projection (
    Insert (..),
    Projection (..),
    Table,
    Value (..),
    enumIn,
    indexed,
    integer,
    nullable,
    spellings,
    strictTable,
 )
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import State.Artifact (
    Artifact (..),
    FileArtifact (..),
    FileRef (..),
    Size (..),
    absPathText,
    fileKindText,
    sha256Text,
    uriText,
    urlKindText,
 )
import State.Run.Codec (handoverReasonText)
import State.Run.Event (
    Envelope (..),
    Event (..),
    Handover (..),
    RunId,
    TaskRef (..),
    runIdText,
 )
import State.Run.Fold (RunState (..))
import State.Run.IJson (ijsonValue)
import State.Run.Id (SpanId (..))
import State.Run.Stopgap (Stopgap (..), StopgapAt (..), stopgapKeyText)
import State.Show (jsonText)
import State.Step.Artifact (nonBlankText, taskIdText)

projection :: Projection
projection =
    Projection
        { name = "context"
        , version = 1
        , tables = notes :| [artifacts, handovers, handoverNextSteps, stopgaps]
        }

-- | The run's rows in every table of this projection, from its trace.
rows :: NonEmpty (Envelope, RunState) -> [Insert]
rows trace =
    concatMap lineRows lines'
        <> [ stopgapInsert (StopgapRow final.run at stopgap)
           | (at, stopgap) <- Map.toList final.stopgaps
           ]
  where
    lines' = toList (fmap fst trace)
    final = snd (NonEmpty.last trace)
    lineRows e = case e.event of
        Noted topic text -> [noteInsert (NoteRow e.run e.seq topic text)]
        ArtifactLogged artifact source span' ->
            [ artifactInsert
                ( ArtifactRow
                    e.run
                    e.seq
                    artifact
                    (mfilter (`Set.member` registered) source)
                    (mfilter ((`Set.member` started) . (.spanSeq)) span')
                )
            ]
        HandedOver handover -> handoverInserts (HandoverRow e.run e.seq handover)
        _ -> []
    -- A void drops the line an artifact names as its source or span: the row names none.
    registered = Set.fromList [e.seq | e <- lines', ArtifactLogged {} <- [e.event]]
    started = Set.fromList [e.seq | e <- lines', SpanStarted _ <- [e.event]]

-- | A note, by the seq of its line.
data NoteRow = NoteRow {runId :: RunId, id :: Natural, topic :: Text, text :: Text}
    deriving stock (Eq, Show)

{- | A file or URL the run registered, by the seq of its line: the artifact
of this run it was made from, and the span of the agent that made it.
-}
data ArtifactRow = ArtifactRow
    { runId :: RunId
    , id :: Natural
    , artifact :: Artifact
    , derivedFrom :: Maybe Natural
    , span :: Maybe SpanId
    }
    deriving stock (Eq, Show)

-- | A hand-over, by the seq of its line.
data HandoverRow = HandoverRow {runId :: RunId, id :: Natural, handover :: Handover}
    deriving stock (Eq, Show)

-- | A stopgap in force, where it lives.
data StopgapRow = StopgapRow {runId :: RunId, at :: StopgapAt, stopgap :: Stopgap}
    deriving stock (Eq, Show)

data LocationKind = FileLocation | UrlLocation
    deriving stock (Eq, Show, Enum, Bounded)

locationKindName :: LocationKind -> Text
locationKindName = \case
    FileLocation -> "file"
    UrlLocation -> "url"

noteInsert :: NoteRow -> Insert
noteInsert row =
    Insert
        "notes"
        ( ("run_id", SqlText (runIdText row.runId))
            :| [ ("id", integer row.id)
               , ("topic", SqlText row.topic)
               , ("text", SqlText row.text)
               ]
        )

artifactInsert :: ArtifactRow -> Insert
artifactInsert row =
    Insert
        "artifacts"
        ( ("run_id", SqlText (runIdText row.runId))
            :| [ ("id", integer row.id)
               , ("kind", SqlText kind)
               , ("location_kind", SqlText (locationKindName location))
               , ("path", nullable (SqlText . Text.pack . absPathText . (.path)) file)
               , ("sha256", nullable (SqlText . sha256Text . (.sha256)) file)
               , ("size_bytes", nullable (integer . (.size.bytes)) file)
               , ("url", nullable (SqlText . uriText) url)
               , ("span_id", nullable (integer . (.spanSeq)) row.span)
               , ("source_artifact_id", nullable integer row.derivedFrom)
               ]
        )
  where
    (kind, location, file, url) = case row.artifact of
        File f -> (fileKindText f.kind, FileLocation, Just f.ref, Nothing)
        Url urlKind uri -> (urlKindText urlKind, UrlLocation, Nothing, Just uri)

-- | A hand-over and each of its next steps, in order, from 1.
handoverInserts :: HandoverRow -> [Insert]
handoverInserts row =
    Insert
        "handovers"
        ( ("run_id", SqlText (runIdText row.runId))
            :| [ ("id", integer row.id)
               , ("reason", SqlText (handoverReasonText row.handover.reason))
               , ("summary", SqlText row.handover.summary)
               ]
        )
        : [ Insert
                "handover_next_steps"
                ( ("run_id", SqlText (runIdText row.runId))
                    :| [ ("handover_id", integer row.id)
                       , ("ordinal", integer ordinal)
                       , ("next_step", SqlText step)
                       ]
                )
          | (ordinal, step) <- zip [1 ..] (toList row.handover.next)
          ]

stopgapInsert :: StopgapRow -> Insert
stopgapInsert row =
    Insert
        "stopgaps"
        ( ("run_id", SqlText (runIdText row.runId))
            :| [ ("id", integer row.stopgap.seq)
               , ("breakdown_id", nullable (integer . (.breakdown)) row.at.scope)
               , ("task_id", nullable (SqlText . taskIdText . (.task)) row.at.scope)
               , ("key", SqlText (stopgapKeyText row.at.key))
               , ("value", SqlText (jsonText (ijsonValue row.stopgap.value)))
               , ("reason", SqlText (nonBlankText row.stopgap.reason))
               ]
        )

notes :: Table
notes =
    indexed ["run_id", "topic"] $
        strictTable
            "notes"
            [ "  -- Free text a lead wants a later session to find, filed under a topic."
            , ""
            , "  -- The run."
            , "  run_id TEXT    NOT NULL REFERENCES runs (id),"
            , "  -- The seq of the note event."
            , "  id     INTEGER NOT NULL,"
            , "  -- A short label that groups notes, such as live or traps."
            , "  topic  TEXT    NOT NULL,"
            , "  -- The note itself."
            , "  text   TEXT    NOT NULL,"
            , "  PRIMARY KEY (run_id, id),"
            , "  FOREIGN KEY (run_id, id) REFERENCES events (run_id, seq)"
            ]

artifacts :: Table
artifacts =
    indexed ["run_id", "path"] $
        strictTable
            "artifacts"
            [ "  -- Every file and URL a run registered: its map of context."
            , "  -- A file's content is in blobs when a row there has the same sha256."
            , ""
            , "  -- The run."
            , "  run_id             TEXT    NOT NULL REFERENCES runs (id),"
            , "  -- The seq of the artifact event."
            , "  id                 INTEGER NOT NULL,"
            , "  -- What the artifact is for: a file's kind, or a URL's."
            , "  kind               TEXT    NOT NULL"
            , "                     CONSTRAINT artifacts_kind_enum CHECK ("
            , "                       kind IN " <> artifactKinds <> "),"
            , "  -- file: a path on this machine. url: a web address."
            , "  location_kind      TEXT    NOT NULL"
            , "                     CONSTRAINT artifacts_location_kind_enum CHECK (location_kind IN "
                <> spellings locationKindName
                <> "),"
            , "  -- The file's absolute path at registration. Set only when file."
            , "  path               TEXT,"
            , "  -- SHA-256 of the file as read at registration, 64 lowercase hex. Set only when file."
            , "  sha256             TEXT,"
            , "  -- The file's size in bytes at registration. Set only when file."
            , "  size_bytes         INTEGER,"
            , "  -- The web address. Set only when url."
            , "  url                TEXT,"
            , "  -- The span of the agent that made the artifact. prov:wasGeneratedBy. Optional: the lead or the user made it."
            , "  span_id            INTEGER,"
            , "  -- The artifact this one was made from. prov:wasDerivedFrom. Optional: most have no source."
            , "  source_artifact_id INTEGER,"
            , "  PRIMARY KEY (run_id, id),"
            , "  FOREIGN KEY (run_id, id) REFERENCES events (run_id, seq),"
            , "  FOREIGN KEY (run_id, span_id) REFERENCES spans (run_id, id),"
            , "  FOREIGN KEY (run_id, source_artifact_id) REFERENCES artifacts (run_id, id),"
            , "  CONSTRAINT artifacts_path_iff_file CHECK ((path IS NOT NULL) = (location_kind = 'file')),"
            , "  CONSTRAINT artifacts_sha256_iff_file CHECK ((sha256 IS NOT NULL) = (location_kind = 'file')),"
            , "  CONSTRAINT artifacts_size_bytes_iff_file CHECK ((size_bytes IS NOT NULL) = (location_kind = 'file')),"
            , "  CONSTRAINT artifacts_url_iff_url CHECK ((url IS NOT NULL) = (location_kind = 'url')),"
            , "  CONSTRAINT artifacts_source_artifact_id_not_self CHECK (source_artifact_id IS NOT id)"
            ]
  where
    -- A file's kinds, then a URL's: both spell their other kind @other@.
    artifactKinds =
        enumIn
            ( nub
                ( map fileKindText [minBound .. maxBound]
                    <> map urlKindText [minBound .. maxBound]
                )
            )

handovers :: Table
handovers =
    strictTable
        "handovers"
        [ "  -- A session's note to the next session of the same run. The session is the event's session_id."
        , ""
        , "  -- The run."
        , "  run_id  TEXT    NOT NULL REFERENCES runs (id),"
        , "  -- The seq of the handover event."
        , "  id      INTEGER NOT NULL,"
        , "  -- Why the session hands over. context: its context is full. user: the user asked. crash: written for a session that died."
        , "  reason  TEXT    NOT NULL"
        , "          CONSTRAINT handovers_reason_enum CHECK (reason IN "
            <> spellings handoverReasonText
            <> "),"
        , "  -- Where the work stands, in the session's words."
        , "  summary TEXT    NOT NULL,"
        , "  PRIMARY KEY (run_id, id),"
        , "  FOREIGN KEY (run_id, id) REFERENCES events (run_id, seq)"
        ]

handoverNextSteps :: Table
handoverNextSteps =
    strictTable
        "handover_next_steps"
        [ "  -- What the next session should do first, in order."
        , ""
        , "  -- The run."
        , "  run_id      TEXT    NOT NULL REFERENCES runs (id),"
        , "  -- The handover: handovers.id."
        , "  handover_id INTEGER NOT NULL,"
        , "  -- The place of this step in the list, from 1."
        , "  ordinal     INTEGER NOT NULL,"
        , "  -- One thing to do, ideally a command."
        , "  next_step   TEXT    NOT NULL,"
        , "  PRIMARY KEY (run_id, handover_id, ordinal),"
        , "  FOREIGN KEY (run_id, handover_id) REFERENCES handovers (run_id, id)"
        ]

stopgaps :: Table
stopgaps =
    strictTable
        "stopgaps"
        [ "  -- A fact an agent recorded when no typed command fit, by key, for the run or one of its tasks."
        , "  -- One row per stopgap in force, at its newest value. An unset one leaves the table;"
        , "  -- the run's log keeps every event. Nothing the kernel decides reads a stopgap."
        , ""
        , "  -- The run."
        , "  run_id       TEXT    NOT NULL REFERENCES runs (id),"
        , "  -- The seq of the stopgap_set event that set this value."
        , "  id           INTEGER NOT NULL,"
        , "  -- The breakdown of the task the stopgap is for. NULL: the run's own."
        , "  -- No foreign key to tasks: the log may name a task no breakdown holds."
        , "  breakdown_id INTEGER,"
        , "  -- The task the stopgap is for. Set only with breakdown_id."
        , "  task_id      TEXT,"
        , "  -- The key, as OpenTelemetry names attributes, such as deploy.window."
        , "  key          TEXT    NOT NULL,"
        , "  -- The value: I-JSON (RFC 7493) text."
        , "  value        TEXT    NOT NULL"
        , "               CONSTRAINT stopgaps_value_json CHECK (json_valid(value)),"
        , "  -- Why it was set."
        , "  reason       TEXT    NOT NULL,"
        , "  PRIMARY KEY (run_id, id),"
        , "  FOREIGN KEY (run_id, id) REFERENCES events (run_id, seq),"
        , "  CONSTRAINT stopgaps_task_id_iff_breakdown_id CHECK ((task_id IS NOT NULL) = (breakdown_id IS NOT NULL))"
        ]
