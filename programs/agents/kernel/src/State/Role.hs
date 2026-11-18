{- | The roles that lead a flow: each names its flow, runs it, and stands on a
rung of the chain a question climbs. A role is a named flow with a rung; the
other agents (researchers, implementers, fixers) are workers that run one step
and lead nothing, so they are no entry here. Adding a role is a 'FlowName'
constructor, its 'flowText' and its 'role' arm; @flows/steps.nix@ names it in a row's
@flows@, which "State.Table" checks against 'roles'. A flow runs inline as a
branch of a larger one under a 'Scope' named after it: 'scopeFlow' reads the
scope back as the flow, and 'rungAt' the rung a question asked there climbs from.
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
) where

import Data.List (find)
import Data.Maybe (mapMaybe)
import State.Category.Effect (Unhandled)
import State.Category.Flow (AgentRole (..), Effects, Flow, Name (..), roleText, scopeNames, unqualify)
import State.Category.Fuel (parseByName)
import State.Category.Step (StateName (..))
import State.Category.Ty (KnownTy (..), NotSum, TyOf (..), TyVal)
import State.Flow.Architect (architect)
import State.Flow.Chief (chief, discussion)
import State.Flow.Engineer (engineer)
import State.Flow.TenX (tenX)
import State.FlowName (FlowName (..), defaultFlow, flowText)

-- | A rung of the chain a question climbs; the user is the top.
data Rung = Worker | Lead | Orchestrator | User
    deriving stock (Eq, Show, Enum, Bounded)

-- | A role that leads a flow: its wire name, its flow, and its rung.
data RoleDef = RoleDef {name :: AgentRole, flow :: SomeFlow, rung :: Rung}

{- | A whole flow, whatever it ends in: a PR, a plan, a ticket. It exits
nowhere and handles every effect its steps raise, else it does not compile.
-}
data SomeFlow where
    SomeFlow :: (KnownTy o, NotSum o, Unhandled (Effects s) ~ '[]) => Flow s 'Ctx 'Nothing o -> SomeFlow

-- | What the flow ends in.
flowOut :: SomeFlow -> TyVal
flowOut (SomeFlow (_ :: Flow s 'Ctx 'Nothing o)) = tyVal @o

role :: FlowName -> RoleDef
role flowName = case flowName of
    EngineerFlow -> RoleDef (AgentRole (flowText flowName)) (SomeFlow engineer) Lead
    TenXFlow -> RoleDef (AgentRole (flowText flowName)) (SomeFlow tenX) Orchestrator
    ArchitectFlow -> RoleDef (AgentRole (flowText flowName)) (SomeFlow architect) Lead
    ChiefFlow -> RoleDef (AgentRole (flowText flowName)) (SomeFlow chief) Lead

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
