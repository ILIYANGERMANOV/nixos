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

import Data.List (nub, sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import State.Category.Fuel (Cfg (..), Fuel (..), PerFuel, SkipWhen (..), atFuel, cfg)
import State.Category.Graph (Arrow (..), Cap (..), Edge (..), Node (..), OpenGraph (..), Place (..), eventLabel, placeName, places, shownOrder)
import State.Category.Meter (Limit (..), SomeMeter (..), someMeterName)
import State.Category.Step (SomeStep (..), StateName, StepSet (stepName), stateNameText)
import State.Role (FlowName (..), RoleDef (..), Rung (..), role, roleText)
import State.Run.Ask (Cond (..), Kind, Rule (..), authority, kindName)
import State.Run.Codec (areaText)
import State.Show (tshow)
import State.Step.Build (Sing (Refactor))
import State.Step.Catalog (AnyStep (..), shownEdges, stepNamed)
import State.Step.Choice (choiceNamed)
import State.Step.Gather (Sing (Research))
import State.Step.Review (Sing (Pick))
import State.Table (Row (runner), Runner (..), Steps, row)

{- | The flow's states in the term's order: who runs each, and where each of
its outcomes goes. A skip is an arrow like any other: 'fuel' says when a
level takes it.
-}
states :: OpenGraph -> Steps -> Text
states g steps =
    table
        ["State", "Run by", "Arrows out"]
        [[stateNameText (placeName place), runBy place.name, arrowsOut place] | place <- Set.toList (places g)]
  where
    runBy name = case (stepNamed name, choiceNamed name) of
        (Just (AnyStep _ (SomeStep s)), _) -> case (row steps s).runner of
            Agent agent _ -> roleText agent
            Inline -> "you"
        (Nothing, Just _) -> "you"
        (Nothing, Nothing) -> "fan-out"
    arrowsOut place =
        Text.intercalate "; " [eventLabel place event <> ": " <> target edge.to | (event, edge) <- shownEdges g place]
    target = \case
        At place -> stateNameText (placeName place)
        Out -> "end"
        Exit -> "exit"

{- | The engineer's rows of the Fuel table: the meters a level caps
differently, the steps it lets the agent skip, read off the flow's graph,
which carries its term's budgets, and 'cfg', with each level's depth prose
after it. A meter is a row by its name, in the flow's order, a choice's
actions in the order the term declares them. One
capped alike at every level is no row. A step the flow draws as optional
('Skip' arrow) is skippable by its state's name.
-}
fuel :: OpenGraph -> Text
fuel g =
    rows $
        [someMeterName cap.meter : map (\level -> meterCell cap.meter level (atFuel level cap.limit)) levels | (_, cap) <- sortOn (uncurry shownOrder) (Map.toList g.caps), varies cap.limit]
            <> [ "Skippable when trivial" : map skippable levels
               , "Refactor" : map (\level -> refactor (skipAt level (stepName Refactor)) <> refactorDepth level) levels
               , "Full review of a fix to" : map (areasText . (.areas) . cfg) levels
               ]
  where
    levels = [minBound .. maxBound]
    varies limit = nub (map (`atFuel` limit) levels) /= [atFuel Low limit]
    -- An 'Opt' draws as a skip arrow out of its first state.
    optSteps :: [(StateName, PerFuel SkipWhen)]
    optSteps = nub [(placeName from, skips) | ((from, _), Edge {arrow = Skip _ skips}) <- Map.toList g.edges]
    skippable level = case ["`" <> stateNameText name <> "`" | (name, skips) <- optSteps, atFuel level skips == Skippable] of
        [] -> "none"
        names -> Text.intercalate ", " names
    skipAt level step = maybe Never (atFuel level) (lookup step optSteps)
    refactor = \case
        Never -> "always"
        AtOrBelow most -> "above about " <> tshow most <> " changed lines"
        Skippable -> "unless trivial"
    areasText areas = Text.intercalate ", " [Text.replace "-" " " (areaText area) | area <- [minBound .. maxBound], Set.member area areas]

{- | A meter's cell: what the level allows, and for researchers and
re-reviews how deep each goes.
-}
meterCell :: SomeMeter -> Fuel -> Limit -> Text
meterCell meter level limit
    | meter == SomeMeter Research = researchers limit <> researchDepth level
    | meter == SomeMeter Pick = upTo limit <> reReviewDepth level
    | otherwise = upTo limit
  where
    researchers = \case
        UpTo 1 -> "1 for all"
        other -> upTo other
    upTo = \case
        UpTo most -> "up to " <> tshow most
        PerGroup -> "one per group"

-- | How far each researcher goes, beyond how many run.
researchDepth :: Fuel -> Text
researchDepth = \case
    Low -> ", 8 calls, notes past the hand-back limit"
    Balanced -> ", 15 calls, notes"
    Max -> ", 30 calls, notes, top 5 facts re-checked"

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
