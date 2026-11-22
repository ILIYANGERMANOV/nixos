{-# LANGUAGE TypeData #-}

-- | The steps that ship the diff as a PR: describe it, simplify it, wait on CI, ready it.
module State.Step.Ship (
    ShipStep (..),
    Sing (..),
    Outcome (..),
) where

import Data.Aeson ((.:), (.=))
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import State.Category.Effect (OpOf (Awaits), Waiting (Ci))
import State.Category.Meter (Meter (..), Spend (..))
import State.Category.Step
import State.Category.Ty (TyOf (..))
import State.Step.Artifact (Check (..), Sha, Url, headData, headOf, urlData, urlOf)

type data ShipStep = Describe | SimplifyPR | AwaitCi | FixPR | Ready

instance StepSet ShipStep where
    type Raises Describe = '[]
    type Raises SimplifyPR = '[]
    type Raises AwaitCi = '[ 'Awaits 'Ci]
    type Raises FixPR = '[]
    type Raises Ready = '[]

    type Sig Describe = '( 'Diff, 'Nothing, 'PR)
    type Sig SimplifyPR = '( 'PR, 'Nothing, 'PR)
    type Sig AwaitCi = '( 'PR, 'Just 'PR, 'PR)
    type Sig FixPR = '( 'PR, 'Nothing, 'PR)
    type Sig Ready = '( 'PR, 'Nothing, 'Sum '[ '("done", 'PR), '("skipped", 'PR)])

    data Sing s where
        Describe :: Sing Describe
        SimplifyPR :: Sing SimplifyPR
        AwaitCi :: Sing AwaitCi
        FixPR :: Sing FixPR
        Ready :: Sing Ready

    data Outcome s l where
        DescribeDone :: Sha -> Outcome Describe 'Continued
        SimplifyPrDone :: Sha -> Outcome SimplifyPR 'Continued
        AwaitCiGreen :: Sha -> Outcome AwaitCi 'Exited
        -- \| Red has a failing check by definition.
        AwaitCiRed :: Sha -> NonEmpty Check -> Outcome AwaitCi 'Continued
        FixPrDone :: Sha -> Outcome FixPR 'Continued
        ReadyDone :: Url -> Outcome Ready ('Took "done")
        -- \| The PR left as it is: a round on an existing PR keeps it so.
        ReadySkipped :: Url -> Outcome Ready ('Took "skipped")

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
        Ready -> Branches

    pack = \case
        o@(DescribeDone _) -> packed Describe o
        o@(SimplifyPrDone _) -> packed SimplifyPR o
        o@(AwaitCiGreen _) -> packed AwaitCi o
        o@(AwaitCiRed _ _) -> packed AwaitCi o
        o@(FixPrDone _) -> packed FixPR o
        o@(ReadyDone _) -> packed Ready o
        o@(ReadySkipped _) -> packed Ready o

    encodeOutcome = \case
        DescribeDone sha -> headData sha
        SimplifyPrDone sha -> headData sha
        AwaitCiGreen sha -> headData sha
        AwaitCiRed sha failing -> headData sha <> "failing" .= map (\(Check check) -> check) (NonEmpty.toList failing)
        FixPrDone sha -> headData sha
        ReadyDone url -> urlData url
        ReadySkipped url -> urlData url

    decoders =
        [ Decoder Describe (fmap DescribeDone . headOf)
        , Decoder SimplifyPR (fmap SimplifyPrDone . headOf)
        , Decoder AwaitCi (fmap AwaitCiGreen . headOf)
        , Decoder AwaitCi (\obj -> AwaitCiRed <$> headOf obj <*> (fmap Check <$> obj .: "failing"))
        , Decoder FixPR (fmap FixPrDone . headOf)
        , Decoder Ready (fmap ReadyDone . urlOf)
        , Decoder Ready (fmap ReadySkipped . urlOf)
        ]

deriving stock instance Show (Sing (s :: ShipStep))
deriving stock instance Show (Outcome (s :: ShipStep) l)
deriving stock instance Eq (Outcome (s :: ShipStep) l)

-- | Each fix of a red CI: another round of waiting on it.
instance Meter FixPR where
    meterName FixPR = "CI fixes"
    spends FixPR = \case
        Ends _ (FixPrDone _) -> 1
        Asks -> 0
