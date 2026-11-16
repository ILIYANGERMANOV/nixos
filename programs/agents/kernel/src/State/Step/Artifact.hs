{- | What the steps' outcomes report - a commit, a PR, the picks, the tasks -
and how the log spells each. The layers of "State.Step" share them; the
run's other events name some too ("State.Run.Event").
-}
module State.Step.Artifact (
    DraftPr (..),
    Commit (..),
    Picks (..),
    Judgement (..),
    Sha (..),
    Url (..),
    Branch (..),
    Label (..),
    Requirement (..),
    Check (..),
    TaskId (..),
    Task (..),
    Shape (..),
    Repo (..),
    ShellPath,
    Topic (..),
    Tasks,
    BreakdownError (..),
    breakdown,
    taskList,
    shaText,
    urlText,
    branchText,
    repoText,
    shellPath,
    shellPathText,
    shellPathRule,
    slugChar,
    shellWord,
    taskIdText,
    topicText,
    judgementText,
    areaText,
    headData,
    urlData,
    draftData,
    commitData,
    picksData,
    tasksData,
    taskEncoding,
    shapeData,
    headOf,
    urlOf,
    draftOf,
    commitOf,
    picksOf,
    breakdownOf,
    decodeBreakdown,
    taskOf,
    shapeOf,
    decodeTask,
    distinct,
    keyed,
    named,
) where

import Control.Monad (foldM)
import Data.Aeson (Object, Value, eitherDecodeStrictText, parseJSON, withObject, (.:), (.:?), (.=))
import Data.Aeson.Encoding (Encoding, list, pair, pairs)
import Data.Aeson.Types (Parser, Series, parseEither)
import Data.Bifunctor (first)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import State.Category.Fuel (Area (..), Fuel, fuelName, parseByName, parseFuel)
import State.FlowName (FlowName, defaultFlow, flowText, namedFlowText)
import System.FilePath (isAbsolute)

-- | The draft PR, synced from GitHub.
data DraftPr = DraftPr {url :: Url, base :: Branch, branch :: Branch}
    deriving stock (Eq, Show)

-- | A commit and the areas it touches, which decide a fix's full review.
data Commit = Commit {head :: Sha, touches :: Set Area}
    deriving stock (Eq, Show)

{- | The rows to fix, labelled so one finding keeps its label across rounds,
and the verdict on each requirement.
-}
data Picks = Picks {rows :: Set Label, verdicts :: Map Requirement Judgement}
    deriving stock (Eq, Show)

data Judgement = Met | NotMet | Unverified
    deriving stock (Eq, Show, Enum, Bounded)

newtype Sha = Sha Text
    deriving stock (Eq, Show)

newtype Url = Url Text
    deriving stock (Eq, Show)

newtype Branch = Branch Text
    deriving stock (Eq, Show)

newtype Label = Label Text
    deriving stock (Eq, Ord, Show)

newtype Requirement = Requirement Text
    deriving stock (Eq, Ord, Show)

-- | A CI check, by name.
newtype Check = Check Text
    deriving stock (Eq, Ord, Show)

-- | A task of the 10x's breakdown, by the id the breakdown gives it.
newtype TaskId = TaskId Text
    deriving stock (Eq, Ord, Show)

-- | What the engineer run for a task is briefed with.
data Task = Task
    { id :: TaskId
    , deps :: [TaskId]
    -- ^ Tasks whose work this one builds on: earlier ones only.
    , base :: Branch
    , branch :: Branch
    , fuel :: Fuel
    , qa :: Bool
    , heavy :: Bool
    -- ^ Advisory: the kernel caps nothing on it; it stays on the wire for old breakdowns.
    , security :: Set Topic
    , shape :: Shape
    , repo :: Maybe Repo
    -- ^ The repo the task's work lands in, when the breakdown names it: its brief's notes dir.
    , worktree :: Maybe ShellPath
    -- ^ When the breakdown names it: its brief's init line runs there.
    , flow :: FlowName
    -- ^ The flow its child run follows: an engineer's unless the breakdown names another.
    }
    deriving stock (Eq, Show)

-- | A GitHub repository as @gh@ names it, @OWNER/REPO@.
data Repo = Repo {owner :: Text, name :: Text}
    deriving stock (Eq, Show)

{- | @OWNER/REPO@: one slash, each side non-empty and of 'slugChar's, as
GitHub allows, so a brief prints it in a shell line unquoted.
-}
parseRepo :: Text -> Maybe Repo
parseRepo raw = case Text.splitOn "/" raw of
    [owner, name] | all part [owner, name] -> Just (Repo owner name)
    _ -> Nothing
  where
    part text = not (Text.null text) && Text.all slugChar text

repoText :: Repo -> Text
repoText repo = repo.owner <> "/" <> repo.name

{- | A path a shell line prints unquoted, so it runs from any directory:
absolute, of 'slugChar's, @/@, @\@@ and @+@ only - none a shell reads as
syntax. Built by 'shellPath' alone.
-}
newtype ShellPath = ShellPath FilePath
    deriving stock (Eq, Show)

shellPath :: FilePath -> Maybe ShellPath
shellPath path
    | isAbsolute path, all pathChar path = Just (ShellPath path)
    | otherwise = Nothing
  where
    pathChar c = slugChar c || c `elem` ("/@+" :: String)

shellPathText :: ShellPath -> FilePath
shellPathText (ShellPath path) = path

-- | What 'shellPath' accepts, as a refusal names it.
shellPathRule :: String
shellPathRule = "an absolute path of ASCII letters, digits and ._/@+-"

-- | A character a shell word holds unquoted, with no meaning to the shell: ASCII letters, digits, @.@, @_@ and @-@.
slugChar :: Char -> Bool
slugChar c = isAsciiLower c || isAsciiUpper c || isDigit c || c `elem` ("._-" :: String)

{- | Text as one shell word: as it is when all 'slugChar's, else single-quoted
with each @'@ written @'\\''@, so a printed line runs as it reads.
-}
shellWord :: Text -> Text
shellWord text
    | not (Text.null text), Text.all slugChar text = text
    | otherwise = "'" <> Text.replace "'" "'\\''" text <> "'"

{- | What the task's engineer does to its PR. A round on a PR that already
exists leaves it open: its run skips @ready@, and the task settles kept.
-}
data Shape = OwnPr | RoundOn Url
    deriving stock (Eq, Show)

-- | The security-sensitive work a task's brief flags.
data Topic = CiTopic | AuthTopic | DatabaseTopic | SecretsTopic
    deriving stock (Eq, Ord, Show, Enum, Bounded)

{- | The tasks in order, ids unique, each depending on earlier tasks only, so
the dependencies are acyclic by construction. Built by 'breakdown' alone.
-}
newtype Tasks = Tasks (NonEmpty Task)
    deriving stock (Eq, Show)

data BreakdownError
    = TaskTwice TaskId
    | -- | The task names a dependency that is not an earlier task.
      DependsLater TaskId TaskId
    deriving stock (Eq, Show)

breakdown :: NonEmpty Task -> Either BreakdownError Tasks
breakdown tasks = Tasks tasks <$ foldM check [] tasks
  where
    check seen task =
        case (task.id `elem` seen, filter (`notElem` seen) task.deps) of
            (True, _) -> Left (TaskTwice task.id)
            (False, later : _) -> Left (DependsLater task.id later)
            (False, []) -> Right (task.id : seen)

taskList :: Tasks -> [Task]
taskList (Tasks tasks) = toList tasks

shaText :: Sha -> Text
shaText (Sha sha) = sha

urlText :: Url -> Text
urlText (Url url) = url

branchText :: Branch -> Text
branchText (Branch branch) = branch

taskIdText :: TaskId -> Text
taskIdText (TaskId task) = task

topicText :: Topic -> Text
topicText = \case
    CiTopic -> "ci"
    AuthTopic -> "auth"
    DatabaseTopic -> "database"
    SecretsTopic -> "secrets"

-- | As a review's verdict table spells them.
judgementText :: Judgement -> Text
judgementText = \case
    Met -> "met"
    NotMet -> "not-met"
    Unverified -> "unverified"

areaText :: Area -> Text
areaText = \case
    Interface -> "interface"
    DataModel -> "data-model"
    Auth -> "auth"

headData :: Sha -> Series
headData sha = "head" .= shaText sha

urlData :: Url -> Series
urlData url = "url" .= urlText url

draftData :: DraftPr -> Series
draftData draft = urlData draft.url <> "base" .= branchText draft.base <> "branch" .= branchText draft.branch

commitData :: Commit -> Series
commitData commit = headData commit.head <> "touches" .= map areaText (Set.toList commit.touches)

picksData :: Picks -> Series
picksData picks =
    "rows" .= map (\(Label label) -> label) (Set.toList picks.rows)
        <> pair "verdicts" (list verdictEncoding (Map.toList picks.verdicts))
  where
    verdictEncoding (Requirement requirement, judgement) =
        pairs ("requirement" .= requirement <> "outcome" .= judgementText judgement)

tasksData :: Tasks -> Series
tasksData tasks = pair "tasks" (list taskEncoding (taskList tasks))

taskEncoding :: Task -> Encoding
taskEncoding task =
    pairs $
        "id" .= taskIdText task.id
            <> "deps" .= map taskIdText task.deps
            <> "base" .= branchText task.base
            <> "branch" .= branchText task.branch
            <> "fuel" .= fuelName task.fuel
            <> "qa" .= task.qa
            <> "heavy" .= task.heavy
            <> "security" .= map topicText (Set.toList task.security)
            <> shapeData task.shape
            <> maybe mempty (("repo" .=) . repoText) task.repo
            <> maybe mempty (("worktree" .=) . shellPathText) task.worktree
            <> flowData task.flow

-- | The default flow is omitted, so a breakdown older than flows encodes as it was written.
flowData :: FlowName -> Series
flowData = maybe mempty ("flow" .=) . namedFlowText

-- | Only a round names its PR: a log older than rounds reads as own PRs.
shapeData :: Shape -> Series
shapeData = \case
    OwnPr -> mempty
    RoundOn url -> "pr" .= urlText url

headOf :: Object -> Parser Sha
headOf obj = Sha <$> obj .: "head"

urlOf :: Object -> Parser Url
urlOf obj = Url <$> obj .: "url"

draftOf :: Object -> Parser DraftPr
draftOf obj = DraftPr <$> urlOf obj <*> (Branch <$> obj .: "base") <*> (Branch <$> obj .: "branch")

commitOf :: Object -> Parser Commit
commitOf obj = Commit <$> headOf obj <*> (Set.fromList <$> (obj .: "touches" >>= traverse (named "area" (parseByName areaText))))

picksOf :: Object -> Parser Picks
picksOf obj =
    Picks
        <$> (obj .: "rows" >>= distinct "row" . map Label)
        <*> (obj .: "verdicts" >>= traverse (withObject "verdict" verdictOf) >>= keyed "requirement")
  where
    verdictOf verdict = (,) . Requirement <$> verdict .: "requirement" <*> (verdict .: "outcome" >>= named "outcome" (parseByName judgementText))

-- | A breakdown file: the JSON array @breakdown.done@ logs as its @tasks@.
decodeBreakdown :: Text -> Either Text Tasks
decodeBreakdown = decodeWith breakdownOf

-- | A task file for @task add@: one task, as a breakdown file spells each.
decodeTask :: Text -> Either Text Task
decodeTask = decodeWith taskOf

decodeWith :: (Value -> Parser a) -> Text -> Either Text a
decodeWith parser raw = first Text.pack (eitherDecodeStrictText raw >>= parseEither parser)

breakdownOf :: Value -> Parser Tasks
breakdownOf value = do
    tasks <- parseJSON value >>= traverse taskOf
    case NonEmpty.nonEmpty tasks of
        Nothing -> fail "a breakdown has a task at least"
        Just some -> either (fail . Text.unpack . breakdownErrorText) pure (breakdown some)
  where
    breakdownErrorText = \case
        TaskTwice (TaskId task) -> "task " <> task <> " is named twice"
        DependsLater (TaskId task) (TaskId dep) -> "task " <> task <> " depends on " <> dep <> ", which is not an earlier task"

taskOf :: Value -> Parser Task
taskOf = withObject "task" taskFieldsOf

-- | By name, as a field a later breakdown adds is one more line; an optional one is omitted when absent.
taskFieldsOf :: Object -> Parser Task
taskFieldsOf obj = do
    taskId <- TaskId <$> obj .: "id"
    deps <- map TaskId <$> obj .: "deps"
    base <- Branch <$> obj .: "base"
    branch <- Branch <$> obj .: "branch"
    fuel <- obj .: "fuel" >>= named "fuel" parseFuel
    qa <- obj .: "qa"
    heavy <- obj .: "heavy"
    security <- obj .: "security" >>= traverse (named "topic" (parseByName topicText)) >>= distinct "topic"
    shape <- shapeOf obj
    repo <- obj .:? "repo" >>= traverse (named "repo" parseRepo)
    worktree <- obj .:? "worktree" >>= traverse worktreeOf
    flow <- fromMaybe defaultFlow <$> (obj .:? "flow" >>= traverse (named "flow" (parseByName flowText)))
    pure Task {id = taskId, deps, base, branch, fuel, qa, heavy, security, shape, repo, worktree, flow}
  where
    worktreeOf path = maybe (fail ("a worktree is " <> shellPathRule <> ", not " <> show path)) pure (shellPath path)

shapeOf :: Object -> Parser Shape
shapeOf obj = maybe OwnPr (RoundOn . Url) <$> obj .:? "pr"

{- | A list read as a set, refusing a repeat: a set would keep one copy
silently, and a log naming one twice is a bug in its writer.
-}
distinct :: (Ord a) => String -> [a] -> Parser (Set a)
distinct what = fmap Map.keysSet . keyed what . map (,())

-- | Pairs read as a map, refusing a repeated key, where a map would keep the last.
keyed :: (Ord k) => String -> [(k, v)] -> Parser (Map k v)
keyed what entries
    | Map.size byKey == length entries = pure byKey
    | otherwise = fail ("repeated " <> what)
  where
    byKey = Map.fromList entries

named :: String -> (Text -> Maybe a) -> Text -> Parser a
named what parse raw = maybe (fail ("unknown " <> what <> " " <> show raw)) pure (parse raw)
