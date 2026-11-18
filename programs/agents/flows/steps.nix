# The step table of #351's flows (#360 "Step table schema"): plain data, one
# row per step of the kernel's `State.Category.Step`. `dom`, `cod` and `exit` are the
# step's types (`in` is a Nix keyword), `outcomes` its exit outcome first, then
# the continuing one; `skipped` is no outcome, a Fuel's skip appends it.
# The runner is a sum, checked by flows/default.nix:
#   { runner = "inline"; task; }        the lead runs the step itself
#   { runner = "<role>"; lead; task; }  a subagent of that role runs it
# `task` is what the runner executes: `state next` prints it, after `lead`,
# the lead's part, for a subagent's step; `state brief` prints it alone. The
# kernel's test holds the types and outcomes equal to `State.Category.Step`.
#
# The profile (#351 section 8) every role's record is derived from
# (lib/derive.nix): `tools` the step uses, as role capabilities (`delegate`
# comes from a `spawn:` op); `skills` its runner preloads; `prose` the
# instruction fragments it reads, by name (programs/agents/default.nix);
# `ops` what it may call: `ask`, `await`, `notify`, `spawn:<role>`. `flows`
# names the flows the step is in, `engineer`, `10x`, `architect` or `chief`. A role leads the flow
# named after it (the kernel's `State.Role`), so the `engineer` flow's inline rows are the engineer
# role's. `offFlow` is a `role`'s work outside the flows: it has no types,
# the kernel never sees it, and only the derivation reads it.
let
  # The lead's Fuel table, read at every step it decides to run or skip.
  leadProse = [ "topics/fuel.md" ];

  # The 10x's steps around its engineers' fan-out.
  fanSteps = {
    breakdown = {
      dom = "Plan";
      cod = "[Ctx]";
      exit = null;
      outcomes = [ "done" ];
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
      dom = "[PR]";
      cod = "Ctx";
      exit = "PR";
      outcomes = [
        "done"
        "next_round"
      ];
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
  # code. `problem` and `confirm_design` are the legacy architect's
  # (kernel State.Flow.Legacy), kept so old runs still replay and finish.
  architectSteps = {
    discuss = {
      dom = "Ctx";
      cod = "Ctx";
      exit = null;
      outcomes = [ "asked" ];
      runner = "inline";
      task = "Discuss: this round's design questions one at a time, each through `state ask` and answered before the next, never two at once. First send the Explain message: the context, and pseudo-code or a diagram; then the picker question, your recommendation first, in the same turn, for each question. Once the round's last question is answered, record `discuss.asked`, back to the discussion's pick. There `research` spawns a researcher for any fact an answer opens, and `enough`, when nothing is open, waits for every researcher's hand-back. At either Fuel budget's end, asked whether to go on: yes is `extend <why>`, no is `enough`.";
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
      dom = "Ctx";
      cod = "Ctx";
      exit = null;
      outcomes = [ "written" ];
      runner = "inline";
      task = "Ticket: write the design so far into the ticket, or edit it, at any point and as often as the design changes: the skill's `references/issue.md` sections from a quoted heredoc (`<<'EOF'`), into the ticket the request named (`gh issue edit <number> --repo <owner>/<repo> --body-file -`), else a new one (`gh issue create --repo <owner>/<repo>`), or a Linear issue when the request names Linear; `gh issue comment` adds to it. Then record `ticket.written <url>`, back to the discussion's pick. The ticket is optional: `enough` ends the run with or without one.";
      tools = [ "shell" ];
      skills = [ "architect" ];
      prose = leadProse;
      ops = [ ];
      flows = [ "architect" ];
    };
    problem = {
      dom = "Ctx";
      cod = "Ctx";
      exit = "Ctx";
      outcomes = [
        "understood"
        "more"
      ];
      runner = "inline";
      task = "Problem: talk the problem through with the user: what hurts, for whom, and why now. No ticket yet. A fact gap is `problem.more`, back to research.";
      tools = [
        "read"
        "web"
      ];
      skills = [ "architect" ];
      prose = leadProse;
      ops = [ "ask" ];
      flows = [ "architect" ];
    };
    confirm_design = {
      dom = "Ctx";
      cod = "Ctx";
      exit = "Ticket";
      outcomes = [
        "confirmed"
        "adjusted"
      ];
      runner = "inline";
      task = "Design: first send the agreed design as a summary: its decisions, and a diagram or pseudo-code; then, in the same turn, the one Confirm question. `adjusted` discusses again. Only once it is `confirmed`, write the ticket, once: the skill's `references/issue.md` sections from a quoted heredoc (`<<'EOF'`), into the ticket the request named (`gh issue edit <number> --repo <owner>/<repo> --body-file -`), else a new one (`gh issue create --repo <owner>/<repo>`), or a Linear issue when the request names Linear. Then record `confirm_design.confirmed <url>`.";
      tools = [ "shell" ];
      skills = [ "architect" ];
      prose = leadProse;
      ops = [ "ask" ];
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
          exit = null;
          outcomes = [ "done" ];
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
        dom = "Ctx";
        cod = "Ctx";
        outcomes = [ "set" ];
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
        dom = "Ctx";
        cod = "Plan";
        task = "Open: the issue the request names holds the plan to build. Read it with `gh issue view <url>` and record its url; the block builds what its plan says.";
      };
      open_branch = chiefStep {
        dom = "Ctx";
        cod = "Diff";
        task = "Open: the branch or sha the request names is what the block works on. Fetch it and check it out: when `git worktree list` shows a worktree holding the branch, `state move <that worktree>` and work there instead. Record it.";
      };
      open_pr = chiefStep {
        dom = "Ctx";
        cod = "PR";
        task = "Open: the PR the request names is what the block works on. Check out its branch (`gh pr checkout <url>`): when `git worktree list` shows a worktree holding it, `state move <that worktree>` and work there instead. Record its url.";
      };
      direct = chiefStep {
        dom = "Ctx";
        cod = "Ctx";
        task = "Direct: no flow fits the request, so do it yourself, the hooks and the context guard as everywhere; you may commit and open PRs. Record one line: what was asked and what you did.";
      };
      next = chiefStep {
        dom = "Result";
        cod = "Ctx";
        exit = "Result";
        outcomes = [
          "done"
          "request"
        ];
        tools = [ ];
        ops = [ "ask" ];
        task = "Next: tell the user in one line what the request ended in, the last result below, then ask for the next request or whether they are done, and end the turn. `request` when they name one, carrying that result as its context; `done` when they are done. At the Fuel's cap, asked whether to go on: yes is `extend <why>`, no is `done`.";
      };
    };
in
{
  steps = {
    research = {
      dom = "Ctx";
      cod = "Ctx";
      exit = null;
      outcomes = [
        "spawned"
        "handed_back"
      ];
      runner = "researcher";
      lead = "Gather: spawn a researcher per open fact group, in the background or not as its option says, each prompted per the researcher skill's `## Callers`; the hooks record each spawn and hand-back. Each researcher's task:";
      task = "Research the open fact group your prompt names, as the researcher skill says.";
      tools = [
        "read"
        "shell"
        "web"
      ];
      skills = [ "researcher" ];
      prose = [ "topics/fuel.md" ];
      ops = [ ];
      flows = [
        "engineer"
        "10x"
        "architect"
      ];
    };
    interview = {
      dom = "Ctx";
      cod = "Ctx";
      exit = null;
      outcomes = [ "asked" ];
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
      dom = "[Ctx]";
      cod = "Ctx";
      exit = null;
      outcomes = [ "done" ];
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
      dom = "Ctx";
      cod = "Plan";
      exit = null;
      outcomes = [ "done" ];
      runner = "inline";
      task = "Propose: write the plan in the notes directory, as the skill's Propose block says.";
      tools = [
        "read"
        "edit"
      ];
      skills = [
        "engineer"
        "engineering"
      ];
      prose = leadProse;
      ops = [ ];
      flows = [
        "engineer"
        "10x"
      ];
    };
    simplify_plan = {
      dom = "Plan";
      cod = "Plan";
      exit = null;
      outcomes = [ "done" ];
      runner = "researcher";
      lead = "Propose: one researcher, naming the plan and the notes directory. After an adjust that kept the approach, rerun nothing: `state record simplify_plan.done` on the earlier proposal.";
      task = "Run the researcher skill's `references/proposal.md` on the plan your prompt names.";
      tools = [
        "read"
        "shell"
        "web"
      ];
      skills = [ "researcher" ];
      prose = [ "topics/fuel.md" ];
      ops = [ ];
      flows = [
        "engineer"
        "10x"
      ];
    };
    confirm = {
      dom = "Plan";
      cod = "Ctx";
      exit = "Plan";
      outcomes = [
        "confirmed"
        "adjusted"
      ];
      runner = "inline";
      task = "Propose: the simplified plan as one Confirm question. `confirmed` builds it; `adjusted` gathers again.";
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
      dom = "Plan";
      cod = "Plan";
      exit = null;
      outcomes = [ "done" ];
      runner = "inline";
      task = "Build: branch from origin/<base>, or keep the worktree's task branch; an empty commit `Draft: <task> (plan only)`, push, and the draft PR against <base> (`gh pr create --draft --base <base>`) with the plan as its body.";
      tools = [ "shell" ];
      skills = [ "engineer" ];
      prose = leadProse;
      ops = [ ];
      flows = [ "engineer" ];
    };
    implement = {
      dom = "Plan";
      cod = "Diff";
      exit = null;
      outcomes = [ "done" ];
      runner = "implementer";
      lead = "Build: implementers, one per slice, one after another, in parallel only when independent; brief each with `state brief implementer` plus its slice.";
      task = "Build the slice your prompt names, as the plan says.";
      tools = [
        "read"
        "edit"
        "shell"
      ];
      skills = [ "engineering" ];
      prose = [ "shared/building.md" ];
      ops = [ ];
      flows = [ "engineer" ];
    };
    refactor = {
      dom = "Diff";
      cod = "Diff";
      exit = null;
      outcomes = [ "done" ];
      runner = "refactorer";
      lead = "Build: one refactorer, briefed with `state brief refactorer`.";
      task = "Refactor the branch's diff; hand back each bigger proposal as a Scope question.";
      tools = [
        "read"
        "edit"
        "shell"
      ];
      skills = [
        "refactor"
        "engineering"
      ];
      prose = [
        "shared/building.md"
        "topics/fuel.md"
      ];
      ops = [ ];
      flows = [ "engineer" ];
    };
    review = {
      dom = "Diff";
      cod = "Findings";
      exit = "Diff";
      outcomes = [
        "clean"
        "rows"
      ];
      runner = "review-lead";
      lead = "Review: one review-lead, briefed with `state brief review-lead`.";
      task = "Run `pragmatic-review` on the branch against the requirements file.";
      # Its Low sweep reads the Fuel table; it spawns the `reviewer`s.
      tools = [
        "read"
        "shell"
      ];
      skills = [ "pragmatic-review" ];
      prose = leadProse;
      ops = [ "spawn:reviewer" ];
      flows = [ "engineer" ];
    };
    pick = {
      dom = "Findings";
      cod = "Findings";
      exit = "Diff";
      outcomes = [
        "final"
        "loop"
      ];
      runner = "inline";
      task = "Review: pick the rows to fix and judge each requirement, as `references/review.md` says. `final` goes on to describe, where the final fixer gets the chosen rows; `loop` sends them to a fixer, then a re-review, and spends one Re-review. An Unverified requirement is a verdict (`--verdict <req>=unverified`), never a row: with no surviving Major and no Not met, `final` with no `--row`.";
      tools = [ "read" ];
      skills = [ "engineer" ];
      prose = leadProse;
      ops = [ "ask" ];
      flows = [ "engineer" ];
    };
    fix = {
      dom = "Findings";
      cod = "Diff";
      exit = null;
      outcomes = [ "done" ];
      runner = "fixer";
      lead = "Review: one fixer for the picked rows, briefed with `state brief fixer`.";
      task = "Fix the picked rows your prompt names.";
      tools = [
        "read"
        "edit"
        "shell"
      ];
      skills = [ "engineering" ];
      prose = [ "shared/building.md" ];
      ops = [ ];
      flows = [ "engineer" ];
    };
    re_review = {
      dom = "Diff";
      cod = "Findings";
      exit = "Diff";
      outcomes = [
        "clean"
        "rows"
      ];
      runner = "review-lead";
      lead = "Review: one review-lead for the fix, briefed with `state brief review-lead`.";
      task = "Run `pragmatic-review` with `--fixes <sha>`, the last review's head, on the fix against the requirements file; a fix that touches what your Fuel row's Full review of a fix to names gets the whole branch.";
      # Its Low sweep reads the Fuel table; it spawns the `reviewer`s.
      tools = [
        "read"
        "shell"
      ];
      skills = [ "pragmatic-review" ];
      prose = leadProse;
      ops = [ "spawn:reviewer" ];
      flows = [ "engineer" ];
    };
    describe = {
      dom = "Diff";
      cod = "PR";
      exit = null;
      outcomes = [ "done" ];
      runner = "fixer";
      lead = "Describe: the final fixer, briefed with `state brief fixer`.";
      task = "Fix row R0, writing the PR body's full facts as `pr-description` says, and any picked rows your prompt names; nothing reviews your fix.";
      tools = [
        "read"
        "edit"
        "shell"
      ];
      skills = [ "engineering" ];
      prose = [ "shared/building.md" ];
      ops = [ ];
      flows = [ "engineer" ];
    };
    simplify_pr = {
      dom = "PR";
      cod = "PR";
      exit = null;
      outcomes = [ "done" ];
      runner = "fixer";
      lead = "Describe: a fixer on row S0, briefed with `state brief fixer`.";
      task = "Row S0: `pr-description`'s Simplify; your hand-back ends `Simplified: <head sha>`.";
      tools = [
        "read"
        "edit"
        "shell"
      ];
      skills = [ "engineering" ];
      prose = [ "shared/building.md" ];
      ops = [ ];
      flows = [ "engineer" ];
    };
    await_ci = {
      dom = "PR";
      cod = "PR";
      exit = "PR";
      outcomes = [
        "green"
        "red"
      ];
      runner = "inline";
      task = "Ship: CI on the PR. `green` when every check passes; `red` names the failing checks.";
      tools = [ "shell" ];
      skills = [ "engineer" ];
      prose = leadProse;
      ops = [ "await" ];
      flows = [ "engineer" ];
    };
    fix_pr = {
      dom = "PR";
      cod = "PR";
      exit = null;
      outcomes = [ "done" ];
      runner = "fixer";
      lead = "Ship: one fixer on the failing checks, as `references/review.md`'s CI fix says, briefed with `state brief fixer`.";
      task = "Fix the failing checks your prompt names.";
      tools = [
        "read"
        "edit"
        "shell"
      ];
      skills = [ "engineering" ];
      prose = [ "shared/building.md" ];
      ops = [ ];
      flows = [ "engineer" ];
    };
    ready = {
      dom = "PR";
      cod = "(done: PR + skipped: PR)";
      exit = null;
      outcomes = [
        "done"
        "skipped"
      ];
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
      prose = [ "topics/fuel.md" ];
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
      prose = [ ];
      ops = [ ];
    };
  };
}
