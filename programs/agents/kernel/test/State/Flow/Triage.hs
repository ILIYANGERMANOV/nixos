{-# LANGUAGE TypeData #-}

{- | A flow that branches, for the tests only: no role runs it, so its step is
in no catalog, no @steps.nix@ row and no wire format. Triage sizes a diff:
a small one is described as it is, a big one is planned again.
-}
module State.Flow.Triage (
    TriageStep,
    -- Named, not @(..)@: a data family's @(..)@ would export every layer's constructors in scope here.
    Sing (Triage),
    Outcome (TriageSmall, TriageBig),
    triaged,
) where

import Data.Type.Equality ((:~:) (..))
import State.Category.Flow (Flow (..), (|||))
import State.Category.Step
import State.Category.Ty (Ty (..))
import State.Step.Artifact (Sha, headData, headOf)
import State.Step.Build (Sing (..))
import State.Step.Review (Sing (..))
import State.Step.Ship (Sing (..))

type data TriageStep = Triage

instance StepSet TriageStep where
    type Sig Triage = '( 'Diff, 'Nothing, 'Diff ':+ 'Plan)
    type Drawn s = 'True

    data Sing s where
        Triage :: Sing Triage

    data Outcome s l where
        TriageSmall :: Sha -> Outcome Triage 'Inl
        TriageBig :: Sha -> Outcome Triage 'Inr

    layerSteps = [SomeStep Triage]

    stepName Triage = StateName "triage"

    outcomes Triage = Branches (OutcomeName "small") (OutcomeName "big")

    special Triage = Ordinary

    sameStep Triage Triage = Just Refl

    pack = \case
        o@(TriageSmall _) -> packed Triage o
        o@(TriageBig _) -> packed Triage o

    encodeOutcome = \case
        TriageSmall sha -> headData sha
        TriageBig sha -> headData sha

    decoders =
        [ Decoder Triage (fmap TriageSmall . headOf)
        , Decoder Triage (fmap TriageBig . headOf)
        ]

deriving stock instance Show (Sing (s :: TriageStep))
deriving stock instance Show (Outcome (s :: TriageStep) l)
deriving stock instance Eq (Outcome (s :: TriageStep) l)

triaged :: Flow 'Diff 'Nothing 'PR
triaged = Do Triage :> (Do Describe ||| Do Implement :> Do Fix :> Do Describe)
