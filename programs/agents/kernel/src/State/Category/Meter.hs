{- | A step's meter (decision 13): what one event the step records spends
of a budget the term caps ('State.Category.Flow.Capped'). A step with no
'Meter' instance cannot be capped, so every budget names what it counts.
-}
module State.Category.Meter (
    Meter (..),
    Spend (..),
    Limit (..),
    limitAtMost,
    allowed,
    AtCap (..),
    SomeMeter (..),
    Recorded (..),
    spentBy,
    someMeterName,
) where

import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Type.Equality ((:~:) (..))
import Data.Typeable (eqT)
import Numeric.Natural (Natural)
import State.Category.Step (LegOf, Outcome, Sig, Sing, SomeOutcome (..), StepSet (..))

{- | What a step records at its own state that a meter may count: one of its
outcomes, or a question the run asks there (an interview's question is an
@asked@ event, not an outcome).
-}
data Spend (s :: k) where
    Ends :: LegOf (Sig s) l -> Outcome s l -> Spend s
    Asks :: Spend s

-- | A step that spends a budget: its row name in the Fuel table, and what each event costs.
class (StepSet k) => Meter (s :: k) where
    meterName :: Sing s -> Text
    spends :: Sing s -> Spend s -> Natural

-- | How much a budget allows at one level: a count, or one per group of the plan, which the agent counts.
data Limit = UpTo Natural | PerGroup
    deriving stock (Eq, Show)

-- | @limitAtMost a b@: @a@ allows no more than @b@. A 'PerFuel' 'Limit' is monotone by it.
limitAtMost :: Limit -> Limit -> Bool
limitAtMost a b = case (a, b) of
    (UpTo n, UpTo m) -> n <= m
    (UpTo _, PerGroup) -> True
    (PerGroup, UpTo _) -> False
    (PerGroup, PerGroup) -> True

-- | The count the kernel holds a spend to: none for 'PerGroup', which the kernel cannot count.
allowed :: Limit -> Maybe Natural
allowed = \case
    UpTo n -> Just n
    PerGroup -> Nothing

-- | What a spend past the cap does.
data AtCap
    = -- | The spend is refused: the agent takes another outcome.
      Refuse
    | -- | The run stops (@state stop rounds@) unless it takes another outcome.
      Stop
    | -- | The user is asked whether to go on: @extend@ grants the budget again.
      Extend
    deriving stock (Eq, Show, Enum, Bounded)

-- | A meter with its step's kind hidden, as the graph keeps it at the step's state.
data SomeMeter where
    SomeMeter :: (Meter s) => Sing (s :: k) -> SomeMeter

instance Show SomeMeter where
    showsPrec d (SomeMeter s) = showParen (d > 10) $ showString "SomeMeter " . showsPrec 11 (meterName s)

-- | Equal when of one step.
instance Eq SomeMeter where
    SomeMeter (a :: Sing (s :: k)) == SomeMeter (b :: Sing (t :: j)) = case eqT @k @j of
        Just Refl -> isJust (sameStep a b)
        Nothing -> False

someMeterName :: SomeMeter -> Text
someMeterName (SomeMeter s) = meterName s

-- | An event a run records at a metered state, its step's kind hidden.
data Recorded where
    RecordedOutcome :: (StepSet k) => SomeOutcome k -> Recorded
    RecordedAsk :: Recorded

{- | What the event spends of the meter. An outcome of another step spends
nothing: the graph keeps a meter at its own step's state, so a run records
none there.
-}
spentBy :: SomeMeter -> Recorded -> Natural
spentBy (SomeMeter (s :: Sing (s :: k))) = \case
    RecordedAsk -> spends s Asks
    RecordedOutcome (SomeOutcome (t :: Sing (t :: j)) leg o) -> case eqT @k @j of
        Just Refl -> case sameStep s t of
            Just Refl -> spends s (Ends leg o)
            Nothing -> 0
        Nothing -> 0
