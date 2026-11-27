{- | The run's epics: a long branch its tasks build on, whose own PR merges
last (#552's Appendix B, "Epics"). An epic is opened, then ready for review
once its final PR opens, then merged; there is no back edge until a run
needs one. Each edge is a typed function ('ready', 'merge'), so the fold
cannot take an edge the table lacks: every other move is refused.
-}
module State.Run.Epic (
    Epic (..),
    OpenEpic (..),
    ReadyEpic (..),
    MergedEpic (..),
    EpicMove (..),
    Refusal (..),
    ready,
    merge,
    moved,
    opened,
    stageName,
    epicRepo,
    epicBranch,
    epicPr,
) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import State.Step.Artifact (Base (..), Branch, EpicName, Repo, Url)

-- | An epic by where it stands, each stage with what it knows.
data Epic = Open OpenEpic | Ready ReadyEpic | Merged MergedEpic
    deriving stock (Eq, Show)

-- | Opened on its branch of the repo: its tasks build on the branch.
data OpenEpic = OpenEpic {repo :: Repo, branch :: Branch}
    deriving stock (Eq, Show)

-- | Its final PR, of the branch into the default one, is open for review.
data ReadyEpic = ReadyEpic {repo :: Repo, branch :: Branch, pr :: Url}
    deriving stock (Eq, Show)

-- | Its final PR merged.
data MergedEpic = MergedEpic {repo :: Repo, branch :: Branch, pr :: Url}
    deriving stock (Eq, Show)

-- | The final PR opened: the epic is ready for review.
ready :: OpenEpic -> Url -> ReadyEpic
ready epic = ReadyEpic epic.repo epic.branch

merge :: ReadyEpic -> MergedEpic
merge epic = MergedEpic epic.repo epic.branch epic.pr

-- | What an epic's event does: open it on a branch, mark it ready with its PR, or merge it.
data EpicMove = Opens Repo Branch | Readies Url | Merges
    deriving stock (Eq, Show)

-- | Why a move is refused: each names the epic.
data Refusal
    = -- | The run opened an epic of this name already.
      EpicExists EpicName
    | -- | Only an open epic is made ready: it is ready or merged already.
      EpicNotOpen EpicName
    | -- | Only a ready epic merges: it is open still, or merged already.
      EpicNotReady EpicName
    | -- | The run never opened an epic of this name.
      UnknownEpic EpicName
    deriving stock (Eq, Show)

-- | The run's epics after the move, by name, or why the table refuses it.
moved ::
    EpicName -> EpicMove -> Map EpicName Epic -> Either Refusal (Map EpicName Epic)
moved name move epics = (\epic -> Map.insert name epic epics) <$> next
  where
    next = case (Map.lookup name epics, move) of
        (Nothing, Opens repo branch) -> Right (Open (OpenEpic repo branch))
        (Nothing, Readies _) -> Left (UnknownEpic name)
        (Nothing, Merges) -> Left (UnknownEpic name)
        (Just _, Opens _ _) -> Left (EpicExists name)
        (Just (Open epic), Readies pr) -> Right (Ready (ready epic pr))
        (Just (Ready _), Readies _) -> Left (EpicNotOpen name)
        (Just (Merged _), Readies _) -> Left (EpicNotOpen name)
        (Just (Open _), Merges) -> Left (EpicNotReady name)
        (Just (Ready epic), Merges) -> Right (Merged (merge epic))
        (Just (Merged _), Merges) -> Left (EpicNotReady name)

{- | A task's base names only an epic the run opened, at any stage: @state
epic open@ comes before the breakdown that uses it.
-}
opened :: Map EpicName Epic -> Base -> Either Refusal ()
opened epics = \case
    OnDefault -> Right ()
    OnTask _ -> Right ()
    OnEpic name
        | Map.member name epics -> Right ()
        | otherwise -> Left (UnknownEpic name)

-- | The stage as the log's projection and the resume packet spell it.
stageName :: Epic -> Text
stageName = \case
    Open _ -> "open"
    Ready _ -> "ready_for_review"
    Merged _ -> "merged"

epicRepo :: Epic -> Repo
epicRepo = \case
    Open epic -> epic.repo
    Ready epic -> epic.repo
    Merged epic -> epic.repo

epicBranch :: Epic -> Branch
epicBranch = \case
    Open epic -> epic.branch
    Ready epic -> epic.branch
    Merged epic -> epic.branch

-- | The epic's final PR, once it is ready.
epicPr :: Epic -> Maybe Url
epicPr = \case
    Open _ -> Nothing
    Ready epic -> Just epic.pr
    Merged epic -> Just epic.pr
