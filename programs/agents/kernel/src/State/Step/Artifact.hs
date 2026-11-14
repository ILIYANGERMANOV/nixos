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
    Topic (..),
    Tasks,
    BreakdownError (..),
    breakdown,
    taskList,
    shaText,
    urlText,
    branchText,
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
    headOf,
    urlOf,
    draftOf,
    commitOf,
    picksOf,
    breakdownOf,
    decodeBreakdown,
    distinct,
    keyed,
    named,
) where

import Control.Monad (foldM)
import Data.Aeson (Object, Value, eitherDecodeStrictText, parseJSON, withObject, (.:), (.=))
import Data.Aeson.Encoding (Encoding, list, pair, pairs)
import Data.Aeson.Types (Parser, Series, parseEither)
import Data.Bifunctor (first)
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import State.Category.Mode (Area (..), Quality, Size, parseByName, parseQuality, qualityName, sizeName)

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
    , quality :: Quality
    , size :: Size
    , qa :: Bool
    , heavy :: Bool
    -- ^ At most one heavy task runs at a time.
    , security :: Set Topic
    }
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
            <> "quality" .= qualityName task.quality
            <> "size" .= sizeName task.size
            <> "qa" .= task.qa
            <> "heavy" .= task.heavy
            <> "security" .= map topicText (Set.toList task.security)

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
decodeBreakdown raw = first Text.pack (eitherDecodeStrictText raw >>= parseEither breakdownOf)

breakdownOf :: Value -> Parser Tasks
breakdownOf value = do
    tasks <- parseJSON value >>= traverse (withObject "task" taskFieldsOf)
    case NonEmpty.nonEmpty tasks of
        Nothing -> fail "a breakdown has a task at least"
        Just some -> either (fail . Text.unpack . breakdownErrorText) pure (breakdown some)
  where
    breakdownErrorText = \case
        TaskTwice (TaskId task) -> "task " <> task <> " is named twice"
        DependsLater (TaskId task) (TaskId dep) -> "task " <> task <> " depends on " <> dep <> ", which is not an earlier task"

taskFieldsOf :: Object -> Parser Task
taskFieldsOf obj =
    Task . TaskId
        <$> obj .: "id"
        <*> (map TaskId <$> obj .: "deps")
        <*> (Branch <$> obj .: "base")
        <*> (Branch <$> obj .: "branch")
        <*> (obj .: "quality" >>= named "quality" parseQuality)
        <*> (obj .: "size" >>= named "size" (parseByName sizeName))
        <*> obj .: "qa"
        <*> obj .: "heavy"
        <*> (obj .: "security" >>= traverse (named "topic" (parseByName topicText)) >>= distinct "topic")

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
