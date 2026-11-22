{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeData #-}
{-# LANGUAGE UndecidableInstances #-}

{- | The first-order effects of a flow: what a run needs from outside the
flow to go on. A step raises operations ('State.Category.Step.Raises'),
each of one effect ('EffOf'), a flow's 'State.Category.Flow.Effects'
collects the effects from its structure, and a
'State.Category.Flow.Handle' takes one off. A whole flow handles every one.
-}
module State.Category.Effect (
    Eff (..),
    Handler (..),
    Waiting (..),
    OpOf (..),
    Op,
    OpVal,
    EffOf,
    KnownOps (..),
    awaiting,
    Effs,
    None,
    FromOps,
    ToList,
    Union,
    Without,
    Unhandled,
) where

import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Type.Bool (type (||))
import GHC.TypeError (ErrorMessage (..), TypeError)
import GHC.TypeLits (KnownSymbol, Symbol, symbolVal)

{- | @PickE@: a branch is picked, by the agent. @AskE@: a question is put,
to the run's principal. @FocusE@: the run waits for the user's attention.
@AwaitE@: the run waits on something outside it, a PR's CI or merge.
-}
type data Eff = PickE | AskE | FocusE | AwaitE

{- | Who answers the effect. A tag in the term, so a graph and a states
table do not see it ('State.Category.Flow.Handle' is drawn as its body).
Each is named after its effect.
-}
data Handler (eff :: Eff) where
    -- | The agent picks a branch by its label.
    PickHandler :: Handler PickE
    {- | Whoever started the run answers the question: the user for a run of
    their own, the parent run for a linked child, which rules or re-raises
    it up. Who that is, is the run's 'State.Run.Ask.Principal', a runtime
    value: the same flow roots both runs.
    -}
    AskHandler :: Handler AskE
    -- | Focus is granted at once.
    FocusHandler :: Handler FocusE
    -- | The outcome that settles the wait moves the run on.
    AwaitHandler :: Handler AwaitE

deriving stock instance Show (Handler eff)

-- | What a run with no wakes of its own hands up for a run above to wait on.
data Waiting = Ci | Merge
    deriving stock (Eq, Show, Enum, Bounded)

{- | An operation a step raises: one declaration at two levels, like
'State.Category.Ty.TyOf'. A step's 'Op's are its type; the advice and the
fold match on their 'OpVal's. A step raises at most one entry operation
('Confirms', 'Discusses', 'Awaits'): a list admits two, and the advice
takes the first.
-}
data OpOf text
    = -- | The agent picks the branch.
      Picks
    | -- | The run waits for the user's attention.
      Focuses
    | -- | Ask the user to confirm this, once, on entering the step, before recording: @the simplified plan@.
      Confirms text
    | -- | Its work is the user's questions: offer @state ask@ beside its records.
      Discusses
    | -- | Wait on the PR's CI, or on the tasks' PRs to merge.
      Awaits Waiting
    deriving stock (Eq, Show)

-- | The kind of a step's operations.
type Op = OpOf Symbol

-- | An 'Op' as a value.
type OpVal = OpOf Text

-- | The effect an operation raises.
type EffOf :: Op -> Eff
type family EffOf o where
    EffOf 'Picks = PickE
    EffOf 'Focuses = FocusE
    EffOf ('Confirms q) = AskE
    EffOf 'Discusses = AskE
    EffOf ('Awaits w) = AwaitE

-- | The values of promoted operations, in their order.
class KnownOps (os :: [Op]) where
    opsVal :: [OpVal]

instance KnownOps '[] where opsVal = []
instance (KnownOp o, KnownOps os) => KnownOps (o ': os) where
    opsVal = opVal @o : opsVal @os

class KnownOp (o :: Op) where
    opVal :: OpVal

instance KnownOp 'Picks where opVal = Picks
instance KnownOp 'Focuses where opVal = Focuses
instance (KnownSymbol q) => KnownOp ('Confirms q) where
    opVal = Confirms (Text.pack (symbolVal (Proxy @q)))
instance KnownOp 'Discusses where opVal = Discusses
instance KnownOp ('Awaits 'Ci) where opVal = Awaits Ci
instance KnownOp ('Awaits 'Merge) where opVal = Awaits Merge

-- | Whether the operation waits on something outside the run.
awaiting :: OpVal -> Bool
awaiting = \case
    Awaits _ -> True
    Picks -> False
    Focuses -> False
    Confirms _ -> False
    Discusses -> False

{- | A set of effects, one flag per 'Eff' in its order: raised or not.
Flags, not a list, so a union is four @||@s on reduced flags: a union
over lists, by @If@ and @Elem@, made GHC's coercions grow with the whole
flow's 'State.Category.Flow.Shape' and run out of memory on a whole flow.
-}
type data Effs = Flags Bool Bool Bool Bool

-- | No effect.
type None :: Effs
type None = Flags 'False 'False 'False 'False

{- | The effects of a step that raises these operations: 'AskE' always, as
every step may put a question, then each operation's.
-}
type FromOps :: [Op] -> Effs
type family FromOps os where
    FromOps '[] = One AskE
    FromOps (o ': os) = Union (One (EffOf o)) (FromOps os)

type One :: Eff -> Effs
type family One e where
    One PickE = Flags 'True 'False 'False 'False
    One AskE = Flags 'False 'True 'False 'False
    One FocusE = Flags 'False 'False 'True 'False
    One AwaitE = Flags 'False 'False 'False 'True

-- | The effects in the set, in 'Eff''s order, each once.
type ToList :: Effs -> [Eff]
type family ToList s where
    ToList (Flags p a f w) =
        Flag p PickE (Flag a AskE (Flag f FocusE (Flag w AwaitE '[])))

type Flag :: Bool -> Eff -> [Eff] -> [Eff]
type family Flag b e es where
    Flag 'True e es = e ': es
    Flag 'False e es = es

-- | The effects of either set.
type Union :: Effs -> Effs -> Effs
type family Union s t where
    Union (Flags p a f w) (Flags p' a' f' w') =
        Flags (p || p') (a || a') (f || f') (w || w')

-- | The set without the effect.
type Without :: Eff -> Effs -> Effs
type family Without e s where
    Without PickE (Flags p a f w) = Flags 'False a f w
    Without AskE (Flags p a f w) = Flags p 'False f w
    Without FocusE (Flags p a f w) = Flags p a 'False w
    Without AwaitE (Flags p a f w) = Flags p a f 'False

{- | The empty list, or a refusal naming the effects left: a whole flow
demands @Unhandled (Effects s) ~ '[]@. An equality, so the refusal is also
raised by a term built with its type errors deferred.
-}
type Unhandled :: [Eff] -> [Eff]
type family Unhandled es where
    Unhandled '[] = '[]
    Unhandled es =
        TypeError
            ( 'Text "A whole flow leaves effects unhandled: "
                ':<>: 'ShowType es
                ':$$: 'Text "Wrap it in a Handle for each."
            )
