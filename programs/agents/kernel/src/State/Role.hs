{- | The roles that lead a flow: each names its flow, runs it, and stands on a
rung of the chain a question climbs. A role is a named flow with a rung; the
other agents (researchers, implementers, fixers) are workers that run one step
and lead nothing, so they are no entry here. Adding a role is a 'FlowName'
constructor, its 'flowText' and its 'role' arm; @flows/steps.nix@ names it in a row's
@flows@, which "State.Table" checks against 'roles'. A flow runs inline as a
branch of a larger one under a 'Scope' named after it: 'scopeFlow' reads the
scope back as the flow, and 'rungAt' the rung a question asked there climbs from.

The steps the roles' flows draw that no layer lists: each pick, with
its labels, and each skip. Their events carry no data, so each outcome is
its own reader.
-}
module State.Role (
    FlowName (..),
    defaultFlow,
    flowText,
    RoleDef (..),
    SomeFlow (..),
    flowOut,
    Rung (..),
    AgentRole (..),
    role,
    roles,
    leads,
    roleText,
    scopeFlow,
    flowAt,
    rungAt,
    drawnSteps,
    drawnOutcomes,
    drawnDecoders,
    SkipHere (..),
    skipHere,
    fuelTakes,
    isPick,
) where

import Data.Aeson (Object)
import Data.Aeson.Types (Parser)
import Data.Function (on)
import Data.List (find, nubBy)
import Data.Maybe (listToMaybe, mapMaybe)
import State.Category.Effect (Handler (..), Unhandled)
import State.Category.Flow (
    AgentRole (..),
    Effects,
    Flow (..),
    Name (..),
    roleText,
    scopeNames,
    unqualify,
 )
import State.Category.Fuel (
    Fuel,
    PerFuel,
    SkipWhen (Never),
    atFuel,
    parseByName,
 )
import State.Category.Step (
    EventName (..),
    SomeStep (..),
    StateName (..),
    StepSet (stepName),
 )
import State.Category.Ty (KnownTy (..), NotSum, TyOf (..), TyVal)
import State.Flow.Role.Architect (architect)
import State.Flow.Role.Chief (chief, discussion)
import State.Flow.Role.Engineer (engineer)
import State.Flow.Role.TenX (tenX)
import State.FlowName (FlowName (..), defaultFlow, flowText)
import State.Step.Catalog (
    AnyOutcome,
    AnyStep (..),
    Layer (FuelLayer, PickLayer),
    flowOutcomes,
    outcome,
    outcomeEvent,
    termSteps,
 )
import State.Step.Fuel (Outcome (Running, Skipping), Sing (Skip))

-- | A rung of the chain a question climbs; the user is the top.
data Rung = Worker | Lead | Orchestrator | User
    deriving stock (Eq, Show, Enum, Bounded)

-- | A role that leads a flow: its wire name, its flow, and its rung.
data RoleDef = RoleDef {name :: AgentRole, flow :: SomeFlow, rung :: Rung}

{- | A whole flow, whatever it ends in: a PR, a plan, a ticket. It exits
nowhere and handles every effect its steps raise, else it does not compile.
-}
data SomeFlow where
    SomeFlow ::
        (KnownTy o, NotSum o, Unhandled (Effects s) ~ '[]) =>
        Flow s 'Ctx 'Nothing o -> SomeFlow

-- | What the flow ends in.
flowOut :: SomeFlow -> TyVal
flowOut (SomeFlow (_ :: Flow s 'Ctx 'Nothing o)) = tyVal @o

{- | A named flow's handler, @Handle PickHandler@, removes only its picks: its
questions stay open, so a flow nested in another (a forked engineer, a
chief's branch) raises them to the enclosing flow. They bubble up to the
run's root, where the principal answers them: handled here once, as the
flow is registered. So are its waits on a PR's CI or merge, which only a
flow that ships PRs raises.
-}
role :: FlowName -> RoleDef
role flowName = case flowName of
    EngineerFlow ->
        RoleDef
            (AgentRole (flowText flowName))
            (SomeFlow (Handle AskHandler (Handle AwaitHandler engineer)))
            Lead
    TenXFlow ->
        RoleDef
            (AgentRole (flowText flowName))
            (SomeFlow (Handle AskHandler (Handle AwaitHandler tenX)))
            Orchestrator
    ArchitectFlow ->
        RoleDef
            (AgentRole (flowText flowName))
            (SomeFlow (Handle AskHandler architect))
            Lead
    ChiefFlow ->
        RoleDef
            (AgentRole (flowText flowName))
            (SomeFlow (Handle AskHandler (Handle AwaitHandler chief)))
            Lead

roles :: [RoleDef]
roles = map role [minBound .. maxBound]

-- | The flow a role leads; a worker leads none.
leads :: AgentRole -> Maybe FlowName
leads agent = find (\flowName -> (role flowName).name == agent) [minBound .. maxBound]

{- | The flow a scope runs inline: a scope named after a flow's wire name,
@Scope "10x" tenX@, runs that flow. The chief's @discussion@ runs as the
architect's, read-only and at its rung. Other scopes (@security@) run no flow
of their own.
-}
scopeFlow :: Name -> Maybe FlowName
scopeFlow = \case
    scope | scope == discussion -> Just ArchitectFlow
    Name scope -> parseByName flowText scope

-- | The flow running at this state: the innermost scope around it that runs one, else the run's own.
flowAt :: FlowName -> StateName -> FlowName
flowAt runFlow (StateName at) = case reverse (mapMaybe scopeFlow (scopeNames (fst (unqualify at)))) of
    innermost : _ -> innermost
    [] -> runFlow

-- | The rung a question asked at this state climbs from: that of the flow running there.
rungAt :: FlowName -> StateName -> Rung
rungAt runFlow asked = (role (flowAt runFlow asked)).rung

{- | Once per name: two flows drawing one name draw one step, or the step
table's check finds two readers of one event.
-}
drawnSteps :: [AnyStep]
drawnSteps =
    nubBy
        ((==) `on` nameOf)
        [step | RoleDef {flow = SomeFlow flow} <- roles, step <- termSteps flow]
  where
    nameOf (AnyStep _ (SomeStep s)) = stepName s

-- | Each drawn step's outcomes, in the flows' order.
drawnOutcomes :: [AnyOutcome]
drawnOutcomes = concatMap flowOutcomes drawnSteps

-- | A reader per drawn outcome, keyed by its event as 'State.Step.Catalog.outcomeDecoders' are.
drawnDecoders :: [(EventName, Object -> Parser AnyOutcome)]
drawnDecoders = [(outcomeEvent o, const (pure o)) | o <- drawnOutcomes]

-- | A skip step: its block, the levels that skip it, and its two outcomes.
data SkipHere = SkipHere
    { block :: Name
    , when :: PerFuel SkipWhen
    , skips :: AnyOutcome
    , runs :: AnyOutcome
    }

-- | The skip step of this name, when the flows draw one.
skipHere :: StateName -> Maybe SkipHere
skipHere name =
    listToMaybe
        [ SkipHere block when (outcome (Skipping s)) (outcome (Running s))
        | AnyStep FuelLayer (SomeStep s@(Skip block when)) <- drawnSteps
        , stepName s == name
        ]

-- | Whether a run at this Fuel takes the event out of the state: a skip its level never makes is no way on.
fuelTakes :: Fuel -> StateName -> EventName -> Bool
fuelTakes fuel name event = case skipHere name of
    Just skip
        | atFuel fuel skip.when == Never ->
            event.outcome /= (outcomeEvent skip.skips).outcome
    _ -> True

-- | Whether the flows draw a pick of this name: the agent picks its branch by label.
isPick :: StateName -> Bool
isPick name = or [stepName s == name | AnyStep PickLayer (SomeStep s) <- drawnSteps]
