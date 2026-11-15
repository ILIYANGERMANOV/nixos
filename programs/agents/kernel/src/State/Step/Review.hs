{-# LANGUAGE TypeData #-}

{- | The steps of the review flow: review the diff, then, while it has findings,
pick the rows to fix, fix them and re-review the fix.
-}
module State.Step.Review (
    ReviewStep,
    Sing (..),
    Outcome (..),
) where

import Data.Type.Equality ((:~:) (..))
import State.Category.Step
import State.Category.Ty (Ty (..))
import State.Step.Artifact (Commit, Picks, Sha, commitData, commitOf, headData, headOf, picksData, picksOf)

type data ReviewStep = Review | Pick | Fix | ReReview

instance StepSet ReviewStep where
    type Sig Review = '( 'Diff, 'Just 'Diff, 'Findings)
    type Sig Pick = '( 'Findings, 'Just 'Diff, 'Findings)
    type Sig Fix = '( 'Findings, 'Nothing, 'Diff)
    type Sig ReReview = '( 'Diff, 'Just 'Diff, 'Findings)
    type Drawn s = 'True

    data Sing s where
        Review :: Sing Review
        Pick :: Sing Pick
        Fix :: Sing Fix
        ReReview :: Sing ReReview

    data Outcome s l where
        ReviewClean :: Sha -> Outcome Review 'Exited
        ReviewRows :: Sha -> Outcome Review 'Continued
        PickFinal :: Picks -> Outcome Pick 'Exited
        PickLoop :: Picks -> Outcome Pick 'Continued
        FixDone :: Commit -> Outcome Fix 'Continued
        ReReviewClean :: Sha -> Outcome ReReview 'Exited
        ReReviewRows :: Sha -> Outcome ReReview 'Continued

    layerSteps = [SomeStep Review, SomeStep Pick, SomeStep Fix, SomeStep ReReview]
      where
        _listsEvery :: Sing (s :: ReviewStep) -> ()
        _listsEvery = \case
            Review -> ()
            Pick -> ()
            Fix -> ()
            ReReview -> ()

    stepName =
        StateName . \case
            Review -> "review"
            Pick -> "pick"
            Fix -> "fix"
            ReReview -> "re_review"

    outcomes = \case
        Review -> ExitsOr (OutcomeName "clean") (OutcomeName "rows")
        Pick -> ExitsOr (OutcomeName "final") (OutcomeName "loop")
        Fix -> Continues (OutcomeName "done")
        ReReview -> ExitsOr (OutcomeName "clean") (OutcomeName "rows")

    special = \case
        Review -> Ordinary
        Pick -> PicksRows
        Fix -> Ordinary
        ReReview -> Ordinary

    sameStep a b = case (a, b) of
        (Review, Review) -> Just Refl
        (Review, _) -> Nothing
        (Pick, Pick) -> Just Refl
        (Pick, _) -> Nothing
        (Fix, Fix) -> Just Refl
        (Fix, _) -> Nothing
        (ReReview, ReReview) -> Just Refl
        (ReReview, _) -> Nothing

    pack = \case
        o@(ReviewClean _) -> packed Review o
        o@(ReviewRows _) -> packed Review o
        o@(PickFinal _) -> packed Pick o
        o@(PickLoop _) -> packed Pick o
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
        , Decoder Pick (fmap PickFinal . picksOf)
        , Decoder Pick (fmap PickLoop . picksOf)
        , Decoder Fix (fmap FixDone . commitOf)
        , Decoder ReReview (fmap ReReviewClean . headOf)
        , Decoder ReReview (fmap ReReviewRows . headOf)
        ]

deriving stock instance Show (Sing (s :: ReviewStep))
deriving stock instance Show (Outcome (s :: ReviewStep) l)
deriving stock instance Eq (Outcome (s :: ReviewStep) l)
