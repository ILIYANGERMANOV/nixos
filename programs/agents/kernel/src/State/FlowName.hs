{- | The name of a flow a run follows. A leaf, so a breakdown's task can name
its flow without importing the flows themselves: "State.Role" re-exports it
with each flow's definition.
-}
module State.FlowName (
    FlowName (..),
    defaultFlow,
    flowText,
    namedFlowText,
    fixedFuel,
) where

import Data.Text (Text)
import State.Category.Fuel (Fuel (Balanced))

{- | The Fuel a flow runs at whoever starts it: the 10x picks each task's
Fuel and runs at Balanced itself, so its user is asked none. The chief has
none: each request, the first too, records its own at its Fuel step.
-}
fixedFuel :: FlowName -> Maybe Fuel
fixedFuel = \case
    TenXFlow -> Just Balanced
    ChiefFlow -> Nothing
    EngineerFlow -> Nothing
    ArchitectFlow -> Nothing

-- | A flow a run follows, named after the role that leads it.
data FlowName = EngineerFlow | TenXFlow | ArchitectFlow | ChiefFlow
    deriving stock (Eq, Show, Enum, Bounded)

-- | The flow a run, or a breakdown's task, follows when none is named.
defaultFlow :: FlowName
defaultFlow = EngineerFlow

-- | Its wire name, which is also the name of the role that leads it.
flowText :: FlowName -> Text
flowText = \case
    EngineerFlow -> "engineer"
    TenXFlow -> "10x"
    ArchitectFlow -> "architect"
    ChiefFlow -> "chief"

{- | Its wire name, unless it is 'defaultFlow', which a line or an encoding
leaves out so it reads as it did before flows.
-}
namedFlowText :: FlowName -> Maybe Text
namedFlowText flow
    | flow == defaultFlow = Nothing
    | otherwise = Just (flowText flow)
