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
    Union,
    Without,
    Unhandled,
) where

import Data.Type.Bool (If, type (||))
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

{- | Every effect, in the order an effect list is kept: 'Union' keeps it,
so two flows raising the same effects have the same list.
-}
type Every :: [Eff]
type Every = '[PickE, AskE, FocusE]

-- | The effects of either list, in 'Every''s order, each once.
type Union :: [Eff] -> [Eff] -> [Eff]
type Union xs ys = Keep Every xs ys

type Keep :: [Eff] -> [Eff] -> [Eff] -> [Eff]
type family Keep every xs ys where
    Keep '[] xs ys = '[]
    Keep (x ': every) xs ys = If (Elem x xs || Elem x ys) (x ': Keep every xs ys) (Keep every xs ys)

type Elem :: Eff -> [Eff] -> Bool
type family Elem x xs where
    Elem x '[] = 'False
    Elem x (x ': xs) = 'True
    Elem x (y ': xs) = Elem x xs

-- | The list without the effect.
type Without :: Eff -> [Eff] -> [Eff]
type family Without x xs where
    Without x '[] = '[]
    Without x (x ': xs) = Without x xs
    Without x (y ': xs) = y ': Without x xs

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
