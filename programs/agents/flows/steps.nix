# The step table of #351's flows (#360 "Step table schema"): plain data, one
# row per step of the kernel's `State.Category.Step`. `dom`, `cod` and `exit` are the
# step's types (`in` is a Nix keyword), `outcomes` its exit outcome first, then
# the continuing one; `skipped` is no outcome, a mode's skip appends it.
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
# names the flows the step is in, `engineer` or `10x`. A role leads the flow
# named after it (the kernel's `State.Role`), so the `engineer` flow's inline rows are the engineer
# role's. `offFlow` is a `role`'s work outside the two flows: it has no types,
# the kernel never sees it, and only the derivation reads it.
let
  # The lead's Size and Quality rules, read at every step it decides to run
  # or skip.
  leadProse = [
    "topics/trivial.md"
    "topics/quality.md"
  ];
in
{
  steps = {
    research = {
      dom = "Ctx";
      cod = "Ctx";
      exit = null;
      outcomes = [ "done" ];
      runner = "researcher";
      lead = "Gather: researchers in parallel, each prompted per the researcher skill's `## Callers`, one per open fact group. When all are back: `state record research.done <n>`.";
      task = "Research the open fact group your prompt names, as the researcher skill says.";
      tools = [
        "read"
        "shell"
        "web"
      ];
      skills = [ "researcher" ];
      prose = [ "topics/quality.md" ];
      ops = [ ];
      flows = [
        "engineer"
        "10x"
      ];
    };
    interview = {
      dom = "Ctx";
      cod = "Ctx";
      exit = "Ctx";
      outcomes = [
        "enough"
        "more"
      ];
      runner = "inline";
      task = "Gather: the `grilling` interview, one question at a time, each through `state ask`. `enough` when nothing is open; `more` when an answer opens a fact to research.";
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
      prose = [ "topics/quality.md" ];
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
      task = "Build: branch, an empty commit, push, and the draft PR with the plan as its body.";
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
      lead = "Build: implementers as your Quality row's Implement says, one per slice, one after another, in parallel only when independent; brief each with `state brief implementer` plus its slice.";
      task = "Build the slice your prompt names, as the plan says.";
      tools = [
        "read"
        "edit"
        "shell"
      ];
      skills = [ "engineering" ];
      prose = [
        "shared/building.md"
        "topics/quality.md"
      ];
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
        "topics/quality.md"
      ];
      ops = [ ];
      flows = [ "engineer" ];
    };
    review = {
      dom = "Diff";
      cod = "Diff";
      exit = "Diff";
      outcomes = [
        "clean"
        "rows"
      ];
      runner = "review-lead";
      lead = "Review: one review-lead, briefed with `state brief review-lead`.";
      task = "Run `pragmatic-review` on the branch, or on the fixes after round 1, against the requirements file.";
      # Its sweep reads the Trivial rule; it spawns the `reviewer`s.
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
      dom = "Diff";
      cod = "Diff";
      exit = "Diff";
      outcomes = [
        "final"
        "loop"
      ];
      runner = "inline";
      task = "Review: pick the rows to fix and judge each requirement, as `references/review.md` says. `final` hands the rows to the final fixer; `loop` fixes them and reviews again.";
      tools = [ "read" ];
      skills = [ "engineer" ];
      prose = leadProse;
      ops = [ "ask" ];
      flows = [ "engineer" ];
    };
    fix = {
      dom = "Diff";
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
      cod = "PR";
      exit = null;
      outcomes = [ "done" ];
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
      cod = "PR";
      exit = null;
      outcomes = [ "done" ];
      runner = "inline";
      task = "Merge: the review queue, the merge loop and the final audit, as the 10x skill's Merge says.";
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
      prose = [ "topics/quality.md" ];
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
