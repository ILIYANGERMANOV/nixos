{- | The blocks the skills paste rather than restate (#360, "Rendered and
checked in"): each is whole lines ending in a newline, so a test can hold a
file region equal to it. Each reads the knowledge it shows from the one place
that owns it - the graph, the step table, 'cfg', 'authority' - so the skill
text cannot drift from what the kernel does.
-}
module State.Cli.Render (
    states,
    quality,
    trivialSkips,
    kinds,
    stopRule,
    planWrong,
) where

import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import State.Category.Flow (FanId (..), OptId (..))
import State.Category.Graph (Arrow (..), Edge (..), Node (..), OpenGraph (..), Place (..), places)
import State.Category.Mode (Cfg (..), Mode (..), Quality (..), Size (..), SkipWhen (..), cfg, qualityName, reReviews)
import State.Category.Step (EventName (..), OutcomeName (..), SomeStep (..), stateNameText)
import State.Role (FlowName (..), RoleDef (..), Rung (..), role, roleText)
import State.Run.Ask (Cond (..), Kind, Rule (..), authority, kindName)
import State.Run.Codec (areaText)
import State.Show (tshow)
import State.Step.Catalog (AnyStep (..), stepNamed)
import State.Table (Row (runner), Runner (..), Steps, row)

{- | The flow's states in the term's order: who runs each, and where each of
its outcomes goes. A skip is an arrow like any other: 'quality' and
'trivialSkips' say when a mode takes it.
-}
states :: OpenGraph -> Steps -> Text
states g steps =
    table
        ["State", "Run by", "Arrows out"]
        [[stateNameText place.name, runBy place.name, arrowsOut place] | place <- Set.toList (places g)]
  where
    runBy name = case stepNamed name of
        Just (AnyStep _ (SomeStep s)) -> case (row steps s).runner of
            Agent agent _ -> roleText agent
            Inline -> "you"
        Nothing -> "fan-out"
    arrowsOut place =
        Text.intercalate "; " [outcomeText event <> ": " <> target edge.to | ((from, event), edge) <- Map.toList g.edges, from == place]
    outcomeText (EventName _ (OutcomeName outcome)) = outcome
    target = \case
        At place -> stateNameText place.name
        Out -> "end"
        Exit -> "exit"

{- | The engineer's rows of the Quality table in @quality.md@, at 'Normal'
size: the steps a mode skips or repeats, from 'cfg', with each Quality's
depth prose after it.
-}
quality :: Text
quality =
    rows
        [ "Refactor" : map (\q -> refactor (normal q) <> refactorDepth q) qualities
        , "Re-reviews" : map (\q -> "up to " <> tshow (reReviews q Normal) <> reReviewDepth q) qualities
        , "Full review of a fix to" : map (areasText . (.areas) . normal) qualities
        ]
  where
    normal q = cfg (Mode q Normal)
    refactor c = case c.skip ORefactor of
        Never -> "always"
        AtOrBelow most -> "above about " <> tshow most <> " changed lines"
        Always -> "never"
    areasText areas = Text.intercalate ", " [Text.replace "-" " " (areaText area) | area <- [minBound .. maxBound], Set.member area areas]

-- | How deep a refactor goes, beyond whether it runs.
refactorDepth :: Quality -> Text
refactorDepth = \case
    Poc -> ", quick: items 1-3, no `tests.md`"
    Balanced -> ""
    Max -> ""

-- | What a re-review fixes, beyond how many run.
reReviewDepth :: Quality -> Text
reReviewDepth = \case
    Poc -> ", blockers and Not met fixed only"
    Balanced -> ""
    Max -> ""

{- | What @Size: Trivial@ changes, as a list: each optional step of the flow,
in its order, then the review rounds and researchers. A value the same at
every Quality is written once.
-}
trivialSkips :: OpenGraph -> Text
trivialSkips g =
    Text.unlines $
        ["- `" <> stateNameText name <> "`: " <> byQuality (\q -> skipText ((cfg (Mode q Trivial)).skip optId)) | (optId, name) <- optSteps]
            <> [ "- re-reviews: " <> byQuality (\q -> tshow (reReviews q Trivial))
               , "- researchers: " <> byQuality (\q -> tshow ((cfg (Mode q Trivial)).fan FResearchers))
               ]
  where
    -- An 'Opt' draws as a skip arrow out of its first state.
    optSteps = nub [(optId, from.name) | ((from, _), Edge {arrow = Skip optId}) <- Map.toList g.edges]
    skipText = \case
        Never -> "never skipped"
        AtOrBelow most -> "skipped at or below " <> tshow most <> " changed lines"
        Always -> "skipped"
    byQuality cell = case nub (map cell qualities) of
        [same] -> same
        _ -> Text.intercalate ", " [qualityName q <> " " <> cell q | q <- qualities]

-- | Who answers each kind of question: 'authority', row for row.
kinds :: Text
kinds =
    table
        ("Kind" : map rungText rungs)
        [kindName kind : map (ruleText . (`authority` kind)) rungs | kind <- [minBound .. maxBound :: Kind]]
  where
    rungs = [minBound .. maxBound]
    ruleText = \case
        Answers -> "answers"
        AnswersIf cond -> "answers if " <> condText cond
        Forwards -> "forwards"
        NeverAsked -> "never asked"
    -- A lead's and the orchestrator's column is headed by the role on that rung.
    rungText = \case
        Worker -> "worker"
        Lead -> roleText (role EngineerFlow).name
        Orchestrator -> roleText (role TenXFlow).name
        User -> "user"
    condText = \case
        RuleTest -> "it passes the rule test"
        FitsBreakdown -> "the task plan fits the confirmed breakdown"
        ObviousOrAnswered -> "the user already answered it, or it is obvious"
        OneRetry -> "no retry was spent on it yet"
        TrivialSize -> "the task is `Size: Trivial`"

-- | The paragraph every implementer, refactorer and fixer brief carries.
stopRule :: Text
stopRule =
    Text.unlines
        [ "> A question that blocks your work and that the repo, this brief and the plan"
        , "> do not settle, or choosing differently from a decision the plan states:"
        , "> stop at once. Commit and push the work you have, if any, as a"
        , "> normal commit with no WIP marker and `Remaining: <what is left>` in its"
        , "> body, plus `(does not build yet)` when it does not build."
        , "> Start your hand-back with `NEEDS_DECISION <question>`, then that commit, what"
        , "> you tried and the evidence paths. Spawn no researcher."
        , "> On `Size: Trivial`, work bigger than briefed is `GREW <why>`: stop the same"
        , "> way, after committing and pushing what you have, and start your hand-back"
        , "> with that line. With a `NEEDS_DECISION`, that line comes first and `GREW`"
        , "> on the next."
        ]

-- | The line a review-lead brief carries instead of 'stopRule'.
planWrong :: Text
planWrong =
    Text.unlines
        [ "> The plan is wrong when a finding shows a wrong approach, a requirement that"
        , "> cannot be met, scope the plan does not hold, or a data-model or auth"
        , "> redesign. Do not stop early: finish the review, then make"
        , "> `NEEDS_DECISION plan wrong: <finding>` the first line of your return, before"
        , "> the usual report. Every other finding, security included, goes in the table"
        , "> as usual."
        ]

qualities :: [Quality]
qualities = [minBound .. maxBound]

-- | A Markdown table: the header, its rule, then a line per row.
table :: [Text] -> [[Text]] -> Text
table header body = Text.unlines [line header, "|" <> Text.intercalate "|" (map (const "---") header) <> "|"] <> rows body

rows :: [[Text]] -> Text
rows = Text.unlines . map line

line :: [Text] -> Text
line cells = "| " <> Text.intercalate " | " cells <> " |"
