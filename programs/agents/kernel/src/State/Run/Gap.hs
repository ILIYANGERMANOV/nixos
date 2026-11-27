{- | A gap: a flaw a run met in the flow, its prose or its tools, typed so a
report can rank it, and where its fix stands (#552's Appendix B, Gaps). A
gap is logged open; a status event moves it along 'transition', in the
gap's own run, whatever state that run is in. A closed gap stays closed: a
gap that comes back is a new gap, its evidence pointing at the old one.
-}
module State.Run.Gap (
    Gap (..),
    GapKind (..),
    gapKindText,
    Severity (..),
    severityText,
    GapArea (..),
    Evidence (..),
    parseGapText,
    GapDraft (..),
    draft,
    filed,
    GapLine (..),
    parseGapLine,
    gapLineText,
    gapLineRule,
    lineGap,
    GapStatus (..),
    Closure (..),
    GapMove (..),
    Transition (..),
    transition,
    Tracked (..),
    isOpen,
) where

import Data.Char (isSpace)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import State.Artifact (Uri)
import State.Category.Flow (AgentRole)
import State.Category.Fuel (parseByName)
import State.Run.Ask (OneLine, oneLineText, parseOneLine)
import State.Run.Id (EventRef)

data Gap = Gap
    { kind :: GapKind
    , severity :: Severity
    , area :: GapArea
    , text :: OneLine
    -- ^ Never empty: 'parseGapText' builds it.
    , reporter :: AgentRole
    -- ^ The role that saw it: the run's lead, or the worker whose hand-back named it.
    , evidence :: [Evidence]
    -- ^ In the order given (POSIX Guideline 11 for a repeated option).
    }
    deriving stock (Eq, Show)

data GapKind = Kernel | Prose | Tool | Permission | Ci | Process | Other
    deriving stock (Eq, Show, Enum, Bounded)

-- | A gap kind as the log, the CLI and a hand-back's @Gap:@ line spell it.
gapKindText :: GapKind -> Text
gapKindText = \case
    Kernel -> "kernel"
    Prose -> "prose"
    Tool -> "tool"
    Permission -> "permission"
    Ci -> "ci"
    Process -> "process"
    Other -> "other"

-- | Worst first: the order @state resume@ lists open gaps in.
data Severity = Blocker | Slowdown | Papercut
    deriving stock (Eq, Ord, Show, Enum, Bounded)

severityText :: Severity -> Text
severityText = \case
    Blocker -> "blocker"
    Slowdown -> "slowdown"
    Papercut -> "papercut"

{- | Where the gap was met: by default the step the run was at, or a hand-back
closed; any word @--area@ gives.
-}
newtype GapArea = GapArea {areaText :: Text}
    deriving stock (Eq, Show)

-- | What shows the gap: a line of any run, as an artifact's line names a file, or a URL.
data Evidence = OfEvent EventRef | OfUrl Uri
    deriving stock (Eq, Show)

-- | A gap's text: one line, not blank.
parseGapText :: Text -> Maybe OneLine
parseGapText raw
    | Text.null (Text.strip raw) = Nothing
    | otherwise = parseOneLine raw

{- | A gap as @state record gap@ gives it, before the run fills in the area
it left out and the reporter.
-}
data GapDraft = GapDraft
    { kind :: GapKind
    , severity :: Severity
    , area :: Maybe GapArea
    , text :: OneLine
    , evidence :: [Evidence]
    }
    deriving stock (Eq, Show)

-- | A bare gap's defaults (#552's Appendix B): kind other, severity slowdown, no evidence.
draft :: OneLine -> GapDraft
draft text = GapDraft Other Slowdown Nothing text []

-- | The gap a draft logs, met here by this role.
filed :: GapArea -> AgentRole -> GapDraft -> Gap
filed here reporter d =
    Gap
        { kind = d.kind
        , severity = d.severity
        , area = fromMaybe here d.area
        , text = d.text
        , reporter
        , evidence = d.evidence
        }

{- | A hand-back's @Gap: <kind> <severity> <text>@ line, or one whose words
do not read so: never refused, it logs the whole value with the defaults.
-}
data GapLine = WellFormed GapKind Severity OneLine | Malformed OneLine
    deriving stock (Eq, Show)

-- | The value after @Gap:@; a blank one is no gap.
parseGapLine :: Text -> Maybe GapLine
parseGapLine raw =
    case ( parseByName gapKindText kindWord
         , parseByName severityText severityWord
         , parseGapText (Text.strip rest)
         ) of
        (Just kind, Just severity, Just text) -> Just (WellFormed kind severity text)
        _ -> Malformed <$> parseGapText value
  where
    value = Text.strip raw
    (kindWord, afterKind) = word value
    (severityWord, rest) = word afterKind
    word = Text.break isSpace . Text.stripStart

-- | The value a @Gap:@ line holds, as 'parseGapLine' reads it back.
gapLineText :: GapLine -> Text
gapLineText = \case
    WellFormed kind severity text ->
        Text.unwords [gapKindText kind, severityText severity, oneLineText text]
    Malformed text -> oneLineText text

-- | The words a @Gap:@ line takes, as a malformed one is told.
gapLineRule :: Text
gapLineRule =
    "Gap: <kind> <severity> <text>, kind "
        <> choices gapKindText
        <> ", severity "
        <> choices severityText
  where
    choices :: (Bounded a, Enum a) => (a -> Text) -> Text
    choices name = Text.intercalate "|" (map name [minBound .. maxBound])

-- | The gap a hand-back's line logs, met at the step it closes by the worker that sent it.
lineGap :: GapArea -> AgentRole -> GapLine -> Gap
lineGap here reporter = \case
    WellFormed kind severity text -> filed here reporter (GapDraft kind severity Nothing text [])
    Malformed text -> filed here reporter (draft text)

-- | Where a gap's fix stands.
data GapStatus = Open | FixProposed Uri | Closed Closure
    deriving stock (Eq, Show)

-- | How a gap closed: fixed by a PR, or left as it is, and why.
data Closure = Fixed Uri | WontFix OneLine
    deriving stock (Eq, Show)

-- | A status event: a fix proposed in a PR, or the gap closed.
data GapMove = Propose Uri | Close Closure
    deriving stock (Eq, Show)

-- | What a status event does to a gap.
data Transition
    = To GapStatus
    | -- | The PR proposed already is proposed again: a no-op.
      Again
    | -- | The gap closed already, so: every move is refused.
      Shut Closure
    deriving stock (Eq, Show)

{- | Appendix B's gap table: an open gap or one with a fix proposed takes
every move, a new PR replacing the last; a closed one takes none.
-}
transition :: GapStatus -> GapMove -> Transition
transition status move = case status of
    Closed closure -> Shut closure
    Open -> To (after move)
    FixProposed current -> case move of
        Propose pr | pr == current -> Again
        Propose _ -> To (after move)
        Close _ -> To (after move)
  where
    after = \case
        Propose pr -> FixProposed pr
        Close closure -> Closed closure

-- | A gap the run logged, and where its fix stands.
data Tracked = Tracked {gap :: Gap, status :: GapStatus}
    deriving stock (Eq, Show)

-- | Open, or a fix proposed and not yet merged: still a gap.
isOpen :: GapStatus -> Bool
isOpen = \case
    Open -> True
    FixProposed _ -> True
    Closed _ -> False
