{-# LANGUAGE TypeData #-}

-- | The steps of the review loop: review the diff, pick the rows to fix, fix them.
module State.Step.Review (
    ReviewStep,
    Sing (..),
    Outcome (..),
) where

import Data.Type.Equality ((:~:) (..))
import State.Category.Step
import State.Category.Ty (Ty (..))
import State.Step.Artifact (Commit, Picks, Sha, commitData, commitOf, headData, headOf, picksData, picksOf)

type data ReviewStep = Review | Pick | Fix

instance StepSet ReviewStep where
    type Sig Review = '( 'Diff, 'Just 'Diff, 'Diff)
    type Sig Pick = '( 'Diff, 'Just 'Diff, 'Diff)
    type Sig Fix = '( 'Diff, 'Nothing, 'Diff)
    type Drawn s = ()

    data Sing s where
        Review :: Sing Review
        Pick :: Sing Pick
        Fix :: Sing Fix

    data Outcome s l where
        ReviewClean :: Sha -> Outcome Review 'Exited
        ReviewRows :: Sha -> Outcome Review 'Continued
        PickFinal :: Picks -> Outcome Pick 'Exited
        PickLoop :: Picks -> Outcome Pick 'Continued
        FixDone :: Commit -> Outcome Fix 'Continued

    layerSteps = [SomeStep Review, SomeStep Pick, SomeStep Fix]
      where
        _listsEvery :: Sing (s :: ReviewStep) -> ()
        _listsEvery = \case
            Review -> ()
            Pick -> ()
            Fix -> ()

    stepName =
        StateName . \case
            Review -> "review"
            Pick -> "pick"
            Fix -> "fix"

    outcomes = \case
        Review -> ExitsOr (OutcomeName "clean") (OutcomeName "rows")
        Pick -> ExitsOr (OutcomeName "final") (OutcomeName "loop")
        Fix -> Continues (OutcomeName "done")

    special = \case
        Review -> Ordinary
        Pick -> PicksRows
        Fix -> Ordinary

    sameStep a b = case (a, b) of
        (Review, Review) -> Just Refl
        (Pick, Pick) -> Just Refl
        (Fix, Fix) -> Just Refl
        _ -> Nothing

    pack = \case
        o@(ReviewClean _) -> packed Review o
        o@(ReviewRows _) -> packed Review o
        o@(PickFinal _) -> packed Pick o
        o@(PickLoop _) -> packed Pick o
        o@(FixDone _) -> packed Fix o

    encodeOutcome = \case
        ReviewClean sha -> headData sha
        ReviewRows sha -> headData sha
        PickFinal picks -> picksData picks
        PickLoop picks -> picksData picks
        FixDone commit -> commitData commit

    decoders =
        [ Decoder Review (fmap ReviewClean . headOf)
        , Decoder Review (fmap ReviewRows . headOf)
        , Decoder Pick (fmap PickFinal . picksOf)
        , Decoder Pick (fmap PickLoop . picksOf)
        , Decoder Fix (fmap FixDone . commitOf)
        ]

deriving stock instance Show (Sing (s :: ReviewStep))
deriving stock instance Show (Outcome (s :: ReviewStep) l)
deriving stock instance Eq (Outcome (s :: ReviewStep) l)
