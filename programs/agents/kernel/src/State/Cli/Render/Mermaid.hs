{- | A flow's graph as a Mermaid state diagram, one transition per edge,
labelled with its outcome ('eventLabel'). Fuel and skips are marks on the term, not in the
graph (#351), so the diagram is the same in every mode.
-}
module State.Cli.Render.Mermaid (mermaid) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import State.Category.Graph (Edge (..), Node (..), OpenGraph (..), Place (..), eventLabel, placeName, places)
import State.Category.Step (StateName (..), stateNameText)

{- | In the graph's order, which is the term's: a block's states before the
next block's. 'Out' and 'Exit' are both ends, @[*]@, told apart by the label.
A scoped state, whose id is not its name, is declared first, labelled with its name.
-}
mermaid :: OpenGraph -> Text
mermaid g =
    Text.unlines $
        ["stateDiagram-v2", "  direction LR"]
            <> ["  state \"" <> name <> "\" as " <> ident place | place <- Set.toList (places g), let StateName name = placeName place, ident place /= name]
            <> ["  [*] --> " <> ident g.inPort]
            <> [ "  " <> ident from <> " --> " <> node edge.to <> ": " <> eventLabel from event
               | ((from, event), edge) <- Map.toList g.edges
               ]
  where
    node = \case
        At place -> ident place
        Out -> "[*]"
        Exit -> "[*]"

{- | A state's id: its name, which the graph holds once
('State.Category.Graph.SameState'). An id takes no @/@, so a scope's is
spelled @__@, which no step's name holds.
-}
ident :: Place -> Text
ident place = Text.replace "/" "__" (stateNameText (placeName place))
