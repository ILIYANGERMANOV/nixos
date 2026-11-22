{-# LANGUAGE TypeData #-}

{- | The steps around a request the chief routes: open the issue, branch or
PR a block starts from, do a request no flow fits, and take the next
request or end. The lead runs each.
-}
module State.Step.Request (
    RequestStep (..),
    Sing (..),
    Outcome (..),
) where

import Data.Aeson ((.:), (.=))
import Data.Text (Text)
import State.Category.Effect (OpOf (Focuses))
import State.Category.Meter (Meter (..), Spend (..))
import State.Category.Step
import State.Category.Ty (TyOf (..))
import State.Step.Artifact (Branch (..), Url, branchText, urlData, urlOf)

type data RequestStep = OpenPlan | OpenBranch | OpenPr | Direct | Next

-- | The user's attention ('FocusE'): the chief takes the next request, or turns to another.
instance StepSet RequestStep where
    type Raises s = '[ 'Focuses]

    type Sig OpenPlan = '( 'Ctx, 'Nothing, 'Plan)
    type Sig OpenBranch = '( 'Ctx, 'Nothing, 'Diff)
    type Sig OpenPr = '( 'Ctx, 'Nothing, 'PR)
    type Sig Direct = '( 'Ctx, 'Nothing, 'Ctx)
    type Sig Next = '( 'Result, 'Just 'Result, 'Ctx)

    data Sing s where
        OpenPlan :: Sing OpenPlan
        OpenBranch :: Sing OpenBranch
        OpenPr :: Sing OpenPr
        Direct :: Sing Direct
        Next :: Sing Next

    data Outcome s l where
        -- \| The issue holding the plan a build starts from.
        OpenPlanDone :: Url -> Outcome OpenPlan 'Continued
        -- \| The branch, or a sha, holding the diff a review or a description starts from.
        OpenBranchDone :: Branch -> Outcome OpenBranch 'Continued
        -- \| The PR a ship starts from.
        OpenPrDone :: Url -> Outcome OpenPr 'Continued
        -- \| What the request asked and what was done, in the lead's words.
        DirectDone :: Text -> Outcome Direct 'Continued
        NextDone :: Outcome Next 'Exited
        NextRequest :: Outcome Next 'Continued

    layerSteps =
        [ SomeStep OpenPlan
        , SomeStep OpenBranch
        , SomeStep OpenPr
        , SomeStep Direct
        , SomeStep Next
        ]
      where
        _listsEvery :: Sing (s :: RequestStep) -> ()
        _listsEvery = \case
            OpenPlan -> ()
            OpenBranch -> ()
            OpenPr -> ()
            Direct -> ()
            Next -> ()

    stepName =
        StateName . \case
            OpenPlan -> "open_plan"
            OpenBranch -> "open_branch"
            OpenPr -> "open_pr"
            Direct -> "direct"
            Next -> "next"

    outcomes = \case
        OpenPlan -> Continues (OutcomeName "done")
        OpenBranch -> Continues (OutcomeName "done")
        OpenPr -> Continues (OutcomeName "done")
        Direct -> Continues (OutcomeName "done")
        Next -> ExitsOr (OutcomeName "done") (OutcomeName "request")

    pack = \case
        o@(OpenPlanDone _) -> packed OpenPlan o
        o@(OpenBranchDone _) -> packed OpenBranch o
        o@(OpenPrDone _) -> packed OpenPr o
        o@(DirectDone _) -> packed Direct o
        o@NextDone -> packed Next o
        o@NextRequest -> packed Next o

    encodeOutcome = \case
        OpenPlanDone url -> urlData url
        OpenBranchDone branch -> "branch" .= branchText branch
        OpenPrDone url -> urlData url
        DirectDone note -> "note" .= note
        NextDone -> mempty
        NextRequest -> mempty

    decoders =
        [ Decoder OpenPlan (fmap OpenPlanDone . urlOf)
        , Decoder OpenBranch (\obj -> OpenBranchDone . Branch <$> obj .: "branch")
        , Decoder OpenPr (fmap OpenPrDone . urlOf)
        , Decoder Direct (\obj -> DirectDone <$> obj .: "note")
        , Decoder Next (const (pure NextDone))
        , Decoder Next (const (pure NextRequest))
        ]

deriving stock instance Show (Sing (s :: RequestStep))
deriving stock instance Show (Outcome (s :: RequestStep) l)
deriving stock instance Eq (Outcome (s :: RequestStep) l)

-- | Each request taken after the first: a run that never ends asks the user whether to go on.
instance Meter Next where
    meterName Next = "Requests"
    spends Next = \case
        Ends _ NextRequest -> 1
        Ends _ NextDone -> 0
        Asks -> 0
