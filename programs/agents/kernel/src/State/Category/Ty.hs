{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}

-- | The objects of #351's category @Cap@: the artifact types steps pass on.
module State.Category.Ty (
    Ty (..),
    KnownTy (..),
    IsSum,
    NotSum,
) where

import GHC.TypeError (ErrorMessage (..), Unsatisfiable)

{- | Types are references, not values: a plan file, a commit, a PR number.
@a ':+' b@ is #351's sum: one of the two, as a step that branches hands on.
-}
data Ty = Ctx | Plan | Diff | PR | List Ty | Ty :+ Ty
    deriving stock (Eq, Ord, Show)

infixr 6 :+

-- | The value of a promoted 'Ty', so a typed term can label its edges.
class KnownTy (t :: Ty) where
    tyVal :: Ty

instance KnownTy 'Ctx where tyVal = Ctx
instance KnownTy 'Plan where tyVal = Plan
instance KnownTy 'Diff where tyVal = Diff
instance KnownTy 'PR where tyVal = PR
instance (KnownTy t) => KnownTy ('List t) where tyVal = List (tyVal @t)
instance (KnownTy a, KnownTy b) => KnownTy (a ':+ b) where tyVal = tyVal @a :+ tyVal @b

type IsSum :: Ty -> Bool
type family IsSum t where
    IsSum (a ':+ b) = 'True
    IsSum t = 'False

{- | A type that is one thing, not a sum: what 'State.Category.Flow.Opt' and
'State.Category.Flow.Loop' keep, and what a single port takes. The
superclass is the evidence a match uses: given @NotSum t@, a pattern that
makes @t@ a sum is inaccessible, so a match needs no arm for it.
-}
class (IsSum t ~ 'False) => NotSum (t :: Ty)

instance NotSum 'Ctx
instance NotSum 'Plan
instance NotSum 'Diff
instance NotSum 'PR
instance NotSum ('List t)

instance
    (Unsatisfiable ('Text "A sum " ':<>: 'ShowType (a ':+ b) ':<>: 'Text " where one type is needed: branch on it with |||"))
    => NotSum (a ':+ b)
