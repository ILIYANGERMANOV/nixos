{- | The roles that lead a flow: each names its flow, runs it, and stands on a
rung of the chain a question climbs. A role is a named flow with a rung; the
other agents (researchers, implementers, fixers) are workers that run one step
and lead nothing, so they are no entry here. Adding a role is a 'FlowName'
constructor and its 'role' arm; @flows/steps.nix@ names it in a row's
@flows@, which "State.Table" checks against 'roles'.
-}
module State.Role (
    FlowName (..),
    RoleDef (..),
    Rung (..),
    AgentRole (..),
    role,
    roles,
    roleText,
) where

import Data.Text (Text)
import State.Category.Flow (Flow)
import State.Category.Ty (Ty (..))
import State.Flow.Engineer (engineer)
import State.Flow.TenX (tenX)

-- | A flow a run follows, named after the role that leads it.
data FlowName = EngineerFlow | TenXFlow
    deriving stock (Eq, Show, Enum, Bounded)

-- | A rung of the chain a question climbs; the user is the top.
data Rung = Worker | Lead | Orchestrator | User
    deriving stock (Eq, Show, Enum, Bounded)

-- | A subagent's role, as @state handback <role>@ names it: @implementer@.
newtype AgentRole = AgentRole Text
    deriving stock (Eq, Show)

-- | A role that leads a flow: its wire name, its flow, and its rung.
data RoleDef = RoleDef {name :: AgentRole, flow :: Flow 'Ctx 'Nothing 'PR, rung :: Rung}

role :: FlowName -> RoleDef
role = \case
    EngineerFlow -> RoleDef (AgentRole "engineer") engineer Lead
    TenXFlow -> RoleDef (AgentRole "10x") tenX Orchestrator

roles :: [RoleDef]
roles = map role [minBound .. maxBound]

roleText :: AgentRole -> Text
roleText (AgentRole name) = name
