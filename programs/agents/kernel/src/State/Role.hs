{- | The roles that lead a flow: each names its flow, runs it, and stands on a
rung of the chain a question climbs. A role is a named flow with a rung; the
other agents (researchers, implementers, fixers) are workers that run one step
and lead nothing, so they are no entry here. Adding a role is a 'FlowName'
constructor, its 'flowText' and its 'role' arm; @flows/steps.nix@ names it in a row's
@flows@, which "State.Table" checks against 'roles'.
-}
module State.Role (
    FlowName (..),
    defaultFlow,
    flowText,
    RoleDef (..),
    Rung (..),
    AgentRole (..),
    role,
    roles,
    leads,
    roleText,
) where

import Data.List (find)
import Data.Text (Text)
import State.Category.Flow (Flow)
import State.Category.Ty (Ty (..))
import State.Flow.Engineer (engineer)
import State.Flow.TenX (tenX)
import State.FlowName (FlowName (..), defaultFlow, flowText)

-- | A rung of the chain a question climbs; the user is the top.
data Rung = Worker | Lead | Orchestrator | User
    deriving stock (Eq, Show, Enum, Bounded)

-- | A subagent's role, as @state handback <role>@ names it: @implementer@.
newtype AgentRole = AgentRole Text
    deriving stock (Eq, Show)

-- | A role that leads a flow: its wire name, its flow, and its rung.
data RoleDef = RoleDef {name :: AgentRole, flow :: Flow 'Ctx 'Nothing 'PR, rung :: Rung}

role :: FlowName -> RoleDef
role flowName = case flowName of
    EngineerFlow -> RoleDef (AgentRole (flowText flowName)) engineer Lead
    TenXFlow -> RoleDef (AgentRole (flowText flowName)) tenX Orchestrator

roles :: [RoleDef]
roles = map role [minBound .. maxBound]

-- | The flow a role leads; a worker leads none.
leads :: AgentRole -> Maybe FlowName
leads agent = find (\flowName -> (role flowName).name == agent) [minBound .. maxBound]

roleText :: AgentRole -> Text
roleText (AgentRole name) = name
