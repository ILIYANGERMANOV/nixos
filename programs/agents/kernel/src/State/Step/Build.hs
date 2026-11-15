{-# LANGUAGE TypeData #-}

-- | The steps that build the plan into a diff: open the draft PR, implement, refactor.
module State.Step.Build (
    BuildStep,
    Sing (..),
    Outcome (..),
) where

import Data.Aeson ((.:), (.=))
import Data.Text (Text)
import Data.Type.Equality ((:~:) (..))
import State.Category.Step
import State.Category.Ty (Ty (..))
import State.Step.Artifact (Commit, DraftPr, Sha, commitData, commitOf, draftData, draftOf, headData, headOf)

type data BuildStep = Draft | Implement | Refactor

instance StepSet BuildStep where
    type Sig Draft = '( 'Plan, 'Nothing, 'Plan)
    type Sig Implement = '( 'Plan, 'Nothing, 'Diff)
    type Sig Refactor = '( 'Diff, 'Nothing, 'Diff)
    type Drawn s = 'True

    data Sing s where
        Draft :: Sing Draft
        Implement :: Sing Implement
        Refactor :: Sing Refactor

    data Outcome s l where
        DraftDone :: DraftPr -> Outcome Draft 'Continued
        ImplementDone :: Commit -> Outcome Implement 'Continued
        RefactorDone :: Sha -> Outcome Refactor 'Continued
        -- \| Why it was skipped.
        RefactorSkipped :: Text -> Outcome Refactor 'Skipped

    layerSteps = [SomeStep Draft, SomeStep Implement, SomeStep Refactor]
      where
        _listsEvery :: Sing (s :: BuildStep) -> ()
        _listsEvery = \case
            Draft -> ()
            Implement -> ()
            Refactor -> ()

    stepName =
        StateName . \case
            Draft -> "draft"
            Implement -> "implement"
            Refactor -> "refactor"

    outcomes = \case
        Draft -> Continues (OutcomeName "done")
        Implement -> Continues (OutcomeName "done")
        Refactor -> Continues (OutcomeName "done")

    special = \case
        Draft -> Ordinary
        Implement -> Ordinary
        Refactor -> Ordinary

    sameStep a b = case (a, b) of
        (Draft, Draft) -> Just Refl
        (Draft, _) -> Nothing
        (Implement, Implement) -> Just Refl
        (Implement, _) -> Nothing
        (Refactor, Refactor) -> Just Refl
        (Refactor, _) -> Nothing

    pack = \case
        o@(DraftDone _) -> packed Draft o
        o@(ImplementDone _) -> packed Implement o
        o@(RefactorDone _) -> packed Refactor o
        o@(RefactorSkipped _) -> packed Refactor o

    encodeOutcome = \case
        DraftDone draft -> draftData draft
        ImplementDone commit -> commitData commit
        RefactorDone sha -> headData sha
        RefactorSkipped why -> "why" .= why

    decoders =
        [ Decoder Draft (fmap DraftDone . draftOf)
        , Decoder Implement (fmap ImplementDone . commitOf)
        , Decoder Refactor (fmap RefactorDone . headOf)
        , Decoder Refactor (\obj -> RefactorSkipped <$> obj .: "why")
        ]

deriving stock instance Show (Sing (s :: BuildStep))
deriving stock instance Show (Outcome (s :: BuildStep) l)
deriving stock instance Eq (Outcome (s :: BuildStep) l)
