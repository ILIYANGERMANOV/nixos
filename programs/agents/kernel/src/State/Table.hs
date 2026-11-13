{- | The step table, @programs/agents/flows/steps.nix@ written as JSON: who
runs each step and the task text @state next@ prints for it. The table names
each step's types and outcomes too, so the Nix side can derive roles from
plain data; 'parseSteps' holds them equal to "State.Category.Step", so the two cannot
drift.
-}
module State.Table (
    Steps,
    Row (..),
    Runner (..),
    parseSteps,
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
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import State.Category.Step (OutcomeName (..), Outcomes (..), SomeStep (..), StateName (..), Step, allSteps, outcomes, stepName)
import State.Category.Ty (KnownTy (..), Ty (..))
import State.Run.Event (AgentRole (..))

{- | A row for every step of "State.Category.Step" and no other, each with the step's
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
            <*> (fromMaybe [] <$> obj .:? "ops")

-- | The table, or every way it differs from the steps of "State.Category.Step".
parseSteps :: ByteString -> Either [Text] Steps
parseSteps raw = do
    written <- either (\why -> Left [Text.pack why]) Right (eitherDecode raw)
    let rows = Map.mapKeys StateName (written :: Map Text Written)
        known = Set.fromList [stepName s | SomeStep s <- allSteps]
        unknown = [name <> ": no such step" | StateName name <- Map.keys rows, not (Set.member (StateName name) known)]
        checked = map (check rows) allSteps
    case unknown <> concat (lefts checked) of
        [] -> Right (Steps (Map.fromList (rights checked)))
        problems -> Left problems

check :: Map StateName Written -> SomeStep -> Either [Text] (StateName, Row)
check rows (SomeStep s) = case Map.lookup name rows of
    Nothing -> Left [label <> ": no row"]
    Just written -> case (runnerOf written.runner written.lead, mismatches s written) of
        (Right runner, []) -> Right (name, Row runner written.task ("notify" `elem` written.ops))
        (runner, found) -> Left (map ((label <> ": ") <>) (lefts [runner] <> found))
  where
    name@(StateName label) = stepName s

mismatches :: forall i e o. (KnownTy i, KnownTy o) => Step i e o -> Written -> [Text]
mismatches s written =
    [ field <> " is " <> actual <> ", the step's is " <> expected
    | (field, actual, expected) <-
        [ ("dom", written.dom, tyText (tyVal @i))
        , ("cod", written.cod, tyText (tyVal @o))
        , ("exit", fromMaybe "null" written.exit, maybe "null" tyText exitTy)
        , ("outcomes", Text.unwords written.outcomes, Text.unwords [outcome | OutcomeName outcome <- names])
        ]
    , actual /= expected
    ]
  where
    (exitTy, names) = case outcomes s of
        Continues continue -> (Nothing, [continue])
        exits@(ExitsOr exitName continue) -> (Just (exitOf exits), [exitName, continue])

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
step of "State.Category.Step", so the lookup cannot miss.
-}
row :: Steps -> Step i e o -> Row
row (Steps rows) s = fromMaybe (error "parseSteps keeps a row for every step") (Map.lookup (stepName s) rows)

-- | The roles a subagent runs a step as, each once, in the order of the steps.
agentRoles :: Steps -> [AgentRole]
agentRoles steps = nub [role | SomeStep s <- allSteps, Agent role _ <- [(row steps s).runner]]
