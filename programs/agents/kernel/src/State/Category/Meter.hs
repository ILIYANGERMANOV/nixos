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
    Owed (..),
    owedBy,
    someMeterName,
) where

import Control.Monad (join)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Type.Equality ((:~:) (..))
import Data.Typeable (eqT)
import Numeric.Natural (Natural)
import State.Category.Step (LegOf (..), Outcome, Sig, Sing, SomeOutcome (..), StepSet (..))

{- | What a step records at its own state that a meter may count: one of its
outcomes, or a question the run asks there (an interview's question is an
@asked@ event, not an outcome).
-}
data Spend (s :: k) where
    Ends :: LegOf (Sig s) l -> Outcome s l -> Spend s
    Asks :: Spend s

{- | A step that spends a budget: its row name in the Fuel table, and what
each event costs. 'Owes' says whether a spend starts a child that hands
back ('State.Category.Flow.Fork'): only then may the step's outcomes be a
spawn and a hand-back ('Owed').
-}
class (StepSet k) => Meter (s :: k) where
    type Owes s :: Bool
    type Owes s = 'False
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

-- | What an event does to the children a meter's step owes.
data Owed = Opens | Closes
    deriving stock (Eq, Show)

{- | The child the event opens or closes, by its leg: none for another
step's outcome, as for 'spentBy'.
-}
owedBy :: SomeMeter -> Recorded -> Maybe Owed
owedBy (SomeMeter s) = \case
    RecordedAsk -> Nothing
    RecordedOutcome some -> join (ownOutcome s some (\leg _ -> owed leg))
  where
    owed :: LegOf sig l -> Maybe Owed
    owed = \case
        ByOpening -> Just Opens
        ByClosing -> Just Closes
        ByExit -> Nothing
        ByContinuing -> Nothing
        ByTaking -> Nothing

-- | An event a run records at a metered state, its step's kind hidden.
data Recorded where
    RecordedOutcome :: (StepSet k) => SomeOutcome k -> Recorded
    RecordedAsk :: Recorded

{- | What the event spends of the meter. An outcome of another step spends
nothing: the graph keeps a meter at its own step's state, so a run records
none there.
-}
spentBy :: SomeMeter -> Recorded -> Natural
spentBy (SomeMeter s) = \case
    RecordedAsk -> spends s Asks
    RecordedOutcome some -> fromMaybe 0 (ownOutcome s some (\leg o -> spends s (Ends leg o)))

-- | What the step makes of the outcome, when it is one of its own: of another step, nothing.
ownOutcome :: forall k j (s :: k) r. (StepSet k, StepSet j) => Sing s -> SomeOutcome j -> (forall l. LegOf (Sig s) l -> Outcome s l -> r) -> Maybe r
ownOutcome s (SomeOutcome t leg o) own = case eqT @k @j of
    Just Refl -> case sameStep s t of
        Just Refl -> Just (own leg o)
        Nothing -> Nothing
    Nothing -> Nothing
