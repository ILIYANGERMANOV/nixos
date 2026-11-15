{- | How much a run spends: the user's one knob, Fuel, the tokens and time a
task may take. A flow's term carries what each level allows as 'PerFuel'
values, each monotone ('monotone'); 'cfg' holds the rest. A brief spells it
@Fuel: <level>@.
-}
module State.Category.Fuel (
    Fuel (..),
    fuelName,
    fuelLabel,
    parseFuel,
    parseByName,
    PerFuel (..),
    atFuel,
    always,
    monotone,
    SkipWhen (..),
    skipsAtMost,
    Area (..),
    Cfg (..),
    cfg,
    cfgLeq,
) where

import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)

-- | Ordered by spend: every 'PerFuel' a flow carries is 'monotone' in this order.
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

{- | One value per level: a budget the term carries where it is spent, so
the term, not a table keyed by a global id, says what each level allows.
-}
data PerFuel a = PerFuel {low :: a, balanced :: a, max :: a}
    deriving stock (Eq, Show, Functor, Foldable, Traversable)

atFuel :: Fuel -> PerFuel a -> a
atFuel fuel values = case fuel of
    Low -> values.low
    Balanced -> values.balanced
    Max -> values.max

-- | The same at every level.
always :: a -> PerFuel a
always value = PerFuel value value value

{- | Each level allows at least what the one below does, by this order: more
Fuel never buys less work.
-}
monotone :: (a -> a -> Bool) -> PerFuel a -> Bool
monotone atMost values = atMost values.low values.balanced && atMost values.balanced values.max

{- | When a level lets an 'State.Category.Flow.Opt' be skipped. 'AtOrBelow'
counts the branch's changed lines, and the kernel records that skip itself.
'Skippable' is the agent's call: it records the skip when the task is
trivial, and runs the step otherwise.
-}
data SkipWhen = Never | AtOrBelow Natural | Skippable
    deriving stock (Eq, Show)

-- | @skipsAtMost a b@: @a@ skips in no case where @b@ runs. A 'PerFuel' 'SkipWhen' is monotone by its flip.
skipsAtMost :: SkipWhen -> SkipWhen -> Bool
skipsAtMost a b = case (a, b) of
    (Never, _) -> True
    (AtOrBelow _, Never) -> False
    (AtOrBelow n, AtOrBelow n') -> n <= n'
    (AtOrBelow _, Skippable) -> True
    (Skippable, Never) -> False
    (Skippable, AtOrBelow _) -> False
    (Skippable, Skippable) -> True

-- | The areas whose fix gets a full review rather than a quick one.
data Area = Interface | DataModel | Auth
    deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | What a level sets beyond the budgets its flow's term carries.
data Cfg = Cfg
    { areas :: Set Area
    , asks :: Natural
    -- ^ The questions an interview asks the user in one gather, research rounds aside.
    }

-- | Full-review areas as #351 set them, questions as #377 did.
cfg :: Fuel -> Cfg
cfg fuel =
    Cfg
        { areas = fullReview fuel
        , asks = case fuel of
            Low -> 15
            Balanced -> 30
            Max -> 50
        }

-- | #351 decided interface fixes get a full review at the top level only.
fullReview :: Fuel -> Set Area
fullReview = \case
    Low -> Set.fromList [DataModel, Auth]
    Balanced -> Set.fromList [DataModel, Auth]
    Max -> Set.fromList [Interface, DataModel, Auth]

-- | The order 'cfg' must keep: the higher 'Cfg' has at least the areas and the questions.
cfgLeq :: Cfg -> Cfg -> Bool
cfgLeq lower higher =
    lower.areas `Set.isSubsetOf` higher.areas
        && lower.asks <= higher.asks
