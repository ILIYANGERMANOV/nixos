{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}

-- | The objects of #351's category @Cap@: the artifact types steps pass on.
module State.Category.Ty (
    TyOf (..),
    Ty,
    TyVal,
    KnownTy (..),
    IsSum,
    NotSum,
    Elem (..),
    Summand (..),
    Summands (..),
    elemLabel,
    labelledTys,
    HasLabel,
) where

import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.TypeError (ErrorMessage (..), TypeError, Unsatisfiable)
import GHC.TypeLits (KnownSymbol, Symbol, symbolVal)

{- | Types are references, not values: a plan file, a commit, a PR number.
'Findings' are a review's rows on a diff, the rows a fix takes. A 'Ticket'
is a design written into an issue tracker's ticket, by its url. 'Result' is
any request's result, the type every branch of the chief's route joins at:
its value is the run's latest recorded url, never a typed payload.
@'Sum' ss@ is #351's sum, n-ary and labelled: one of the summands, as a
step that branches hands on. Each label is the event of its branch.

The labels are a parameter because one declaration serves two levels: a
flow's types are 'Ty', labels as type-level 'Symbol's, and what a term
reports of them is 'TyVal', labels as 'Text'. GHC has no value of a 'Symbol'.
-}
data TyOf label = Ctx | Plan | Diff | Findings | PR | Ticket | Result | List (TyOf label) | Sum [(label, TyOf label)]
    deriving stock (Eq, Ord, Show)

-- | The kind of a flow's types: what a 'State.Category.Flow.Flow' is indexed by.
type Ty = TyOf Symbol

-- | A 'Ty' as a value: what an edge or a table names.
type TyVal = TyOf Text

-- | The value of a promoted 'Ty', so a typed term can label its edges.
class KnownTy (t :: Ty) where
    tyVal :: TyVal

instance KnownTy 'Ctx where tyVal = Ctx
instance KnownTy 'Plan where tyVal = Plan
instance KnownTy 'Diff where tyVal = Diff
instance KnownTy 'Findings where tyVal = Findings
instance KnownTy 'PR where tyVal = PR
instance KnownTy 'Ticket where tyVal = Ticket
instance KnownTy 'Result where tyVal = Result
instance (KnownTy t) => KnownTy ('List t) where tyVal = List (tyVal @t)
instance (Summands ss) => KnownTy ('Sum ss) where tyVal = Sum (labelledTys @ss)

type IsSum :: Ty -> Bool
type family IsSum t where
    IsSum ('Sum ss) = 'True
    IsSum t = 'False

{- | A type that is one thing, not a sum: what 'State.Category.Flow.Loop' and
'State.Category.Flow.Catch' keep, and what a single port takes. The
superclass is the evidence a match uses: given @NotSum t@, a pattern that
makes @t@ a sum is inaccessible, so a match needs no arm for it.
-}
class (IsSum t ~ 'False) => NotSum (t :: Ty)

instance NotSum 'Ctx
instance NotSum 'Plan
instance NotSum 'Diff
instance NotSum 'Findings
instance NotSum 'PR
instance NotSum 'Ticket
instance NotSum 'Result
instance NotSum ('List t)

instance
    (Unsatisfiable ('Text "A sum " ':<>: 'ShowType ('Sum ss) ':<>: 'Text " where one type is needed: branch on it with Case")) =>
    NotSum ('Sum ss)

-- | Where summand @l@, of type @a@, sits among the summands: a proof by position.
data Elem (ss :: [(Symbol, Ty)]) (l :: Symbol) (a :: Ty) where
    First :: Elem ('(l, a) ': ss) l a
    Next :: Elem ss l a -> Elem (s ': ss) l a

-- | One summand, with what an edge into it needs: its label, its type and that it is one type.
data Summand ss where
    Summand :: (KnownSymbol l, KnownTy a, NotSum a) => Elem ss l a -> Summand ss

{- | Summands that are each one type, known by label: a sum of sums is
refused, so every summand is one in port.
-}
class Summands (ss :: [(Symbol, Ty)]) where
    -- | Every summand, in the order the sum declares them.
    summands :: [Summand ss]

instance Summands '[] where summands = []

instance (KnownSymbol l, KnownTy a, NotSum a, Summands ss) => Summands ('(l, a) ': ss) where
    summands = Summand First : map next (summands @ss)
      where
        next (Summand e) = Summand (Next e)

-- | A summand's label, as its branch's event names it.
elemLabel :: forall ss l a. (KnownSymbol l) => Elem ss l a -> Text
elemLabel _ = Text.pack (symbolVal (Proxy @l))

-- | Every summand's label and type, in the sum's order.
labelledTys :: forall ss. (Summands ss) => [(Text, TyVal)]
labelledTys = [(elemLabel e, elemTy e) | Summand e <- summands @ss]
  where
    elemTy :: forall l a. (KnownTy a) => Elem ss l a -> TyVal
    elemTy _ = tyVal @a

{- | That @l@ labels one of the summands: an outcome into a summand the sum
lacks is refused, by name. An equality, @HasLabel l ss ~ 'True@, so the
refusal is also raised by a term built with its type errors deferred.
-}
type HasLabel :: Symbol -> [(Symbol, Ty)] -> Bool
type family HasLabel l ss where
    HasLabel l ('(l, a) ': ss) = 'True
    HasLabel l (s ': ss) = HasLabel l ss
    HasLabel l '[] = TypeError ('Text "No summand labelled " ':<>: 'ShowType l)
