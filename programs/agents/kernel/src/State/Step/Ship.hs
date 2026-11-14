{-# LANGUAGE TypeData #-}

-- | The steps that ship the diff as a PR: describe it, simplify it, wait on CI, ready it.
module State.Step.Ship (
    ShipStep,
    Sing (..),
    Outcome (..),
) where

import Data.Aeson ((.:), (.=))
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Type.Equality ((:~:) (..))
import State.Category.Step
import State.Category.Ty (Ty (..))
import State.Step.Artifact (Check (..), Sha, Url, headData, headOf, urlData, urlOf)

type data ShipStep = Describe | SimplifyPR | AwaitCi | FixPR | Ready

instance StepSet ShipStep where
    type Sig Describe = '( 'Diff, 'Nothing, 'PR)
    type Sig SimplifyPR = '( 'PR, 'Nothing, 'PR)
    type Sig AwaitCi = '( 'PR, 'Just 'PR, 'PR)
    type Sig FixPR = '( 'PR, 'Nothing, 'PR)
    type Sig Ready = '( 'PR, 'Nothing, 'PR)
    type Drawn s = 'True

    data Sing s where
        Describe :: Sing Describe
        SimplifyPR :: Sing SimplifyPR
        AwaitCi :: Sing AwaitCi
        FixPR :: Sing FixPR
        Ready :: Sing Ready

    data Outcome s l where
        DescribeDone :: Sha -> Outcome Describe 'Continued
        SimplifyPrDone :: Sha -> Outcome SimplifyPR 'Continued
        SimplifyPrSkipped :: Sha -> Outcome SimplifyPR 'Skipped
        AwaitCiGreen :: Sha -> Outcome AwaitCi 'Exited
        -- \| Red has a failing check by definition.
        AwaitCiRed :: Sha -> NonEmpty Check -> Outcome AwaitCi 'Continued
        FixPrDone :: Sha -> Outcome FixPR 'Continued
        ReadyDone :: Url -> Outcome Ready 'Continued
        -- \| POC keeps a draft: the PR it left.
        ReadySkipped :: Url -> Outcome Ready 'Skipped

    layerSteps = [SomeStep Describe, SomeStep SimplifyPR, SomeStep AwaitCi, SomeStep FixPR, SomeStep Ready]
      where
        _listsEvery :: Sing (s :: ShipStep) -> ()
        _listsEvery = \case
            Describe -> ()
            SimplifyPR -> ()
            AwaitCi -> ()
            FixPR -> ()
            Ready -> ()

    stepName =
        StateName . \case
            Describe -> "describe"
            SimplifyPR -> "simplify_pr"
            AwaitCi -> "await_ci"
            FixPR -> "fix_pr"
            Ready -> "ready"

    outcomes = \case
        Describe -> Continues (OutcomeName "done")
        SimplifyPR -> Continues (OutcomeName "done")
        AwaitCi -> ExitsOr (OutcomeName "green") (OutcomeName "red")
        FixPR -> Continues (OutcomeName "done")
        Ready -> Continues (OutcomeName "done")

    special = \case
        Describe -> Ordinary
        SimplifyPR -> Ordinary
        AwaitCi -> AwaitsCi
        FixPR -> Ordinary
        Ready -> Ordinary

    sameStep a b = case (a, b) of
        (Describe, Describe) -> Just Refl
        (Describe, _) -> Nothing
        (SimplifyPR, SimplifyPR) -> Just Refl
        (SimplifyPR, _) -> Nothing
        (AwaitCi, AwaitCi) -> Just Refl
        (AwaitCi, _) -> Nothing
        (FixPR, FixPR) -> Just Refl
        (FixPR, _) -> Nothing
        (Ready, Ready) -> Just Refl
        (Ready, _) -> Nothing

    pack = \case
        o@(DescribeDone _) -> packed Describe o
        o@(SimplifyPrDone _) -> packed SimplifyPR o
        o@(SimplifyPrSkipped _) -> packed SimplifyPR o
        o@(AwaitCiGreen _) -> packed AwaitCi o
        o@(AwaitCiRed _ _) -> packed AwaitCi o
        o@(FixPrDone _) -> packed FixPR o
        o@(ReadyDone _) -> packed Ready o
        o@(ReadySkipped _) -> packed Ready o

    encodeOutcome = \case
        DescribeDone sha -> headData sha
        SimplifyPrDone sha -> headData sha
        SimplifyPrSkipped sha -> headData sha
        AwaitCiGreen sha -> headData sha
        AwaitCiRed sha failing -> headData sha <> "failing" .= map (\(Check check) -> check) (NonEmpty.toList failing)
        FixPrDone sha -> headData sha
        ReadyDone url -> urlData url
        ReadySkipped url -> urlData url

    decoders =
        [ Decoder Describe (fmap DescribeDone . headOf)
        , Decoder SimplifyPR (fmap SimplifyPrDone . headOf)
        , Decoder SimplifyPR (fmap SimplifyPrSkipped . headOf)
        , Decoder AwaitCi (fmap AwaitCiGreen . headOf)
        , Decoder AwaitCi (\obj -> AwaitCiRed <$> headOf obj <*> (fmap Check <$> obj .: "failing"))
        , Decoder FixPR (fmap FixPrDone . headOf)
        , Decoder Ready (fmap ReadyDone . urlOf)
        , Decoder Ready (fmap ReadySkipped . urlOf)
        ]

deriving stock instance Show (Sing (s :: ShipStep))
deriving stock instance Show (Outcome (s :: ShipStep) l)
deriving stock instance Eq (Outcome (s :: ShipStep) l)
