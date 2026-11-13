{-# LANGUAGE AllowAmbiguousTypes #-}

-- | The objects of #351's category @Cap@: the artifact types steps pass on.
module State.Category.Ty (
    Ty (..),
    KnownTy (..),
) where

{- | Types are references, not values: a plan file, a commit, a PR number.
#351's sum @A + B@ is left out until a flow glues a case: its graph needs an
in port per summand.
-}
data Ty = Ctx | Plan | Diff | PR | List Ty
    deriving stock (Eq, Ord, Show)

-- | The value of a promoted 'Ty', so a typed term can label its edges.
class KnownTy (t :: Ty) where
    tyVal :: Ty

instance KnownTy 'Ctx where tyVal = Ctx
instance KnownTy 'Plan where tyVal = Plan
instance KnownTy 'Diff where tyVal = Diff
instance KnownTy 'PR where tyVal = PR
instance (KnownTy t) => KnownTy ('List t) where tyVal = List (tyVal @t)
