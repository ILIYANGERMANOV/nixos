{-# LANGUAGE TypeData #-}
{-# LANGUAGE UndecidableInstances #-}

{- | The first-order effects of a flow: what a run needs from outside the
flow to go on. A step raises them ('State.Category.Step.Raises'), a flow's
'State.Category.Flow.Effects' collects them from its structure, and a
'State.Category.Flow.Handle' takes one off. A whole flow handles every one.
-}
module State.Category.Effect (
    Eff (..),
    Handler (..),
    Effs,
    None,
    FromList,
    ToList,
    Union,
    Without,
    Unhandled,
) where

import Data.Type.Bool (type (||))
import GHC.TypeError (ErrorMessage (..), TypeError)

{- | @PickE@: a branch is picked, by the agent. @AskE@: a question is put,
to the user. @FocusE@: the run waits for the user's attention.
-}
type data Eff = PickE | AskE | FocusE

{- | Who answers the effect. A tag in the term, so a graph and a states
table do not see it ('State.Category.Flow.Handle' is drawn as its body).
-}
data Handler (eff :: Eff) where
    -- | The agent picks a branch by its label.
    AgentPicks :: Handler PickE
    -- | The user answers the question, through @state ask@.
    UserAsks :: Handler AskE
    -- | Focus is granted at once.
    FocusHere :: Handler FocusE

deriving stock instance Show (Handler eff)

{- | A set of effects, one flag per 'Eff' in its order: raised or not.
Flags, not a list, so a union is three @||@s on reduced flags: a union
over lists, by @If@ and @Elem@, made GHC's coercions grow with the whole
flow's 'State.Category.Flow.Shape' and run out of memory on a whole flow.
-}
type data Effs = Flags Bool Bool Bool

-- | No effect.
type None :: Effs
type None = Flags 'False 'False 'False

-- | The set of a list's effects.
type FromList :: [Eff] -> Effs
type family FromList es where
    FromList '[] = None
    FromList (e ': es) = Union (One e) (FromList es)

type One :: Eff -> Effs
type family One e where
    One PickE = Flags 'True 'False 'False
    One AskE = Flags 'False 'True 'False
    One FocusE = Flags 'False 'False 'True

-- | The effects in the set, in 'Eff''s order, each once.
type ToList :: Effs -> [Eff]
type family ToList s where
    ToList (Flags p a f) = Flag p PickE (Flag a AskE (Flag f FocusE '[]))

type Flag :: Bool -> Eff -> [Eff] -> [Eff]
type family Flag b e es where
    Flag 'True e es = e ': es
    Flag 'False e es = es

-- | The effects of either set.
type Union :: Effs -> Effs -> Effs
type family Union s t where
    Union (Flags p a f) (Flags p' a' f') = Flags (p || p') (a || a') (f || f')

-- | The set without the effect.
type Without :: Eff -> Effs -> Effs
type family Without e s where
    Without PickE (Flags p a f) = Flags 'False a f
    Without AskE (Flags p a f) = Flags p 'False f
    Without FocusE (Flags p a f) = Flags p a 'False

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
