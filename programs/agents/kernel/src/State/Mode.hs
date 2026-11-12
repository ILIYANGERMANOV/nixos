{- | How much work a run does: #351's category @Mode@, the product poset
Quality x Size, and the monotone map 'cfg' to what a mode sets. Quality is the
user's knob, spelled on the wire as a brief's @Quality: <mode>@ line.
-}
module State.Mode (
    Quality (..),
    qualityName,
    parseQuality,
    Size (..),
    sizeName,
    parseSize,
    Mode (..),
    modes,
    leq,
    SkipWhen (..),
    Area (..),
    Cfg (..),
    cfg,
    cfgLeq,
) where

import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Numeric.Natural (Natural)
import State.Flow (FanId (..), LoopId (..), OptId (..))

{- | No 'Ord' on purpose: the mode order of #351 is its own definition ('leq'),
not the order the constructors happen to be written in.
-}
data Quality = Poc | Balanced | Max
    deriving stock (Eq, Show, Enum, Bounded)

-- | The wire name, as a brief and the Quality table spell it.
qualityName :: Quality -> Text
qualityName = \case
    Poc -> "POC"
    Balanced -> "Balanced"
    Max -> "Max"

-- | Exact spelling only: a misspelled mode is not silently a default.
parseQuality :: Text -> Maybe Quality
parseQuality name = lookup name [(qualityName quality, quality) | quality <- [minBound .. maxBound]]

-- | No 'Ord', as for 'Quality'.
data Size = Trivial | Normal
    deriving stock (Eq, Show, Enum, Bounded)

-- | The wire name, as a brief's @Size: <size>@ line spells it.
sizeName :: Size -> Text
sizeName = \case
    Trivial -> "Trivial"
    Normal -> "Normal"

parseSize :: Text -> Maybe Size
parseSize name = lookup name [(sizeName size, size) | size <- [minBound .. maxBound]]

data Mode = Mode Quality Size
    deriving stock (Eq, Show)

-- | All six.
modes :: [Mode]
modes = Mode <$> [minBound .. maxBound] <*> [minBound .. maxBound]

-- | The product order: @leq m m'@ when @m'@ does at least the work of @m@.
leq :: Mode -> Mode -> Bool
leq (Mode quality size) (Mode quality' size') =
    qualityRank quality <= qualityRank quality' && sizeRank size <= sizeRank size'
  where
    qualityRank = \case
        Poc -> 0 :: Int
        Balanced -> 1
        Max -> 2
    sizeRank = \case
        Trivial -> 0 :: Int
        Normal -> 1

-- | When a mode skips an 'OptId'. 'AtOrBelow' counts the branch's changed lines.
data SkipWhen = Never | AtOrBelow Natural | Always
    deriving stock (Eq, Show)

-- | The areas whose fix gets a full review rather than a quick one.
data Area = Interface | DataModel | Auth
    deriving stock (Eq, Ord, Show, Enum, Bounded)

{- | The four things a mode sets, and nothing else. Functions rather than
maps: every id has a value, so no lookup can miss.
-}
data Cfg = Cfg
    { skip :: OptId -> SkipWhen
    , fuel :: LoopId -> Natural
    , fan :: FanId -> Natural
    , areas :: Set Area
    }

-- | The mode table of #360, with #351's review fuel and full-review areas.
cfg :: Mode -> Cfg
cfg (Mode quality size) =
    Cfg
        { skip = skipWhen quality size
        , fuel = \case
            LReview -> 1 + reReviews quality size
            LGather -> 6
            LPlan -> 4
            LCi -> 6
        , fan = \case
            FResearchers -> researchers quality size
            FEngineers -> 3
        , areas = fullReview quality
        }

{- | Trivial skips every optional step before the PR. @simplify_pr@ is never
skipped, and @ready@ follows Quality alone: POC leaves a draft.
-}
skipWhen :: Quality -> Size -> OptId -> SkipWhen
skipWhen quality size = \case
    ORes -> unlessTrivial Never
    OSimp -> unlessTrivial Never
    OAlt -> unlessTrivial $ case quality of
        Poc -> Always
        Balanced -> Never
        Max -> Never
    ORefactor -> unlessTrivial $ case quality of
        Poc -> AtOrBelow refactorLines
        Balanced -> AtOrBelow refactorLines
        Max -> Never
    OBody -> Never
    OReady -> case quality of
        Poc -> Always
        Balanced -> Never
        Max -> Never
  where
    unlessTrivial normal = case size of
        Trivial -> Always
        Normal -> normal

{- | Changed lines at or below which POC and Balanced skip the refactor. POC
skips too, unlike the Python @state@: a POC that refactors where Balanced does
not breaks Monotone.
-}
refactorLines :: Natural
refactorLines = 100

-- | Review rounds after the first, @n(m)@ of #351; the loop's fuel is @n(m) + 1@.
reReviews :: Quality -> Size -> Natural
reReviews quality = \case
    Trivial -> 0
    Normal -> case quality of
        Poc -> 2
        Balanced -> 3
        Max -> 5

researchers :: Quality -> Size -> Natural
researchers quality = \case
    Trivial -> 1
    Normal -> case quality of
        Poc -> 1
        Balanced -> 3
        Max -> 6

-- | #351 decided POC loses interface, so the areas grow with Quality.
fullReview :: Quality -> Set Area
fullReview = \case
    Poc -> Set.fromList [DataModel, Auth]
    Balanced -> Set.fromList [DataModel, Auth]
    Max -> Set.fromList [Interface, DataModel, Auth]

{- | The order 'cfg' must keep: the higher 'Cfg' skips less, and has at least
the fuel, the fan-out and the areas.
-}
cfgLeq :: Cfg -> Cfg -> Bool
cfgLeq lower higher =
    all (\optId -> skipsAtMost (higher.skip optId) (lower.skip optId)) [minBound .. maxBound]
        && all (\loopId -> lower.fuel loopId <= higher.fuel loopId) [minBound .. maxBound]
        && all (\fanId -> lower.fan fanId <= higher.fan fanId) [minBound .. maxBound]
        && lower.areas `Set.isSubsetOf` higher.areas

-- | @skipsAtMost a b@: @a@ skips in no case where @b@ runs.
skipsAtMost :: SkipWhen -> SkipWhen -> Bool
skipsAtMost a b = case (a, b) of
    (Never, _) -> True
    (AtOrBelow _, Never) -> False
    (AtOrBelow n, AtOrBelow n') -> n <= n'
    (AtOrBelow _, Always) -> True
    (Always, Never) -> False
    (Always, AtOrBelow _) -> False
    (Always, Always) -> True
