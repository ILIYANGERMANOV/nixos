{-# LANGUAGE AllowAmbiguousTypes #-}

{- | The vocabulary of #351's category @Cap@: artifact types and the typed
steps between them. A step is the bundle of its outcome edges, exits first,
the continuing one last.
-}
module State.Cap (
    Ty (..),
    KnownTy (..),
    Step (..),
    StateName (..),
    stepName,
    OutcomeName (..),
    Outcomes (..),
    outcomes,
    EventName (..),
    eventText,
    continueEvent,
    exitEvent,
    skipEvent,
    skippedOutcome,
    OutcomeEdge (..),
) where

import Data.Text (Text)

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

{- | @i@: in. @e@: the exit, if the step has one. @o@: continue. Only an
endo step (@i ~ o@, no exit) can sit under 'State.Flow.Opt', so the steps a
mode may skip are fixed here.
-}
data Step (i :: Ty) (e :: Maybe Ty) (o :: Ty) where
    Research :: Step 'Ctx 'Nothing 'Ctx
    Interview :: Step 'Ctx ('Just 'Ctx) 'Ctx
    PlanS :: Step 'Ctx 'Nothing 'Plan
    SimplifyP :: Step 'Plan 'Nothing 'Plan
    Alternative :: Step 'Plan 'Nothing 'Plan
    Confirm :: Step 'Plan ('Just 'Plan) 'Ctx
    Draft :: Step 'Plan 'Nothing 'Plan
    Implement :: Step 'Plan 'Nothing 'Diff
    Refactor :: Step 'Diff 'Nothing 'Diff
    Review :: Step 'Diff ('Just 'Diff) 'Diff
    Pick :: Step 'Diff ('Just 'Diff) 'Diff
    Fix :: Step 'Diff 'Nothing 'Diff
    Describe :: Step 'Diff 'Nothing 'PR
    SimplifyPR :: Step 'PR 'Nothing 'PR
    AwaitCi :: Step 'PR ('Just 'PR) 'PR
    FixPR :: Step 'PR 'Nothing 'PR
    Ready :: Step 'PR 'Nothing 'PR
    Breakdown :: Step 'Plan 'Nothing ('List 'Ctx)
    Merge :: Step ('List 'PR) 'Nothing 'PR

deriving stock instance Show (Step i e o)

-- | A state of a flow's graph, by name: what people read, and an override's target.
newtype StateName = StateName Text
    deriving stock (Eq, Ord, Show)

-- | The wire name: the state a run is at, and the first half of its events.
stepName :: Step i e o -> StateName
stepName =
    StateName . \case
        Research -> "research"
        Interview -> "interview"
        PlanS -> "plan"
        SimplifyP -> "simplify_plan"
        Alternative -> "alternative"
        Confirm -> "confirm"
        Draft -> "draft"
        Implement -> "implement"
        Refactor -> "refactor"
        Review -> "review"
        Pick -> "pick"
        Fix -> "fix"
        Describe -> "describe"
        SimplifyPR -> "simplify_pr"
        AwaitCi -> "await_ci"
        FixPR -> "fix_pr"
        Ready -> "ready"
        Breakdown -> "breakdown"
        Merge -> "merge"

-- | One outcome of a step, the second half of its events.
newtype OutcomeName = OutcomeName Text
    deriving stock (Eq, Ord, Show)

-- | Indexed by the exit, so a step has an exit outcome exactly when its type does.
data Outcomes (e :: Maybe Ty) where
    Continues :: OutcomeName -> Outcomes 'Nothing
    -- | The exit outcome, then the continuing one.
    ExitsOr :: (KnownTy x) => OutcomeName -> OutcomeName -> Outcomes ('Just x)

{- | No outcome is @skipped@: that word is the event a skip appends
('State.Graph.graph').
-}
outcomes :: Step i e o -> Outcomes e
outcomes = \case
    Research -> Continues done
    Interview -> ExitsOr (OutcomeName "enough") (OutcomeName "more")
    PlanS -> Continues done
    SimplifyP -> Continues done
    Alternative -> Continues done
    Confirm -> ExitsOr (OutcomeName "confirmed") (OutcomeName "adjusted")
    Draft -> Continues done
    Implement -> Continues done
    Refactor -> Continues done
    Review -> ExitsOr (OutcomeName "clean") (OutcomeName "rows")
    Pick -> ExitsOr (OutcomeName "final") (OutcomeName "loop")
    Fix -> Continues done
    Describe -> Continues done
    SimplifyPR -> Continues done
    AwaitCi -> ExitsOr (OutcomeName "green") (OutcomeName "red")
    FixPR -> Continues done
    Ready -> Continues done
    Breakdown -> Continues done
    Merge -> Continues done
  where
    done = OutcomeName "done"

-- | An event of a run, @<step>.<outcome>@ on the wire, such as @review.rows@.
data EventName = EventName {step :: StateName, outcome :: OutcomeName}
    deriving stock (Eq, Ord, Show)

eventText :: EventName -> Text
eventText (EventName (StateName step) (OutcomeName outcome)) = step <> "." <> outcome

-- | The event a step's continuing outcome appends.
continueEvent :: Step i e o -> EventName
continueEvent s = EventName (stepName s) $ case outcomes s of
    Continues continue -> continue
    ExitsOr _ continue -> continue

-- | The event a step's exit outcome appends: only a step with an exit has one.
exitEvent :: Step i ('Just x) o -> EventName
exitEvent s = case outcomes s of
    ExitsOr exit _ -> EventName (stepName s) exit

-- | The event a skip appends: only an endo step can sit under an 'State.Flow.Opt'.
skipEvent :: Step i 'Nothing i -> EventName
skipEvent s = EventName (stepName s) skippedOutcome

-- | The outcome of a step a mode skipped, which no step has of its own.
skippedOutcome :: OutcomeName
skippedOutcome = OutcomeName "skipped"

-- | A generating arrow of @Cap@: one outcome of one step, @step.outcome : dom -> cod@.
data OutcomeEdge = OutcomeEdge {event :: EventName, dom :: Ty, cod :: Ty}
    deriving stock (Eq, Show)
