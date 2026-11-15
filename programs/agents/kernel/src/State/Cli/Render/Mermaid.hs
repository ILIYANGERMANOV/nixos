{- | A flow's graph as a Mermaid state diagram, one transition per edge,
labelled with its outcome ('eventLabel'). Fuel and skips are marks on the term, not in the
graph (#351), so the diagram is the same in every mode.
-}
module State.Cli.Render.Mermaid (mermaid) where

import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import State.Category.Graph (Edge (..), Node (..), OpenGraph (..), Place (..), eventLabel, placeName, places)
import State.Category.Step (StateName (..), stateNameText)

{- | In the graph's order, which is the term's: a block's states before the
next block's. 'Out' and 'Exit' are both ends, @[*]@, told apart by the label.
A state whose id is not its name is declared first, labelled with its name.
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
    ident = placeId (sharedNames g)
    node = \case
        At place -> ident place
        Out -> "[*]"
        Exit -> "[*]"

{- | A state's name, plus its path where another state has the same name:
Mermaid would draw two states with one id as one. An id takes no @/@, so
a scope's is spelled @__@, which no step's name holds.
-}
placeId :: Set StateName -> Place -> Text
placeId shared place
    | placeName place `Set.member` shared = Text.intercalate "_" (name : map (Text.pack . show) place.path)
    | otherwise = name
  where
    name = Text.replace "/" "__" (stateNameText (placeName place))

-- | Names of two or more states.
sharedNames :: OpenGraph -> Set StateName
sharedNames g =
    Map.keysSet . Map.filter (> (1 :: Int)) $
        Map.fromListWith (+) [(placeName place, 1) | place <- Set.toList (places g)]
