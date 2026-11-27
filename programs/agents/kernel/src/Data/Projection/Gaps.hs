{- | The gaps projection (#552 Appendix A): the friction each run logged
(@gaps@), where its fix stands, and what backs it (@gap_evidence@). Every
row is the last state's of the trace: a gap is never dropped, and its
status is the newest the fold took.
-}
module Data.Projection.Gaps (
    projection,
    rows,
    GapRow (..),
    gapInsert,
    evidenceInserts,
    openStatuses,
) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Projection (
    Insert (..),
    Projection (..),
    Table,
    Value (..),
    integer,
    nullable,
    spellings,
    strictTable,
 )
import Data.Text (Text)
import Numeric.Natural (Natural)
import State.Artifact (uriText)
import State.Category.Flow (roleText)
import State.Run.Ask (oneLineText)
import State.Run.Event (Envelope, RunId, runIdText)
import State.Run.Fold (RunState (..))
import State.Run.Gap (
    Closure (..),
    Evidence (..),
    Gap (..),
    GapStatus (..),
    StatusCase (..),
    Tracked (..),
    gapAreaText,
    gapKindText,
    gapTextText,
    openCase,
    severityText,
    statusCase,
 )
import State.Run.Id (EventRef (..))

projection :: Projection
projection =
    Projection
        { name = "gaps"
        , version = 1
        , tables = gaps :| [gapEvidence]
        }

-- | The run's rows in every table of this projection, from its trace.
rows :: NonEmpty (Envelope, RunState) -> [Insert]
rows trace =
    concat [gapInsert row : evidenceInserts row | row <- gapRows]
  where
    final = snd (NonEmpty.last trace)
    gapRows = [GapRow final.run n tracked | (n, tracked) <- final.gaps]

-- | A gap the run logged, by the seq of its @gap@ line, and where its fix stands.
data GapRow = GapRow {runId :: RunId, id :: Natural, tracked :: Tracked}
    deriving stock (Eq, Show)

-- | A gap's status as its row spells it.
gapStatusName :: StatusCase -> Text
gapStatusName = \case
    OpenCase -> "open"
    FixProposedCase -> "fix_proposed"
    FixedCase -> "fixed"
    WontFixCase -> "wont_fix"

{- | The spellings of the statuses 'openCase' holds open: the runs report
counts a run's open gaps by them, so open has one definition.
-}
openStatuses :: [Text]
openStatuses = [gapStatusName c | c <- [minBound .. maxBound], openCase c]

data EvidenceKind = EventEvidence | UrlEvidence
    deriving stock (Eq, Show, Enum, Bounded)

evidenceKindName :: EvidenceKind -> Text
evidenceKindName = \case
    EventEvidence -> "event"
    UrlEvidence -> "url"

gapInsert :: GapRow -> Insert
gapInsert row =
    Insert
        "gaps"
        ( ("run_id", SqlText (runIdText row.runId))
            :| [ ("id", integer row.id)
               , ("kind", SqlText (gapKindText gap.kind))
               , ("severity", SqlText (severityText gap.severity))
               , ("area", SqlText (gapAreaText gap.area))
               , ("text", SqlText (gapTextText gap.text))
               , ("reporter_role", SqlText (roleText gap.reporter))
               , ("status", SqlText (gapStatusName (statusCase row.tracked.status)))
               , ("fix_pr_url", nullable (SqlText . uriText) pr)
               , ("wont_fix_reason", nullable (SqlText . oneLineText) why)
               ]
        )
  where
    gap = row.tracked.gap
    (pr, why) = case row.tracked.status of
        Open -> (Nothing, Nothing)
        FixProposed url -> (Just url, Nothing)
        Closed (Fixed url) -> (Just url, Nothing)
        Closed (WontFix reason) -> (Nothing, Just reason)

-- | Each piece of a gap's evidence, in the order given, from 1.
evidenceInserts :: GapRow -> [Insert]
evidenceInserts row =
    [ Insert
        "gap_evidence"
        ( ("run_id", SqlText (runIdText row.runId))
            :| [ ("gap_id", integer row.id)
               , ("ordinal", integer ordinal)
               , ("kind", SqlText (evidenceKindName kind))
               , ("event_run_id", nullable (SqlText . runIdText . (.run)) event)
               , ("event_seq", nullable (integer . (.seq)) event)
               , ("url", nullable (SqlText . uriText) url)
               ]
        )
    | (ordinal, evidence) <- zip [1 :: Natural ..] row.tracked.gap.evidence
    , let (kind, event, url) = case evidence of
            OfEvent ref -> (EventEvidence, Just ref, Nothing)
            OfUrl uri -> (UrlEvidence, Nothing, Just uri)
    ]

gaps :: Table
gaps =
    strictTable
        "gaps"
        [ "  -- Friction an agent hit with a flow, a skill or state itself."
        , ""
        , "  -- The run that recorded the gap."
        , "  run_id          TEXT    NOT NULL REFERENCES runs (id),"
        , "  -- The seq of the gap event."
        , "  id              INTEGER NOT NULL,"
        , "  -- Which part of the harness the gap is in."
        , "  kind            TEXT    NOT NULL"
        , "                  CONSTRAINT gaps_kind_enum CHECK ("
        , "                    kind IN " <> spellings gapKindText <> "),"
        , "  -- How much it hurt. blocker: the run could not go on. slowdown: it cost time or tokens. papercut: an annoyance."
        , "  severity        TEXT    NOT NULL"
        , "                  CONSTRAINT gaps_severity_enum CHECK (severity IN "
            <> spellings severityText
            <> "),"
        , "  -- The step, skill or command the gap is in."
        , "  area            TEXT    NOT NULL,"
        , "  -- What happened, in the reporter's words."
        , "  text            TEXT    NOT NULL,"
        , "  -- The role that reported it: the lead's, or the worker whose hand-back held a Gap: line."
        , "  reporter_role   TEXT    NOT NULL,"
        , "  -- open: nothing done. fix_proposed: a pull request is up. fixed: it merged. wont_fix: closed with a reason."
        , "  status          TEXT    NOT NULL"
        , "                  CONSTRAINT gaps_status_enum CHECK (status IN "
            <> spellings gapStatusName
            <> "),"
        , "  -- The pull request that fixes the gap. Set only when fix_proposed or fixed."
        , "  fix_pr_url      TEXT,"
        , "  -- Why the gap will not be fixed. Set only when wont_fix."
        , "  wont_fix_reason TEXT,"
        , "  PRIMARY KEY (run_id, id),"
        , "  FOREIGN KEY (run_id, id) REFERENCES events (run_id, seq),"
        , "  CONSTRAINT gaps_fix_pr_url_iff_fix_proposed_or_fixed CHECK ((fix_pr_url IS NOT NULL) = (status IN ('fix_proposed', 'fixed'))),"
        , "  CONSTRAINT gaps_wont_fix_reason_iff_wont_fix CHECK ((wont_fix_reason IS NOT NULL) = (status = 'wont_fix'))"
        ]

gapEvidence :: Table
gapEvidence =
    strictTable
        "gap_evidence"
        [ "  -- What backs a gap, in the order given: an event of any run, or a URL."
        , "  -- A registered file is an event too: its artifact event."
        , ""
        , "  -- The run of the gap."
        , "  run_id       TEXT    NOT NULL REFERENCES runs (id),"
        , "  -- The gap: gaps.id."
        , "  gap_id       INTEGER NOT NULL,"
        , "  -- The place of this piece in the gap's evidence list, from 1."
        , "  ordinal      INTEGER NOT NULL,"
        , "  -- event: an event in the store. url: a web address."
        , "  kind         TEXT    NOT NULL"
        , "               CONSTRAINT gap_evidence_kind_enum CHECK (kind IN "
            <> spellings evidenceKindName
            <> "),"
        , "  -- The run of the event. Set only when event."
        , "  -- No foreign key: the reporter typed the reference, and the command checks it."
        , "  event_run_id TEXT,"
        , "  -- The seq of the event. Set only when event."
        , "  event_seq    INTEGER,"
        , "  -- The web address. Set only when url."
        , "  url          TEXT,"
        , "  PRIMARY KEY (run_id, gap_id, ordinal),"
        , "  FOREIGN KEY (run_id, gap_id) REFERENCES gaps (run_id, id),"
        , "  CONSTRAINT gap_evidence_event_run_id_iff_event CHECK ((event_run_id IS NOT NULL) = (kind = 'event')),"
        , "  CONSTRAINT gap_evidence_event_seq_iff_event CHECK ((event_seq IS NOT NULL) = (kind = 'event')),"
        , "  CONSTRAINT gap_evidence_url_iff_url CHECK ((url IS NOT NULL) = (kind = 'url'))"
        ]
