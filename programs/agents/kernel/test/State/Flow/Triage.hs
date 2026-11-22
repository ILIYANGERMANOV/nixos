{-# LANGUAGE TypeData #-}

{- | A flow that branches, for the tests only: no role runs it, so its step is
in no catalog, no @steps.nix@ row and no wire format. Triage sizes a diff:
a small one is described as it is, a big one is planned again.
-}
module State.Flow.Triage (
    TriageStep (..),
    -- Named, not @(..)@: a data family's @(..)@ would export every layer's constructors in scope here.
    Sing (Triage),
    Outcome (TriageSmall, TriageBig),
    triaged,
    TriagedS,
) where

import State.Category.Flow (Branch (..), Branches (..), Flow (..), Shape (..))
import State.Category.Step
import State.Category.Ty (TyOf (..))
import State.Step.Artifact (Sha, headData, headOf)
import State.Step.Build (BuildStep (..), Sing (..))
import State.Step.Ship (ShipStep (..), Sing (..))

type data TriageStep = Triage

instance StepSet TriageStep where
    type Raises s = '[]

    type
        Sig Triage =
            '( 'Diff, 'Nothing, 'Sum '[ '("small", 'Diff), '("big", 'Plan)])

    data Sing s where
        Triage :: Sing Triage

    data Outcome s l where
        TriageSmall :: Sha -> Outcome Triage ('Took "small")
        TriageBig :: Sha -> Outcome Triage ('Took "big")

    layerSteps = [SomeStep Triage]

    stepName Triage = StateName "triage"

    outcomes Triage = Branches

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

-- | The big branch is scoped: a flow names each state once, and both branches describe.
triaged :: Flow TriagedS 'Diff 'Nothing 'PR
triaged =
    Do Triage
        :> Case
            ( #small
                :-> Do Describe
                :& #big
                :-> Scope "big" (Do Implement :> Do Refactor :> Do Describe)
                :& End
            )

type TriagedS =
    DoS Triage
        :>> CaseS '[DoS Describe, ScopeS (DoS Implement :>> DoS Refactor :>> DoS Describe)]
