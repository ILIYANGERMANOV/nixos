{- | The name of a flow a run follows. A leaf, so a breakdown's task can name
its flow without importing the flows themselves: "State.Role" re-exports it
with each flow's definition.
-}
module State.FlowName (
    FlowName (..),
    defaultFlow,
    flowText,
    namedFlowText,
) where

import Data.Text (Text)

-- | A flow a run follows, named after the role that leads it.
data FlowName = EngineerFlow | TenXFlow | ArchitectFlow
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

{- | Its wire name, unless it is 'defaultFlow', which a line or an encoding
leaves out so it reads as it did before flows.
-}
namedFlowText :: FlowName -> Maybe Text
namedFlowText flow
    | flow == defaultFlow = Nothing
    | otherwise = Just (flowText flow)
