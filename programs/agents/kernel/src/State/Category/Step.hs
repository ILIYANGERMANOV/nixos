{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE UndecidableInstances #-}

{- | The arrows of #351's category @Cap@: the typed steps between its
artifact types. Each layer of steps ("State.Step.Gather" and its siblings) is
a 'StepSet': a promoted kind of steps, a singleton per step, each step's
signature, and its outcomes, typed by step and leg. A step is the bundle of
its outcome edges, exits first, the continuing one last.
-}
module State.Category.Step (
    StepSet (..),
    Sig3,
    DomOf,
    ExitOf,
    CodOf,
    Leg (..),
    LegOf (..),
    Fits (..),
    SomeOutcome (..),
    packed,
    outcomeEvent,
    payload,
    Decoder (..),
    decoderEvent,
    decodeWith,
    SomeStep (..),
    Special (..),
    StateName (..),
    stateNameText,
    OutcomeName (..),
    Outcomes (..),
    EventName (..),
    eventText,
    continueEvent,
    exitEvent,
    skipEvent,
    skippedOutcome,
    OutcomeEdge (..),
) where

import Data.Aeson (Object)
import Data.Aeson.Types (Parser, Series)
import Data.Kind (Constraint, Type)
import Data.Text (Text)
import Data.Type.Equality ((:~:) (..))
import GHC.TypeError (ErrorMessage (..), TypeError)
import State.Category.Ty (KnownTy, Ty (..))

{- | A step's signature: @(in, exit, continue)@. Only an endo step (@in ~
continue@, no exit) can sit under 'State.Category.Flow.Opt', so the steps a
mode may skip are fixed by it.
-}
type Sig3 = (Ty, Maybe Ty, Ty)

type DomOf :: Sig3 -> Ty
type family DomOf sig where
    DomOf '(i, e, o) = i

type ExitOf :: Sig3 -> Maybe Ty
type family ExitOf sig where
    ExitOf '(i, e, o) = e

type CodOf :: Sig3 -> Ty
type family CodOf sig where
    CodOf '(i, e, o) = o

{- | A layer of steps. No method has a default, so a layer that leaves one
out does not build, and each is total over the layer's steps or outcomes,
so a new one breaks the build at every match. 'pack' guards the outcomes:
GHC accepts an outcome whose leg does not fit its step where it is declared
and refuses it only where it is packed, so 'pack' packs every one, and a
missing arm is an incomplete match.
-}
class (forall (s :: k). Show (Sing s), forall (s :: k) l. Show (Outcome s l), forall (s :: k) l. Eq (Outcome s l)) => StepSet k where
    type Sig (s :: k) :: Sig3

    {- | What 'State.Category.Flow.Do' needs to draw the step: nothing, but
    for a fan-out's own state, which 'State.Category.Flow.Par' draws.
    -}
    type Drawn (s :: k) :: Constraint

    -- | The value of a step: 'State.Category.Flow.Do' takes it.
    data Sing (s :: k) :: Type

    -- | What the step reports when it ends by this leg.
    data Outcome (s :: k) (l :: Leg) :: Type

    -- | Every step of the layer that 'State.Category.Flow.Do' draws, in the order the flows run them.
    layerSteps :: [SomeStep k]

    -- | The wire name: the state a run is at, and the first half of its events.
    stepName :: Sing (s :: k) -> StateName

    {- | The names of the step's exit and continuing outcomes. None is
    @skipped@: that word is the event a skip appends.
    -}
    outcomes :: Sing (s :: k) -> Outcomes (ExitOf (Sig s))

    special :: Sing (s :: k) -> Special

    sameStep :: Sing (a :: k) -> Sing (b :: k) -> Maybe (a :~: b)

    pack :: Outcome (s :: k) l -> SomeOutcome k

    -- | The outcome's @data@ on the wire; its @type@ is 'outcomeEvent'.
    encodeOutcome :: Outcome (s :: k) l -> Series

    -- | A reader per outcome of the layer, each keyed by the event it reads.
    decoders :: [Decoder k]

-- | How a step ends: by its exit, by continuing, or skipped by a mode.
data Leg = Exited | Continued | Skipped
    deriving stock (Eq, Show)

-- | The proof a leg fits a signature: matching it recovers the signature's shape.
data LegOf (sig :: Sig3) (l :: Leg) where
    ByExit :: LegOf '(i, 'Just x, o) 'Exited
    ByContinuing :: LegOf '(i, e, o) 'Continued
    BySkip :: LegOf '(i, 'Nothing, i) 'Skipped

deriving stock instance Show (LegOf sig l)

{- | The legs a signature has: an exit only with an exit type, a skip only on
an endo step with none. A refusal names the signature, where GHC would
print a missing instance.
-}
class Fits (sig :: Sig3) (l :: Leg) where
    legOf :: LegOf sig l

instance Fits '(i, 'Just x, o) 'Exited where
    legOf = ByExit

instance (TypeError ('Text "Outcome leg Exited does not fit step signature " ':<>: 'ShowType '(i, 'Nothing, o))) => Fits '(i, 'Nothing, o) 'Exited where
    legOf = error "unreachable: the context is a type error"

instance Fits '(i, e, o) 'Continued where
    legOf = ByContinuing

-- | A skip on a step that changes the type fails on @i ~ o@: GHC names both types.
instance (i ~ o) => Fits '(i, 'Nothing, o) 'Skipped where
    legOf = BySkip

instance (TypeError ('Text "Outcome leg Skipped does not fit step signature " ':<>: 'ShowType '(i, 'Just x, o))) => Fits '(i, 'Just x, o) 'Skipped where
    legOf = error "unreachable: the context is a type error"

-- | An outcome of some step of the layer, with the proof its leg fits.
data SomeOutcome k where
    SomeOutcome :: Sing (s :: k) -> LegOf (Sig s) l -> Outcome s l -> SomeOutcome k

instance (StepSet k) => Show (SomeOutcome k) where
    showsPrec d (SomeOutcome s _ o) = showParen (d > 10) $ showString "SomeOutcome " . showsPrec 11 s . showChar ' ' . showsPrec 11 o

-- | Equal when of one step and one leg, with equal reports.
instance (StepSet k) => Eq (SomeOutcome k) where
    SomeOutcome s leg o == SomeOutcome s' leg' o' = case (sameStep s s', leg, leg') of
        (Just Refl, ByExit, ByExit) -> o == o'
        (Just Refl, ByContinuing, ByContinuing) -> o == o'
        (Just Refl, BySkip, BySkip) -> o == o'
        _ -> False

-- | The packing 'pack' does per outcome, where the leg must fit the step.
packed :: forall k (s :: k) l. (Fits (Sig s) l) => Sing s -> Outcome s l -> SomeOutcome k
packed s = SomeOutcome s legOf

-- | The graph's name for the edge an outcome takes: its step's, then its leg's.
outcomeEvent :: (StepSet k) => SomeOutcome k -> EventName
outcomeEvent (SomeOutcome s leg _) = legEvent s leg

-- | The outcome's @data@ on the wire.
payload :: (StepSet k) => SomeOutcome k -> Series
payload (SomeOutcome _ _ o) = encodeOutcome o

legEvent :: (StepSet k) => Sing (s :: k) -> LegOf (Sig s) l -> EventName
legEvent s = \case
    ByExit -> exitEvent s
    ByContinuing -> continueEvent s
    BySkip -> skipEvent s

{- | The reader of one outcome. Its key is derived from the type it reads, so
a reader cannot sit under another outcome's name.
-}
data Decoder k where
    Decoder :: (Fits (Sig s) l) => Sing (s :: k) -> (Object -> Parser (Outcome s l)) -> Decoder k

decoderEvent :: (StepSet k) => Decoder k -> EventName
decoderEvent (Decoder s (_ :: Object -> Parser (Outcome s l))) = legEvent s (legOf @(Sig s) @l)

decodeWith :: Decoder k -> Object -> Parser (SomeOutcome k)
decodeWith (Decoder s parse) = fmap (packed s) . parse

-- | A step of the layer with its types known, so the steps can sit in one list.
data SomeStep k where
    SomeStep :: (KnownTy (DomOf (Sig s)), KnownTy (CodOf (Sig s))) => Sing (s :: k) -> SomeStep k

-- | What the advice at a step does instead of running it as its row says.
data Special
    = -- | Run it as its row says.
      Ordinary
    | -- | Ask the user to confirm the plan, once, before recording.
      AsksConfirm
    | -- | Record the picks the review loop's fuel allows.
      PicksRows
    | -- | Wait on the PR's CI.
      AwaitsCi
    | -- | Wait on the tasks' PRs to merge.
      AwaitsMerge
    deriving stock (Eq, Show)

-- | A state of a flow's graph, by name: what people read, and an override's target.
newtype StateName = StateName Text
    deriving stock (Eq, Ord, Show)

stateNameText :: StateName -> Text
stateNameText (StateName name) = name

-- | One outcome of a step, the second half of its events.
newtype OutcomeName = OutcomeName Text
    deriving stock (Eq, Ord, Show)

-- | A step's outcome names, indexed by its exit.
data Outcomes (e :: Maybe Ty) where
    Continues :: OutcomeName -> Outcomes 'Nothing
    -- | The exit outcome, then the continuing one.
    ExitsOr :: (KnownTy x) => OutcomeName -> OutcomeName -> Outcomes ('Just x)

-- | An event of a run, @<step>.<outcome>@ on the wire, such as @review.rows@.
data EventName = EventName {step :: StateName, outcome :: OutcomeName}
    deriving stock (Eq, Ord, Show)

eventText :: EventName -> Text
eventText (EventName (StateName step) (OutcomeName outcome)) = step <> "." <> outcome

-- | The event a step's continuing outcome appends.
continueEvent :: (StepSet k) => Sing (s :: k) -> EventName
continueEvent s = EventName (stepName s) $ case outcomes s of
    Continues continue -> continue
    ExitsOr _ continue -> continue

-- | The event a step's exit outcome appends: only a step with an exit has one.
exitEvent :: (StepSet k, ExitOf (Sig s) ~ 'Just x) => Sing (s :: k) -> EventName
exitEvent s = case outcomes s of
    ExitsOr exit _ -> EventName (stepName s) exit

-- | The event a skip appends: only an endo step can sit under an 'State.Category.Flow.Opt'.
skipEvent :: (StepSet k, ExitOf (Sig s) ~ 'Nothing, DomOf (Sig s) ~ CodOf (Sig s)) => Sing (s :: k) -> EventName
skipEvent s = EventName (stepName s) skippedOutcome

-- | The outcome of a step a mode skipped, which no step has of its own.
skippedOutcome :: OutcomeName
skippedOutcome = OutcomeName "skipped"

-- | A generating arrow of @Cap@: one outcome of one step, @step.outcome : dom -> cod@.
data OutcomeEdge = OutcomeEdge {event :: EventName, dom :: Ty, cod :: Ty}
    deriving stock (Eq, Show)
