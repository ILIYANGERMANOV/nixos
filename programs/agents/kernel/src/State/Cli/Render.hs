{- | The blocks the skills paste rather than restate (#360, "Rendered and
checked in"): each is whole lines ending in a newline, so a test can hold a
file region equal to it. Each reads the knowledge it shows from the one place
that owns it - the graph, the step table, 'cfg', 'authority' - so the skill
text cannot drift from what the kernel does.
-}
module State.Cli.Render (
    states,
    fuel,
    kinds,
    stopRule,
    planWrong,
) where

import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import State.Category.Fuel (Cfg (..), Fuel (..), PerFuel, SkipWhen (..), atFuel, cfg)
import State.Category.Graph (Arrow (..), Edge (..), LoopAt (..), Node (..), OpenGraph (..), Place (..), places)
import State.Category.Step (EventName (..), OutcomeName (..), SomeStep (..), StateName, StepSet (stepName), stateNameText)
import State.Flow.Library (fixLoop, gatherLoop)
import State.Role (FlowName (..), RoleDef (..), Rung (..), role, roleText)
import State.Run.Ask (Cond (..), Kind, Rule (..), authority, kindName)
import State.Run.Codec (areaText)
import State.Show (tshow)
import State.Step.Build (Sing (Refactor))
import State.Step.Catalog (AnyStep (..), stepNamed)
import State.Table (Row (runner), Runner (..), Steps, row)

{- | The flow's states in the term's order: who runs each, and where each of
its outcomes goes. A skip is an arrow like any other: 'fuel' says when a
level takes it.
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

{- | The engineer's rows of the Fuel table: the steps a level lets the agent
skip or repeats, read off the flow's graph, which carries its term's
budgets, and 'cfg', with each level's depth prose after it. A step the flow
draws as optional ('Skip' arrow) is skippable by its state's name. A loop
round after the first is a re-run: a re-review, a research round.
-}
fuel :: OpenGraph -> Text
fuel g =
    rows
        [ "Research rounds after the first" : map (\level -> "up to " <> tshow (reRuns level gatherLoop)) levels
        , "Interview questions" : map (\level -> "up to " <> tshow (cfg level).asks) levels
        , "Skippable when trivial" : map skippable levels
        , "Refactor" : map (\level -> refactor (skipAt level (stepName Refactor)) <> refactorDepth level) levels
        , "Re-reviews" : map (\level -> "up to " <> tshow (reRuns level fixLoop) <> reReviewDepth level) levels
        , "Full review of a fix to" : map (areasText . (.areas) . cfg) levels
        ]
  where
    levels = [minBound .. maxBound]
    reRuns level loop = maybe 0 (pred . atFuel level . (.rounds)) (Map.lookup loop g.loops)
    -- An 'Opt' draws as a skip arrow out of its first state.
    optSteps :: [(StateName, PerFuel SkipWhen)]
    optSteps = nub [(from.name, skips) | ((from, _), Edge {arrow = Skip _ skips}) <- Map.toList g.edges]
    skippable level = case ["`" <> stateNameText name <> "`" | (name, skips) <- optSteps, atFuel level skips == Skippable] of
        [] -> "none"
        names -> Text.intercalate ", " names
    skipAt level step = maybe Never (atFuel level) (lookup step optSteps)
    refactor = \case
        Never -> "always"
        AtOrBelow most -> "above about " <> tshow most <> " changed lines"
        Skippable -> "unless trivial"
    areasText areas = Text.intercalate ", " [Text.replace "-" " " (areaText area) | area <- [minBound .. maxBound], Set.member area areas]

-- | How deep a refactor goes, beyond whether it runs.
refactorDepth :: Fuel -> Text
refactorDepth = \case
    Low -> ", quick: items 1-3, no `tests.md`"
    Balanced -> ""
    Max -> ""

-- | What a re-review fixes, beyond how many run.
reReviewDepth :: Fuel -> Text
reReviewDepth = \case
    Low -> ", blockers and Not met fixed only"
    Balanced -> ""
    Max -> ""

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

-- | A Markdown table: the header, its rule, then a line per row.
table :: [Text] -> [[Text]] -> Text
table header body = Text.unlines [line header, "|" <> Text.intercalate "|" (map (const "---") header) <> "|"] <> rows body

rows :: [[Text]] -> Text
rows = Text.unlines . map line

line :: [Text] -> Text
line cells = "| " <> Text.intercalate " | " cells <> " |"
