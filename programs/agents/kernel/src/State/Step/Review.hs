{-# LANGUAGE TypeData #-}

{- | The steps of the review flow: review the diff, then, while it has findings,
pick the rows to fix, fix them and re-review the fix.
-}
module State.Step.Review (
    ReviewStep (..),
    Sing (..),
    Outcome (..),
) where

import State.Category.Meter (Meter (..), Spend (..))
import State.Category.Step
import State.Category.Ty (TyOf (..))
import State.Step.Artifact (
    Commit,
    Picks,
    Sha,
    commitData,
    commitOf,
    headData,
    headOf,
    picksData,
    picksOf,
 )

type data ReviewStep = Review | PickRows | Fix | ReReview

instance StepSet ReviewStep where
    type Raises s = '[]

    type Sig Review = '( 'Diff, 'Just 'Diff, 'Findings)
    type Sig PickRows = '( 'Findings, 'Just 'Diff, 'Findings)
    type Sig Fix = '( 'Findings, 'Nothing, 'Diff)
    type Sig ReReview = '( 'Diff, 'Just 'Diff, 'Findings)

    data Sing s where
        Review :: Sing Review
        PickRows :: Sing PickRows
        Fix :: Sing Fix
        ReReview :: Sing ReReview

    data Outcome s l where
        ReviewClean :: Sha -> Outcome Review 'Exited
        ReviewRows :: Sha -> Outcome Review 'Continued
        PickFinal :: Picks -> Outcome PickRows 'Exited
        PickLoop :: Picks -> Outcome PickRows 'Continued
        FixDone :: Commit -> Outcome Fix 'Continued
        ReReviewClean :: Sha -> Outcome ReReview 'Exited
        ReReviewRows :: Sha -> Outcome ReReview 'Continued

    layerSteps = [SomeStep Review, SomeStep PickRows, SomeStep Fix, SomeStep ReReview]
      where
        _listsEvery :: Sing (s :: ReviewStep) -> ()
        _listsEvery = \case
            Review -> ()
            PickRows -> ()
            Fix -> ()
            ReReview -> ()

    stepName =
        StateName . \case
            Review -> "review"
            PickRows -> "pick"
            Fix -> "fix"
            ReReview -> "re_review"

    outcomes = \case
        Review -> ExitsOr (OutcomeName "clean") (OutcomeName "rows")
        PickRows -> ExitsOr (OutcomeName "final") (OutcomeName "loop")
        Fix -> Continues (OutcomeName "done")
        ReReview -> ExitsOr (OutcomeName "clean") (OutcomeName "rows")

    pack = \case
        o@(ReviewClean _) -> packed Review o
        o@(ReviewRows _) -> packed Review o
        o@(PickFinal _) -> packed PickRows o
        o@(PickLoop _) -> packed PickRows o
        o@(FixDone _) -> packed Fix o
        o@(ReReviewClean _) -> packed ReReview o
        o@(ReReviewRows _) -> packed ReReview o

    encodeOutcome = \case
        ReviewClean sha -> headData sha
        ReviewRows sha -> headData sha
        PickFinal picks -> picksData picks
        PickLoop picks -> picksData picks
        FixDone commit -> commitData commit
        ReReviewClean sha -> headData sha
        ReReviewRows sha -> headData sha

    decoders =
        [ Decoder Review (fmap ReviewClean . headOf)
        , Decoder Review (fmap ReviewRows . headOf)
        , Decoder PickRows (fmap PickFinal . picksOf)
        , Decoder PickRows (fmap PickLoop . picksOf)
        , Decoder Fix (fmap FixDone . commitOf)
        , Decoder ReReview (fmap ReReviewClean . headOf)
        , Decoder ReReview (fmap ReReviewRows . headOf)
        ]

deriving stock instance Show (Sing (s :: ReviewStep))
deriving stock instance Show (Outcome (s :: ReviewStep) l)
deriving stock instance Eq (Outcome (s :: ReviewStep) l)

-- | A re-review round: each @pick.loop@ buys one.
instance Meter PickRows where
    meterName PickRows = "Re-reviews"
    spends PickRows = \case
        Ends _ (PickLoop _) -> 1
        Ends _ (PickFinal _) -> 0
        Asks -> 0
