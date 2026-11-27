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
    Target (..),
    PlanCall (..),
    Repo (..),
    parsePrUrl,
    prUrlRule,
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
    judgementName,
    areaText,
    areaName,
    planName,
    headData,
    urlData,
    draftData,
    commitData,
    picksData,
    tasksData,
    taskEncoding,
    shapeData,
    targetData,
    planData,
    headOf,
    urlOf,
    draftOf,
    commitOf,
    picksOf,
    breakdownOf,
    decodeBreakdown,
    taskOf,
    shapeOf,
    targetOf,
    planOf,
    decodeTask,
    distinct,
    keyed,
    named,
    unknownCase,
    tag,
    tagged,
) where

import Control.Applicative ((<|>))
import Control.Monad (foldM)
import Data.Aeson (
    Object,
    Value,
    eitherDecodeStrictText,
    parseJSON,
    withObject,
    (.:),
    (.:?),
    (.=),
 )
import Data.Aeson.Encoding (Encoding, list, pair, pairs)
import Data.Aeson.Types (Parser, Series, parseEither)
import Data.Bifunctor (first)
import Data.Bool (bool)
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
    , plan :: PlanCall
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

{- | A pull request's URL as GitHub prints it,
@https://github.com/OWNER/REPO/pull/N@: a 'parseRepo' repo and a number
from 1, with no leading zero, so one PR has one spelling.
-}
parsePrUrl :: Text -> Maybe Url
parsePrUrl raw = case Text.splitOn "/" <$> Text.stripPrefix "https://github.com/" raw of
    Just [owner, name, "pull", number]
        | Just _ <- parseRepo (owner <> "/" <> name)
        , Just (lead, _) <- Text.uncons number
        , lead /= '0'
        , Text.all isDigit number ->
            Just (Url raw)
    _ -> Nothing

-- | What 'parsePrUrl' accepts, as a refusal names it.
prUrlRule :: Text
prUrlRule = "a GitHub PR URL, https://github.com/<owner>/<repo>/pull/<n>"

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

{- | The existing work a request applies feedback to: a PR, a branch or a
ticket. A request that names none opens new work.
-}
data Target = OnPr Url | OnBranch Branch | OnTicket Url
    deriving stock (Eq, Show)

{- | Who settles the task's plan: its child confirms it with its parent, or
the parent decided it already, so the child neither simplifies nor confirms it.
-}
data PlanCall = ChildConfirms | ParentDecided
    deriving stock (Eq, Show, Enum, Bounded)

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

-- | As the log spells it, lowercase snake_case; the CLI's is 'judgementText'.
judgementName :: Judgement -> Text
judgementName = \case
    Met -> "met"
    NotMet -> "not_met"
    Unverified -> "unverified"

-- | As the CLI and a hand-back spell it.
areaText :: Area -> Text
areaText = \case
    Interface -> "interface"
    DataModel -> "data-model"
    Auth -> "auth"

-- | As the log spells it, lowercase snake_case; the CLI's is 'areaText'.
areaName :: Area -> Text
areaName = \case
    Interface -> "interface"
    DataModel -> "data_model"
    Auth -> "auth"

-- | As the log spells it.
planName :: PlanCall -> Text
planName = \case
    ChildConfirms -> "child_confirms"
    ParentDecided -> "parent_decided"

headData :: Sha -> Series
headData sha = "head_sha" .= shaText sha

urlData :: Url -> Series
urlData url = "url" .= urlText url

draftData :: DraftPr -> Series
draftData draft =
    urlData draft.url
        <> "base" .= branchText draft.base
        <> "branch" .= branchText draft.branch

commitData :: Commit -> Series
commitData commit = headData commit.head <> "touches" .= map areaName (Set.toList commit.touches)

picksData :: Picks -> Series
picksData picks =
    "rows" .= map (\(Label label) -> label) (Set.toList picks.rows)
        <> pair "verdicts" (list verdictEncoding (Map.toList picks.verdicts))
  where
    verdictEncoding (Requirement requirement, judgement) =
        pairs ("requirement" .= requirement <> "outcome" .= judgementName judgement)

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
            <> planData task.plan
            <> maybe mempty (("repo" .=) . repoText) task.repo
            <> maybe mempty (("worktree" .=) . shellPathText) task.worktree
            <> flowData task.flow

-- | The default flow is omitted: @flow@ is an optional key.
flowData :: FlowName -> Series
flowData = maybe mempty ("flow" .=) . namedFlowText

planData :: PlanCall -> Series
planData plan = "plan" .= planName plan

-- | A union under @shape@: @{kind: own_pr}@ or @{kind: round_on, pr_url}@.
shapeData :: Shape -> Series
shapeData shape = pair "shape" . pairs $ case shape of
    OwnPr -> tag "own_pr"
    RoundOn url -> tag "round_on" <> "pr_url" .= urlText url

-- | One key, the target's kind, holding its url or branch.
targetData :: Target -> Series
targetData = \case
    OnPr url -> "pr" .= urlText url
    OnBranch branch -> "branch" .= branchText branch
    OnTicket url -> "ticket" .= urlText url

headOf :: Object -> Parser Sha
headOf obj = Sha <$> obj .: "head_sha"

urlOf :: Object -> Parser Url
urlOf obj = Url <$> obj .: "url"

draftOf :: Object -> Parser DraftPr
draftOf obj =
    DraftPr
        <$> urlOf obj
        <*> (Branch <$> obj .: "base")
        <*> (Branch <$> obj .: "branch")

commitOf :: Object -> Parser Commit
commitOf obj =
    Commit
        <$> headOf obj
        <*> ( Set.fromList
                <$> (obj .: "touches" >>= traverse (named "area" (parseByName areaName)))
            )

picksOf :: Object -> Parser Picks
picksOf obj =
    Picks
        <$> (obj .: "rows" >>= distinct "row" . map Label)
        <*> ( obj .: "verdicts"
                >>= traverse (withObject "verdict" verdictOf)
                >>= keyed "requirement"
            )
  where
    verdictOf verdict =
        (,) . Requirement
            <$> verdict .: "requirement"
            <*> (verdict .: "outcome" >>= named "outcome" (parseByName judgementName))

{- | A breakdown file: the JSON array of tasks @breakdown.done@ logs, each
task's shape and plan spelt as 'fileCallsOf' reads them.
-}
decodeBreakdown :: Text -> Either Text Tasks
decodeBreakdown = decodeWith (breakdownWith fileCallsOf)

-- | A task file for @task add@: one task, as a breakdown file spells each.
decodeTask :: Text -> Either Text Task
decodeTask = decodeWith (taskWith fileCallsOf)

decodeWith :: (Value -> Parser a) -> Text -> Either Text a
decodeWith parser raw = first Text.pack (eitherDecodeStrictText raw >>= parseEither parser)

-- | A breakdown as the log holds it.
breakdownOf :: Value -> Parser Tasks
breakdownOf = breakdownWith loggedCallsOf

breakdownWith :: (Object -> Parser (Shape, PlanCall)) -> Value -> Parser Tasks
breakdownWith calls value = do
    tasks <- parseJSON value >>= traverse (taskWith calls)
    case NonEmpty.nonEmpty tasks of
        Nothing -> fail "a breakdown has a task at least"
        Just some -> either (fail . Text.unpack . breakdownErrorText) pure (breakdown some)
  where
    breakdownErrorText = \case
        TaskTwice (TaskId task) -> "task " <> task <> " is named twice"
        DependsLater (TaskId task) (TaskId dep) -> "task " <> task <> " depends on " <> dep <> ", which is not an earlier task"

-- | A task as the log holds it.
taskOf :: Value -> Parser Task
taskOf = taskWith loggedCallsOf

taskWith :: (Object -> Parser (Shape, PlanCall)) -> Value -> Parser Task
taskWith calls = withObject "task" (taskFieldsOf calls)

{- | By name, as a field a later breakdown adds is one more line; an optional
one is omitted when absent. The log and a task file spell the task's shape
and plan apart: @calls@ reads them.
-}
taskFieldsOf :: (Object -> Parser (Shape, PlanCall)) -> Object -> Parser Task
taskFieldsOf calls obj = do
    taskId <- TaskId <$> obj .: "id"
    deps <- map TaskId <$> obj .: "deps"
    base <- Branch <$> obj .: "base"
    branch <- Branch <$> obj .: "branch"
    fuel <- obj .: "fuel" >>= named "fuel" parseFuel
    qa <- obj .: "qa"
    heavy <- obj .: "heavy"
    security <-
        obj .: "security"
            >>= traverse (named "topic" (parseByName topicText))
            >>= distinct "topic"
    (shape, plan) <- calls obj
    repo <- obj .:? "repo" >>= traverse (named "repo" parseRepo)
    worktree <- obj .:? "worktree" >>= traverse worktreeOf
    flow <-
        fromMaybe defaultFlow
            <$> (obj .:? "flow" >>= traverse (named "flow" (parseByName flowText)))
    pure
        Task
            { id = taskId
            , deps
            , base
            , branch
            , fuel
            , qa
            , heavy
            , security
            , shape
            , plan
            , repo
            , worktree
            , flow
            }
  where
    worktreeOf path =
        maybe
            (fail ("a worktree is " <> shellPathRule <> ", not " <> show path))
            pure
            (shellPath path)

-- | A task's shape and plan as the log tags them, under @shape@ and @plan@.
loggedCallsOf :: Object -> Parser (Shape, PlanCall)
loggedCallsOf obj = (,) <$> shapeOf obj <*> planOf obj

{- | A task's shape and plan as a task file spells them: a round's PR under
@pr@, a decided plan as @planDecided: true@, each left out otherwise.
-}
fileCallsOf :: Object -> Parser (Shape, PlanCall)
fileCallsOf obj = do
    pr <- obj .:? "pr"
    decided <- obj .:? "planDecided"
    pure
        ( maybe OwnPr (RoundOn . Url) pr
        , bool ChildConfirms ParentDecided (fromMaybe False decided)
        )

shapeOf :: Object -> Parser Shape
shapeOf obj =
    obj .: "shape" >>= tagged "shape" caseOf
  where
    caseOf shape = \case
        "own_pr" -> pure OwnPr
        "round_on" -> RoundOn . Url <$> shape .: "pr_url"
        other -> unknownCase "shape" other

targetOf :: Object -> Parser Target
targetOf obj =
    OnPr . Url <$> obj .: "pr"
        <|> OnBranch . Branch <$> obj .: "branch"
        <|> OnTicket . Url <$> obj .: "ticket"

planOf :: Object -> Parser PlanCall
planOf obj = obj .: "plan" >>= named "plan" (parseByName planName)

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
named what parse raw = maybe (unknownCase what raw) pure (parse raw)

-- | The refusal of a word, or a union's @kind@, that names no case.
unknownCase :: String -> Text -> Parser a
unknownCase what raw = fail ("unknown " <> what <> " " <> show raw)

-- | A union's tag, RFC 8927's discriminator: the one key named @kind@.
tag :: Text -> Series
tag = ("kind" .=)

-- | The case of a union by its @kind@: each case reads the object's other keys.
tagged :: String -> (Object -> Text -> Parser a) -> Value -> Parser a
tagged what caseOf = withObject what (\obj -> obj .: "kind" >>= caseOf obj)
