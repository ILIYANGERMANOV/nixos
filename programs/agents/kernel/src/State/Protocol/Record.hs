{- | The grammar of @state record@: every event a lead records by hand, its
arguments' usage and their parser. The CLI parses it and the advice prints
it, from this one table.
-}
module State.Protocol.Record (
    Recording (..),
    Recordable (..),
    recordables,
    recordCommand,
    Args (..),
    option,
    options,
    choices,
) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Read (decimal)
import State.Category.Flow (FanId (FEngineers))
import State.Category.Mode (parseByName, parseQuality, qualityName, sizeName)
import State.Category.Step (EventName, builtEvent, eventText)
import State.Protocol.Handback (parseTouches)
import State.Run.Codec (judgementText)
import State.Run.Codec qualified as Codec
import State.Run.Event (Branch (..), Check (..), Commit (..), DraftPr (..), Event (..), Label (..), Picks (..), Requirement (..), Sha, TaskId (..), TaskState (..), Url (..), parseRunId, stepTook)
import State.Step.Build (Outcome (..), Sing (..))
import State.Step.Catalog qualified as Catalog
import State.Step.Fan (Outcome (..), Sing (..))
import State.Step.Gather (Outcome (..), Sing (..))
import State.Step.Plan (Outcome (..), Sing (..))
import State.Step.Review (Outcome (..), Sing (..))
import State.Step.Ship (Outcome (..), Sing (..))

{- | An event to record. Most carry the commit the worktree is at, which only
the shell can read; a breakdown is read from a file, by the shell too.
-}
data Recording = Plain Event | AtHead (Sha -> Event) | FromFile FilePath (Text -> Either Text Event)

-- | The @state record@ line for an event, its arguments' usage after it.
recordCommand :: EventName -> Text
recordCommand event = Text.strip ("state record " <> name <> " " <> foldMap (.args) [r | r <- recordables, r.name == name])
  where
    name = eventText event

-- | An event @state record@ takes: its name, its arguments' usage, and their parser.
data Recordable = Recordable {name :: Text, args :: Text, flags :: [Text], parse :: Args -> Either Text Recording}

-- | Every event a lead records by hand, in the order a run meets them.
recordables :: [Recordable]
recordables =
    [ stay "quality" ("<" <> choices qualityName <> ">") $ \case
        [raw] -> QualitySet <$> known "quality" parseQuality raw
        _ -> Left "one quality"
    , stay "size" ("<" <> choices sizeName <> ">") $ \case
        [raw] -> SizeSet <$> known "size" (parseByName sizeName) raw
        _ -> Left "one size"
    , stay "grew" "<why>" (fmap Grew . because)
    , outcome (builtEvent Research ResearchDone) "<n>" [] $ \a -> case a.positional of
        [raw] -> Plain . stepTook . ResearchDone <$> count raw
        _ -> Left "the number of researchers"
    , nothing ResearchSkipped
    , nothing InterviewEnough
    , nothing InterviewMore
    , outcome (builtEvent PlanS PlanDone) "<path>" [] $ \a -> case a.positional of
        [path] -> Right (Plain (stepTook (PlanDone (Text.unpack path))))
        _ -> Left "the plan's path"
    , nothing SimplifyPlanDone
    , nothing SimplifyPlanSkipped
    , nothing AlternativeDone
    , nothing AlternativeSkipped
    , nothing ConfirmConfirmed
    , nothing ConfirmAdjusted
    , outcome (builtEvent Draft DraftDone) "<url> <base> <branch>" [] $ \a -> case a.positional of
        [link, base, branch] -> Right (Plain (stepTook (DraftDone (DraftPr (Url link) (Branch base) (Branch branch)))))
        _ -> Left "the PR's url, base and branch"
    , -- As a hand-back with no Touches line reads: an implementer may have touched any area.
      commitAt Implement ImplementDone (Set.fromList [minBound .. maxBound])
    , atHead Refactor RefactorDone
    , outcome (builtEvent Refactor RefactorSkipped) "<why>" [] (fmap (Plain . stepTook . RefactorSkipped) . because . (.positional))
    , atHead Review ReviewClean
    , atHead Review ReviewRows
    , picks Pick PickFinal
    , picks Pick PickLoop
    , -- A fixer's hand-back with no Touches line touches no area.
      commitAt Fix FixDone Set.empty
    , atHead Describe DescribeDone
    , atHead SimplifyPR SimplifyPrDone
    , atHead SimplifyPR SimplifyPrSkipped
    , atHead AwaitCi AwaitCiGreen
    , outcome (builtEvent AwaitCi (uncurry AwaitCiRed)) "<check>..." [] $ \a -> case a.positional of
        check : more -> Right (AtHead (\sha -> stepTook (AwaitCiRed sha (fmap Check (check :| more)))))
        [] -> Left "the failing checks"
    , atHead FixPR FixPrDone
    , url Ready ReadyDone
    , url Ready ReadySkipped
    , outcome (builtEvent Breakdown BreakdownDone) "--tasks <file.json>" ["tasks"] $ \a -> case (a.positional, option "tasks" a) of
        ([], Just path) -> Right (FromFile (Text.unpack path) (fmap (stepTook . BreakdownDone) . Codec.decodeBreakdown))
        _ -> Left "the tasks file, as --tasks <file.json>"
    , nothing (FanDone FEngineers)
    , Recordable "task" "<id> <ci|review|merged> <pr> | <id> parked <why> [--pr <url>]" ["pr"] $ \a -> case a.positional of
        [task, state, pr] | Just moved <- lookup state Codec.prStates -> Right (Plain (TaskMoved (TaskId task) (moved (Url pr))))
        task : "parked" : why@(_ : _) -> Right (Plain (TaskMoved (TaskId task) (Parked (Text.unwords why) (Url <$> option "pr" a))))
        _ -> Left "the task, then ci, review or merged and its PR, or parked and why"
    , stay "held" "<task> <url>" $ \case
        [task, link] -> Right (Held (TaskId task) (Url link))
        _ -> Left "the task and the url"
    , stay "acted" "<task> <url>" $ \case
        [task, link] -> Right (ActedOn (TaskId task) (Url link))
        _ -> Left "the task and the held url acted on"
    , stay "spawning" "<task>" $ \case
        [task] -> Right (Spawning (TaskId task))
        _ -> Left "the task the engineer you spawn takes"
    , stay "resumed" "<child run>" $ \case
        [child] -> maybe (Left (child <> " is no run id")) (Right . Resumed) (parseRunId child)
        _ -> Left "the child run you resume"
    , url Merge MergeDone
    ]
  where
    stay name usageText build = Recordable name usageText [] (\a -> Plain <$> build a.positional)
    outcome event = Recordable (eventText event)
    nothing done = outcome (Catalog.outcomeEvent (Catalog.outcome done)) "" [] $ \a -> case a.positional of
        [] -> Right (Plain (stepTook done))
        _ -> Left "no arguments"
    atHead s done = outcome (builtEvent s done) "" [] $ \a -> case a.positional of
        [] -> Right (AtHead (stepTook . done))
        _ -> Left "no arguments: the head is HEAD"
    commitAt s done unstated = outcome (builtEvent s done) "[--touches <area>,...|none]" ["touches"] $ \a -> case a.positional of
        [] -> (\areas -> AtHead (\sha -> stepTook (done (Commit sha areas)))) <$> maybe (Right unstated) parseTouches (option "touches" a)
        _ -> Left "no arguments: the head is HEAD"
    picks s done = outcome (builtEvent s done) ("[--row <label>]... [--verdict <requirement>=<" <> choices judgementText <> ">]...") ["row", "verdict"] $ \a -> case a.positional of
        [] -> Plain . stepTook . done . Picks (Set.fromList (map Label (options "row" a))) . Map.fromList <$> traverse verdict (options "verdict" a)
        _ -> Left "rows and verdicts are options"
    url s done = outcome (builtEvent s done) "<url>" [] $ \a -> case a.positional of
        [raw] -> Right (Plain (stepTook (done (Url raw))))
        _ -> Left "the PR's url"
    because = \case
        [] -> Left "why"
        why -> Right (Text.unwords why)
    count raw = case decimal raw of
        Right (n, "") -> Right n
        _ -> Left (raw <> " is not a count")
    verdict raw = case Text.breakOnEnd "=" raw of
        (requirement, judgement) | Just r <- Text.stripSuffix "=" requirement, not (Text.null r) -> (Requirement r,) <$> known "verdict" (parseByName judgementText) judgement
        _ -> Left (raw <> " is not <requirement>=<verdict>")
    known :: Text -> (Text -> Maybe a) -> Text -> Either Text a
    known what parse raw = maybe (Left ("no " <> what <> " " <> raw)) Right (parse raw)

-- | Positionals and @--name value@ options, the only kind of flag there is.
data Args = Args {positional :: [Text], options :: [(Text, Text)]}

-- | The last value given, as a shell user retyping an option expects.
option :: Text -> Args -> Maybe Text
option name a = case options name a of
    [] -> Nothing
    values -> Just (last values)

options :: Text -> Args -> [Text]
options name a = [value | (key, value) <- a.options, key == name]

choices :: (Bounded a, Enum a) => (a -> Text) -> Text
choices name = Text.intercalate "|" (map name [minBound .. maxBound])
