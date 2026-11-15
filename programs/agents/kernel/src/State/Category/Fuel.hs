{- | How much a run spends: the user's one knob, Fuel, the tokens and time a
task may take, and the monotone map 'cfg' to the loop budgets and shortcuts
each level allows. A brief spells it @Fuel: <level>@.
-}
module State.Category.Fuel (
    Fuel (..),
    fuelName,
    fuelLabel,
    parseFuel,
    parseByName,
    SkipWhen (..),
    Area (..),
    Cfg (..),
    cfg,
    cfgLeq,
    reReviews,
) where

import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import State.Category.Flow (FanId (..), LoopId (..), OptId (..))

-- | Ordered by spend: 'cfg' is monotone in this order ('cfgLeq').
data Fuel = Low | Balanced | Max
    deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The wire name, as @state record fuel@ and a task's JSON spell it.
fuelName :: Fuel -> Text
fuelName = \case
    Low -> "low"
    Balanced -> "balanced"
    Max -> "max"

-- | The name a brief's @Fuel:@ line and the Fuel table spell.
fuelLabel :: Fuel -> Text
fuelLabel = Text.toTitle . fuelName

-- | Exact spelling only: a misspelled level is not silently a default.
parseFuel :: Text -> Maybe Fuel
parseFuel = parseByName fuelName

{- | The value whose wire name is exactly the given text, for any enum named by
a total function, so a name and its parser cannot drift.
-}
parseByName :: (Bounded a, Enum a) => (a -> Text) -> Text -> Maybe a
parseByName name raw = lookup raw [(name value, value) | value <- [minBound .. maxBound]]

{- | When a level lets an 'OptId' be skipped. 'AtOrBelow' counts the branch's
changed lines, and the kernel records that skip itself. 'Skippable' is the
agent's call: it records the skip when the task is trivial, and runs the step
otherwise.
-}
data SkipWhen = Never | AtOrBelow Natural | Skippable
    deriving stock (Eq, Show)

-- | The areas whose fix gets a full review rather than a quick one.
data Area = Interface | DataModel | Auth
    deriving stock (Eq, Ord, Show, Enum, Bounded)

{- | The four things a level sets, and nothing else. Functions rather than
maps: every id has a value, so no lookup can miss.
-}
data Cfg = Cfg
    { skip :: OptId -> SkipWhen
    , rounds :: LoopId -> Natural
    , fan :: FanId -> Natural
    , areas :: Set Area
    }

-- | The Fuel table: review rounds and full-review areas as #351 set them.
cfg :: Fuel -> Cfg
cfg fuel =
    Cfg
        { skip = skipWhen fuel
        , rounds = \case
            LReview -> 1 + reReviews fuel
            LGather -> 6
            LPlan -> 4
            LCi -> 6
        , fan = \case
            FResearchers -> researchers fuel
            FEngineers -> 3
        , areas = fullReview fuel
        }

{- | Low may skip research, the plan's simplify and the refactor of a trivial
task; Confirm is asked at every level. @simplify_pr@ and @ready@ are never
skipped.
-}
skipWhen :: Fuel -> OptId -> SkipWhen
skipWhen fuel = \case
    ORes -> skippableAtLow
    OSimp -> skippableAtLow
    ORefactor -> case fuel of
        Low -> Skippable
        Balanced -> AtOrBelow refactorLines
        Max -> Never
    OBody -> Never
    OReady -> Never
  where
    skippableAtLow = case fuel of
        Low -> Skippable
        Balanced -> Never
        Max -> Never

-- | Changed lines at or below which Balanced skips the refactor.
refactorLines :: Natural
refactorLines = 100

-- | Review rounds after the first, @n(m)@ of #351; the loop's rounds are @n(m) + 1@.
reReviews :: Fuel -> Natural
reReviews = \case
    Low -> 1
    Balanced -> 3
    Max -> 5

researchers :: Fuel -> Natural
researchers = \case
    Low -> 1
    Balanced -> 3
    Max -> 6

-- | #351 decided interface fixes get a full review at the top level only.
fullReview :: Fuel -> Set Area
fullReview = \case
    Low -> Set.fromList [DataModel, Auth]
    Balanced -> Set.fromList [DataModel, Auth]
    Max -> Set.fromList [Interface, DataModel, Auth]

{- | The order 'cfg' must keep: the higher 'Cfg' skips less, and has at least
the rounds, the fan-out and the areas.
-}
cfgLeq :: Cfg -> Cfg -> Bool
cfgLeq lower higher =
    all (\optId -> skipsAtMost (higher.skip optId) (lower.skip optId)) [minBound .. maxBound]
        && all (\loopId -> lower.rounds loopId <= higher.rounds loopId) [minBound .. maxBound]
        && all (\fanId -> lower.fan fanId <= higher.fan fanId) [minBound .. maxBound]
        && lower.areas `Set.isSubsetOf` higher.areas

-- | @skipsAtMost a b@: @a@ skips in no case where @b@ runs.
skipsAtMost :: SkipWhen -> SkipWhen -> Bool
skipsAtMost a b = case (a, b) of
    (Never, _) -> True
    (AtOrBelow _, Never) -> False
    (AtOrBelow n, AtOrBelow n') -> n <= n'
    (AtOrBelow _, Skippable) -> True
    (Skippable, Never) -> False
    (Skippable, AtOrBelow _) -> False
    (Skippable, Skippable) -> True
