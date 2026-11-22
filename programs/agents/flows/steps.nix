# The step table of #351's flows (#360 "Step table schema"): plain data, one
# row per step of the kernel's `State.Category.Step`. A step's types and
# outcomes are the kernel's alone: a row holds only what the kernel lacks.
# The runner is a sum, checked by flows/default.nix:
#   { runner = "inline"; task; }        the lead runs the step itself
#   { runner = "<role>"; lead; task; }  a subagent of that role runs it
# `task` is what the runner executes: `state next` prints it, after `lead`,
# the lead's part, for a subagent's step; `state brief` prints it alone.
#
# The profile (#351 section 8) every role's record is derived from
# (lib/derive.nix): `tools` the step uses, as role capabilities (`delegate`
# comes from a `spawn:` op); `skills` its runner preloads; `prose` the
# instruction fragments it reads, by name (programs/agents/default.nix);
# `ops` what it may call: `ask`, `await`, `notify`, `spawn:<role>`. `flows`
# names the flows the step is in, `engineer`, `10x`, `architect` or `chief`. A role leads the flow
# named after it (the kernel's `State.Role`), so the `engineer` flow's inline rows are the engineer
# role's. `offFlow` is a `role`'s work outside the flows: the
# kernel never sees it, and only the derivation reads it.
let
  # The engineering instructions, and the Fuel table and its run rules the
  # lead reads at every step it decides to run or skip.
  leadProse = engProse ++ [ "topics/fuel-lead.md" ];

  # The engineering instructions and the Fuel table, without its run rules: a
  # role that varies by Fuel but runs no flow.
  engProse = [
    "topics/engineering.md"
    "topics/fuel.md"
  ];

  # A code-writing role's prose: building.md points at the engineering
  # instructions, so the two travel together.
  buildingProse = [
    "shared/building.md"
    "topics/engineering.md"
  ];

  # The findings every refine pass hands back, one table the lead applies to
  # the plan. GFM splits a row on a bare pipe, hence the escape.
  findingFormat = "Hand back one table, `| Concern | Finding | Change | Source | Confidence |`: Source a `path:line`, or a standard's id, section and URL; Confidence high when read in the source, medium from a partial or secondary source, low when inferred. Escape a pipe inside a cell as `\\|`. No row: say \"nothing to change, because ...\".";

  # The 10x's steps around its engineers' fan-out.
  fanSteps = {
    breakdown = {
      runner = "inline";
      task = "Break the confirmed plan into tasks.";
      tools = [
        "read"
        "edit"
        "shell"
      ];
      skills = [ "10x-engineer" ];
      prose = leadProse;
      ops = [ ];
      flows = [ "10x" ];
    };
    merge = {
      runner = "inline";
      task = "Merge: the review queue, the merge loop and the final audit, or a next round, as the 10x skill's Merge says.";
      tools = [ "shell" ];
      skills = [ "10x-engineer" ];
      prose = [ ];
      ops = [
        "await"
        "notify"
      ];
      flows = [ "10x" ];
    };
  };

  # The architect's steps: the design discussion's questions and the ticket
  # it writes or edits at any point, each run by the lead, who changes no
  # code.
  architectSteps = {
    discuss = {
      runner = "inline";
      task = "Discuss: this round's design questions one at a time, each through `state ask` and answered before the next, never two at once. First send the Explain message: the context, and pseudo-code or a diagram; then the question as text, your recommendation first, in the same turn, for each question. Once the round's last question is answered, record `discuss.asked`, back to the discussion's pick. There `research` spawns a researcher for any fact an answer opens, and `enough`, when nothing is open, waits for every researcher's hand-back. At either Fuel budget's end, asked whether to go on: yes is `extend <why>`, no is `enough`.";
      tools = [
        "read"
        "web"
      ];
      skills = [ "architect" ];
      prose = leadProse;
      ops = [ "ask" ];
      flows = [ "architect" ];
    };
    ticket = {
      runner = "inline";
      task = "Ticket: write the design so far into the ticket, or edit it, at any point and as often as the design changes: the skill's `references/issue.md` sections from a quoted heredoc (`<<'EOF'`), into the ticket the request named (`gh issue edit <number> --repo <owner>/<repo> --body-file -`), else a new one (`gh issue create --repo <owner>/<repo>`), or a Linear issue when the request names Linear; `gh issue comment` adds to it. Then record `ticket.written <url>`, back to the discussion's pick. The ticket is optional: `enough` ends the run with or without one.";
      tools = [ "shell" ];
      skills = [ "architect" ];
      prose = leadProse;
      ops = [ ];
      flows = [ "architect" ];
    };
  };

  # The chief's steps around a request: the inputs a block opens, a request
  # no flow fits, and the next request. The lead runs each.
  chiefSteps =
    let
      chiefStep =
        step:
        {
          runner = "inline";
          tools = [ "shell" ];
          skills = [ "chief" ];
          prose = leadProse;
          ops = [ ];
          flows = [ "chief" ];
        }
        // step;
    in
    {
      # Every role's root and each chief request: Fuel is an input, recorded as given.
      fuel = chiefStep {
        task = "Fuel: record the Fuel given: your brief's, parent's or request's `Fuel:` line, or the level the request asks for as the Fuel table says.";
        skills = [ ];
        flows = [
          "engineer"
          "10x"
          "architect"
          "chief"
        ];
      };
      open_plan = chiefStep {
        task = "Open: the issue the request names holds the plan to build. Read it with `gh issue view <url>` and record its url; the block builds what its plan says.";
      };
      open_branch = chiefStep {
        task = "Open: the branch or sha the request names is what the block works on. Fetch it and check it out: when `git worktree list` shows a worktree holding the branch, `state move <that worktree>` and work there instead. Record it.";
      };
      open_pr = chiefStep {
        task = "Open: the PR the request names is what the block works on. Check out its branch (`gh pr checkout <url>`): when `git worktree list` shows a worktree holding it, `state move <that worktree>` and work there instead. Record its url.";
      };
      direct = chiefStep {
        task = "Direct: no flow fits the request, so do it yourself, the hooks and the context guard as everywhere; you may commit and open PRs. Record one line: what was asked and what you did.";
      };
      next = chiefStep {
        tools = [ ];
        ops = [ "ask" ];
        task = "Next: tell the user in one line what the request ended in, the last result below, then ask for the next request or whether they are done, and end the turn. `request` when they name one, carrying that result as its context; `done` when they are done. At the Fuel's cap, asked whether to go on: yes is `extend <why>`, no is `done`.";
      };
    };
in
{
  steps = {
    research = {
      runner = "researcher";
      lead = "Gather: spawn a researcher per open fact group, in the background or not as its option says, each prompted per the researcher skill's `## Callers`; the hooks record each spawn and hand-back. Each researcher's task:";
      task = "Research the open fact group your prompt names, as the researcher skill says.";
      tools = [
        "read"
        "shell"
        "web"
      ];
      skills = [ "researcher" ];
      prose = engProse;
      ops = [ ];
      flows = [
        "engineer"
        "10x"
        "architect"
      ];
    };
    interview = {
      runner = "inline";
      task = "Gather: the `grilling` interview, one question at a time, each through `state ask`; once this round's are answered, `interview.asked` takes you back to the gather. There `gather.research` spawns a researcher for any fact an answer opens, and `gather.enough`, when nothing is open, waits for every researcher's hand-back. At either Fuel budget's end, asked whether to go on: yes is `extend <why>`, no is `gather.enough`.";
      # `skill` invokes grilling, which the engineer does not preload; `web`
      # reads a link or doc an answer points to.
      tools = [
        "read"
        "web"
        "skill"
      ];
      skills = [ "engineer" ];
      prose = leadProse;
      ops = [ "ask" ];
      flows = [
        "engineer"
        "10x"
      ];
    };
    notes = {
      runner = "inline";
      task = "Notes: merge every researcher's hand-back into your notes, each fact once, then record `notes.done`.";
      tools = [ "read" ];
      skills = [ ];
      prose = leadProse;
      ops = [ ];
      flows = [
        "engineer"
        "10x"
        "architect"
      ];
    };
    plan = {
      runner = "inline";
      task = "Propose: write the plan in the notes directory, as the skill's Propose block says.";
      tools = [
        "read"
        "edit"
      ];
      skills = [ "engineer" ];
      prose = leadProse;
      ops = [ ];
      flows = [
        "engineer"
        "10x"
      ];
    };
    simplify_plan = {
      runner = "researcher";
      lead = "Propose: one researcher, naming the plan, the research notes paths and the notes directory. An adjust that changed the approach reruns every refine pass; any other adjust reruns none: record each pass's `.done` on the earlier findings.";
      task = "Run the researcher skill's `references/proposal.md` `## Simplify` on the plan your prompt names. ${findingFormat}";
      tools = [
        "read"
        "shell"
        "web"
      ];
      skills = [ "researcher" ];
      prose = engProse;
      ops = [ ];
      flows = [
        "engineer"
        "10x"
      ];
    };
    standards_plan = {
      runner = "researcher";
      lead = "Propose: one researcher, naming the plan, the research notes paths and the notes directory.";
      task = "Run the researcher skill's `references/proposal.md` `## Standards` on the plan your prompt names. ${findingFormat}";
      tools = [
        "read"
        "shell"
        "web"
      ];
      skills = [ "researcher" ];
      prose = engProse;
      ops = [ ];
      flows = [
        "engineer"
        "10x"
      ];
    };
    align_plan = {
      runner = "reviewer";
      lead = "Propose: one reviewer, naming the plan and the notes directory.";
      task = "Check the plan your prompt names against the engineering instructions in your context: each place it breaks one. Write the table to `<notes>/refine-align.md`, `<notes>` the directory your prompt names. ${findingFormat}";
      tools = [
        "read"
        "shell"
      ];
      skills = [ ];
      prose = engProse;
      ops = [ ];
      flows = [
        "engineer"
        "10x"
      ];
    };
    present = {
      runner = "inline";
      task = "Propose: compose the full plan message as `engineer/references/present.md` says, in `<notes>/present.md`. Ask nothing: `confirm` asks.";
      tools = [ "read" ];
      skills = [ "engineer" ];
      prose = leadProse;
      ops = [ ];
      flows = [
        "engineer"
        "10x"
      ];
    };
    confirm = {
      runner = "inline";
      task = "Propose: one message, `<notes>/present.md` then one Confirm question as its final text. `confirmed` builds it; `adjusted` gathers again.";
      tools = [ ];
      skills = [ "engineer" ];
      prose = leadProse;
      ops = [ "ask" ];
      flows = [
        "engineer"
        "10x"
      ];
    };
    draft = {
      runner = "inline";
      task = "Build: branch from origin/<base>, or keep the worktree's task branch; an empty commit `Draft: <task> (plan only)`, push, and the draft PR against <base> (`gh pr create --draft --base <base>`) with the plan as its body.";
      tools = [ "shell" ];
      skills = [ "engineer" ];
      prose = leadProse;
      ops = [ ];
      flows = [ "engineer" ];
    };
    implement = {
      runner = "implementer";
      lead = "Build: implementers, one per slice, one after another, in parallel only when independent; brief each with `state brief implementer` plus its slice.";
      task = "Build the slice your prompt names, as the plan says.";
      tools = [
        "read"
        "edit"
        "shell"
      ];
      skills = [ ];
      prose = buildingProse;
      ops = [ ];
      flows = [ "engineer" ];
    };
    refactor = {
      runner = "refactorer";
      lead = "Build: one refactorer, briefed with `state brief refactorer`.";
      task = "Refactor the branch's diff; hand back each bigger proposal as a Scope question.";
      tools = [
        "read"
        "edit"
        "shell"
      ];
      skills = [ "refactor" ];
      prose = buildingProse ++ [ "topics/fuel.md" ];
      ops = [ ];
      flows = [ "engineer" ];
    };
    review = {
      runner = "review-lead";
      lead = "Review: one review-lead, briefed with `state brief review-lead`.";
      task = "Run `pragmatic-review` on the branch against the requirements file.";
      # Its Low sweep reads the Fuel table; it spawns the `reviewer`s.
      tools = [
        "read"
        "shell"
      ];
      skills = [ "pragmatic-review" ];
      prose = engProse;
      ops = [ "spawn:reviewer" ];
      flows = [ "engineer" ];
    };
    pick = {
      runner = "inline";
      task = "Review: pick the rows to fix and judge each requirement, as `references/review.md` says. `final` goes on to describe, where the final fixer gets the chosen rows; `loop` sends them to a fixer, then a re-review, and spends one Re-review. An Unverified requirement is a verdict (`--verdict <req>=unverified`), never a row: with no surviving Major and no Not met, `final` with no `--row`.";
      tools = [ "read" ];
      skills = [ "engineer" ];
      prose = leadProse;
      ops = [ "ask" ];
      flows = [ "engineer" ];
    };
    fix = {
      runner = "fixer";
      lead = "Review: one fixer for the picked rows, briefed with `state brief fixer`.";
      task = "Fix the picked rows your prompt names.";
      tools = [
        "read"
        "edit"
        "shell"
      ];
      skills = [ ];
      prose = buildingProse;
      ops = [ ];
      flows = [ "engineer" ];
    };
    re_review = {
      runner = "review-lead";
      lead = "Review: one review-lead for the fix, briefed with `state brief review-lead`.";
      task = "Run `pragmatic-review` with `--fixes <sha>`, the last review's head, on the fix against the requirements file; a fix that touches what your Fuel row's Full review of a fix to names gets the whole branch.";
      # Its Low sweep reads the Fuel table; it spawns the `reviewer`s.
      tools = [
        "read"
        "shell"
      ];
      skills = [ "pragmatic-review" ];
      prose = engProse;
      ops = [ "spawn:reviewer" ];
      flows = [ "engineer" ];
    };
    describe = {
      runner = "fixer";
      lead = "Describe: the final fixer, briefed with `state brief fixer`.";
      task = "Fix row R0, writing the PR body's full facts as `pr-description` says, and any picked rows your prompt names; nothing reviews your fix.";
      tools = [
        "read"
        "edit"
        "shell"
      ];
      skills = [ ];
      prose = buildingProse;
      ops = [ ];
      flows = [ "engineer" ];
    };
    simplify_pr = {
      runner = "fixer";
      lead = "Describe: a fixer on row S0, briefed with `state brief fixer`.";
      task = "Row S0: `pr-description`'s Simplify; your hand-back ends `Simplified: <head sha>`.";
      tools = [
        "read"
        "edit"
        "shell"
      ];
      skills = [ ];
      prose = buildingProse;
      ops = [ ];
      flows = [ "engineer" ];
    };
    await_ci = {
      runner = "inline";
      task = "Ship: CI on the PR. `green` when every check passes; `red` names the failing checks.";
      tools = [ "shell" ];
      skills = [ "engineer" ];
      prose = leadProse;
      ops = [ "await" ];
      flows = [ "engineer" ];
    };
    fix_pr = {
      runner = "fixer";
      lead = "Ship: one fixer on the failing checks, as `references/review.md`'s CI fix says, briefed with `state brief fixer`.";
      task = "Fix the failing checks your prompt names.";
      tools = [
        "read"
        "edit"
        "shell"
      ];
      skills = [ ];
      prose = buildingProse;
      ops = [ ];
      flows = [ "engineer" ];
    };
    ready = {
      runner = "inline";
      task = "Ship: the skill's gates, then mark the PR ready.";
      tools = [ "shell" ];
      skills = [ "engineer" ];
      prose = leadProse;
      ops = [
        "notify"
        "spawn:checker"
      ];
      flows = [ "engineer" ];
    };
  }
  // fanSteps
  // architectSteps
  // chiefSteps;

  # Role work outside the flows: only lib/derive.nix reads it.
  offFlow = {
    # The full check, inside `ready` and wherever lead.md's Checks send it.
    full_check = {
      role = "checker";
      tools = [
        "read"
        "shell"
      ];
      skills = [ ];
      prose = [ ];
      ops = [ ];
    };
    # A review agent under a review-lead, a review brief, a skill dry run, QA
    # evidence or the 10x audit.
    inspect = {
      role = "reviewer";
      tools = [
        "read"
        "shell"
      ];
      skills = [ ];
      prose = engProse;
      ops = [ ];
    };
    # The /qa skill's executor.
    qa_run = {
      role = "qa-runner";
      tools = [
        "read"
        "edit"
        "shell"
        "web"
      ];
      skills = [ ];
      prose = [ "topics/engineering.md" ];
      ops = [ ];
    };
  };
}
