{- | The step table, @programs/agents/flows/steps.nix@ written as JSON: who
runs each step and the task text @state next@ prints for it. The table names
each step's types and outcomes too, so the Nix side can derive roles from
plain data; 'parseSteps' holds them equal to the layers' ("State.Step.Catalog"),
so the two cannot drift.
-}
module State.Table (
    Steps,
    Row (..),
    Runner (..),
    parseSteps,
    namingProblems,
    row,
    agentRoles,
) where

import Data.Aeson (FromJSON (..), eitherDecode, withObject, (.:), (.:?))
import Data.ByteString.Lazy (ByteString)
import Data.Either (lefts, rights)
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import State.Category.Step (CodOf, DomOf, EventName (..), OutcomeName (..), Outcomes (..), Sig, Sing, SomeStep (..), StateName (..), StepSet, eventText, outcomes, skippedOutcome, stateNameText, stepName)
import State.Category.Ty (KnownTy (..), Ty (..))
import State.Role (AgentRole (..), RoleDef (..), roleText, roles)
import State.Step.Catalog (AnyStep (..), allSteps, outcomeDecoders, outcomeSteps)

{- | A row for every step of the layers and no other, each with the step's
types and outcomes. Only 'parseSteps' builds one.
-}
newtype Steps = Steps (Map StateName Row)

{- | What the kernel reads of a row; the types and outcomes are checked, not
kept. The task is what the runner executes: @state next@ prints an agent
step's lead part and then the task, @state brief@ the task alone, so a
worker's brief holds none of the lead's commands.
-}
data Row = Row {runner :: Runner, task :: Text, notifies :: Bool}
    deriving stock (Eq, Show)

{- | Who runs a step: the lead itself, or a subagent of this role, with the
lead's part, how it spawns and records that subagent.
-}
data Runner = Inline | Agent AgentRole Text
    deriving stock (Eq, Show)

-- | A row as written, before it is checked against its step.
data Written = Written
    { dom :: Text
    , cod :: Text
    , exit :: Maybe Text
    , outcomes :: [Text]
    , runner :: Text
    , lead :: Maybe Text
    , task :: Text
    , flows :: [Text]
    , ops :: [Text]
    }

instance FromJSON Written where
    parseJSON = withObject "step" $ \obj ->
        Written
            <$> obj .: "dom"
            <*> obj .: "cod"
            <*> obj .: "exit"
            <*> obj .: "outcomes"
            <*> obj .: "runner"
            <*> obj .:? "lead"
            <*> obj .: "task"
            <*> obj .: "flows"
            <*> (fromMaybe [] <$> obj .:? "ops")

{- | The table, or every way it differs from the layers' steps. The layers
are checked too, as the table is read: step and outcome wire names are each
unique, and each step reads exactly its own outcomes, so no layer can leave
one out or name another's.
-}
parseSteps :: ByteString -> Either [Text] Steps
parseSteps raw = do
    written <- either (\why -> Left [Text.pack why]) Right (eitherDecode raw)
    let rows = Map.mapKeys StateName (written :: Map Text Written)
        known = Set.fromList stepNames
        unknown = [name <> ": no such step" | StateName name <- Map.keys rows, not (Set.member (StateName name) known)]
        checked = map (check rows) allSteps
    case catalogProblems <> unknown <> concat (lefts checked) of
        [] -> Right (Steps (Map.fromList (rights checked)))
        problems -> Left problems

stepNames :: [StateName]
stepNames = [stepName s | AnyStep _ (SomeStep s) <- allSteps]

-- | Every way the layers' own names clash or miss an outcome.
catalogProblems :: [Text]
catalogProblems = namingProblems stepNames readers declared
  where
    readers = map fst outcomeDecoders
    declared = Set.fromList (concat [stepEvents s (EventName (stepName s) skippedOutcome `elem` readers) | AnyStep _ (SomeStep s) <- outcomeSteps])

{- | Every way these names clash or miss an outcome: the steps' names, the
event each outcome reader reads, and the events the steps declare.
-}
namingProblems :: [StateName] -> [EventName] -> Set EventName -> [Text]
namingProblems steps readers declared =
    [stateNameText name <> ": two steps have this name" | name <- twice steps]
        <> [eventText event <> ": two readers read this event" | event <- twice readers]
        <> [eventText event <> ": no step has this outcome" | event <- readers, not (Set.member event declared)]
        <> [eventText event <> ": no layer reads this outcome" | event <- Set.toList declared, event `notElem` readers]
  where
    twice :: (Ord a) => [a] -> [a]
    twice names = Map.keys (Map.filter (> (1 :: Int)) (Map.fromListWith (+) [(name, 1) | name <- names]))

-- | A step's events: its exit and continuing ones, and its skip if it has one.
stepEvents :: (StepSet k) => Sing (s :: k) -> Bool -> [EventName]
stepEvents s skips = map (EventName (stepName s)) (names <> [skippedOutcome | skips])
  where
    names = case outcomes s of
        Continues continue -> [continue]
        ExitsOr exit continue -> [exit, continue]

check :: Map StateName Written -> AnyStep -> Either [Text] (StateName, Row)
check rows (AnyStep _ (SomeStep s)) = case Map.lookup name rows of
    Nothing -> Left [label <> ": no row"]
    Just written -> case (runnerOf written.runner written.lead, mismatches s written <> roleProblems written) of
        (Right runner, []) -> Right (name, Row runner written.task ("notify" `elem` written.ops))
        (runner, found) -> Left (map ((label <> ": ") <>) (lefts [runner] <> found))
  where
    name@(StateName label) = stepName s

mismatches :: forall k (s :: k). (StepSet k, KnownTy (DomOf (Sig s)), KnownTy (CodOf (Sig s))) => Sing s -> Written -> [Text]
mismatches s written =
    [ field <> " is " <> actual <> ", the step's is " <> expected
    | (field, actual, expected) <-
        [ ("dom", written.dom, tyText (tyVal @(DomOf (Sig s))))
        , ("cod", written.cod, tyText (tyVal @(CodOf (Sig s))))
        , ("exit", fromMaybe "null" written.exit, maybe "null" tyText exitTy)
        , ("outcomes", Text.unwords written.outcomes, Text.unwords [outcome | OutcomeName outcome <- names])
        ]
    , actual /= expected
    ]
  where
    (exitTy, names) = case outcomes s of
        Continues continue -> (Nothing, [continue])
        exits@(ExitsOr exitName continue) -> (Just (exitOf exits), [exitName, continue])

{- | Every way a row's roles miss the registry ("State.Role"): each flow it
names is a role's, and its runner leads no flow, since a lead runs its own
flow's steps inline.
-}
roleProblems :: Written -> [Text]
roleProblems written =
    ["flows names " <> flow <> ", which no role leads" | flow <- written.flows, flow `notElem` leads]
        <> [written.runner <> " leads a flow, so it runs no step as a subagent" | written.runner `elem` leads]
  where
    leads = map (\def -> roleText def.name) roles

exitOf :: forall x. Outcomes ('Just x) -> Ty
exitOf (ExitsOr _ _) = tyVal @x

-- | As the table spells a type: @[Ctx]@ for a list.
tyText :: Ty -> Text
tyText = \case
    Ctx -> "Ctx"
    Plan -> "Plan"
    Diff -> "Diff"
    PR -> "PR"
    List t -> "[" <> tyText t <> "]"

-- | The runner sum: an inline step has no lead, a role's step has one.
runnerOf :: Text -> Maybe Text -> Either Text Runner
runnerOf runner lead = case (runner, lead) of
    ("inline", Nothing) -> Right Inline
    ("inline", Just _) -> Left "an inline step has no lead"
    (role, Just part) -> Right (Agent (AgentRole role) part)
    (role, Nothing) -> Left ("a step run by " <> role <> " needs a lead")

{- | The step's row. Total: 'parseSteps' built the map with a row for every
step of the layers, so the lookup cannot miss.
-}
row :: (StepSet k) => Steps -> Sing (s :: k) -> Row
row (Steps rows) s = fromMaybe (error "parseSteps keeps a row for every step") (Map.lookup (stepName s) rows)

-- | The roles a subagent runs a step as, each once, in the order of the steps.
agentRoles :: Steps -> [AgentRole]
agentRoles steps = nub [role | AnyStep _ (SomeStep s) <- allSteps, Agent role _ <- [(row steps s).runner]]
