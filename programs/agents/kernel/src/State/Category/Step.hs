{- | The arrows of #351's category @Cap@: the typed steps between its
artifact types. A step is the bundle of its outcome edges, exits first,
the continuing one last.
-}
module State.Category.Step (
    Step (..),
    SomeStep (..),
    allSteps,
    stepNamed,
    StateName (..),
    stepName,
    stateNameText,
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
import State.Category.Ty (KnownTy, Ty (..))

{- | @i@: in. @e@: the exit, if the step has one. @o@: continue. Only an
endo step (@i ~ o@, no exit) can sit under 'State.Category.Flow.Opt', so the steps a
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

-- | A step of any type, so the steps can sit in one list.
data SomeStep where
    SomeStep :: (KnownTy i, KnownTy o) => Step i e o -> SomeStep

{- | Every step, in the order the flows run them. A GADT cannot be enumerated,
so the match below is the reminder: a new step breaks the build there, next
to this list.
-}
allSteps :: [SomeStep]
allSteps =
    [ SomeStep Research
    , SomeStep Interview
    , SomeStep PlanS
    , SomeStep SimplifyP
    , SomeStep Alternative
    , SomeStep Confirm
    , SomeStep Draft
    , SomeStep Implement
    , SomeStep Refactor
    , SomeStep Review
    , SomeStep Pick
    , SomeStep Fix
    , SomeStep Describe
    , SomeStep SimplifyPR
    , SomeStep AwaitCi
    , SomeStep FixPR
    , SomeStep Ready
    , SomeStep Breakdown
    , SomeStep Merge
    ]
  where
    _listsEvery :: Step i e o -> ()
    _listsEvery = \case
        Research -> ()
        Interview -> ()
        PlanS -> ()
        SimplifyP -> ()
        Alternative -> ()
        Confirm -> ()
        Draft -> ()
        Implement -> ()
        Refactor -> ()
        Review -> ()
        Pick -> ()
        Fix -> ()
        Describe -> ()
        SimplifyPR -> ()
        AwaitCi -> ()
        FixPR -> ()
        Ready -> ()
        Breakdown -> ()
        Merge -> ()

-- | The step a state is named after; a fan-out's state names none.
stepNamed :: StateName -> Maybe SomeStep
stepNamed name = lookup name [(someName some, some) | some <- allSteps]
  where
    someName (SomeStep s) = stepName s

-- | A state of a flow's graph, by name: what people read, and an override's target.
newtype StateName = StateName Text
    deriving stock (Eq, Ord, Show)

stateNameText :: StateName -> Text
stateNameText (StateName name) = name

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
('State.Category.Graph.graph').
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

-- | The event a skip appends: only an endo step can sit under an 'State.Category.Flow.Opt'.
skipEvent :: Step i 'Nothing i -> EventName
skipEvent s = EventName (stepName s) skippedOutcome

-- | The outcome of a step a mode skipped, which no step has of its own.
skippedOutcome :: OutcomeName
skippedOutcome = OutcomeName "skipped"

-- | A generating arrow of @Cap@: one outcome of one step, @step.outcome : dom -> cod@.
data OutcomeEdge = OutcomeEdge {event :: EventName, dom :: Ty, cod :: Ty}
    deriving stock (Eq, Show)
