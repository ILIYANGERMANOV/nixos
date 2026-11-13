# The step table of #351's flows (#360 "Step table schema"): plain data, one
# row per step of the kernel's `State.Cap`. `dom`, `cod` and `exit` are the
# step's types (`in` is a Nix keyword), `outcomes` its exit outcome first, then
# the continuing one; `skipped` is no outcome, a mode's skip appends it.
# `runner` is `inline` (the lead) or the role a subagent runs; `entry` is the
# text `state next` prints for the step, and `state brief` for its subagent.
# A subagent's step has a `lead` too: the lead's part, which only `state next`
# prints, before the entry. The kernel's test holds the types and
# outcomes equal to `State.Cap`. Tools, skills, prose and ops come in PR 5.
{
  research = {
    dom = "Ctx";
    cod = "Ctx";
    exit = null;
    outcomes = [ "done" ];
    runner = "researcher";
    lead = "Gather: researchers in parallel, each prompted per the researcher skill's `## Callers`, one per open fact group. When all are back: `state record research.done <n>`.";
    entry = "Research the open fact group your prompt names, as the researcher skill says.";
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
    entry = "Gather: the `grilling` interview, one question at a time, each through `state ask`. `enough` when nothing is open; `more` when an answer opens a fact to research.";
  };
  plan = {
    dom = "Ctx";
    cod = "Plan";
    exit = null;
    outcomes = [ "done" ];
    runner = "inline";
    entry = "Propose: write the plan in the notes directory, as the skill's Propose block says.";
  };
  simplify_plan = {
    dom = "Plan";
    cod = "Plan";
    exit = null;
    outcomes = [ "done" ];
    runner = "researcher";
    lead = "Propose: one researcher in the background, naming the plan and the notes directory.";
    entry = "Run the researcher skill's `references/proposal.md`, mode simplify, on the plan your prompt names.";
  };
  alternative = {
    dom = "Plan";
    cod = "Plan";
    exit = null;
    outcomes = [ "done" ];
    runner = "researcher";
    lead = "Propose: one researcher in the background, naming the plan and the notes directory.";
    entry = "Run the researcher skill's `references/proposal.md`, mode alternative, on the plan your prompt names.";
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
    entry = "Propose: the plan and its proposals as one Confirm question. `confirmed` builds it; `adjusted` gathers again.";
  };
  draft = {
    dom = "Plan";
    cod = "Plan";
    exit = null;
    outcomes = [ "done" ];
    runner = "inline";
    entry = "Build: branch, an empty commit, push, and the draft PR with the plan as its body.";
  };
  implement = {
    dom = "Plan";
    cod = "Diff";
    exit = null;
    outcomes = [ "done" ];
    runner = "implementer";
    lead = "Build: implementers as your Quality row's Implement says, one per slice, one after another, in parallel only when independent; brief each with `state brief implementer` plus its slice.";
    entry = "Build the slice your prompt names, as the plan says.";
  };
  refactor = {
    dom = "Diff";
    cod = "Diff";
    exit = null;
    outcomes = [ "done" ];
    runner = "refactorer";
    lead = "Build: one refactorer, briefed with `state brief refactorer`.";
    entry = "Refactor the branch's diff; hand back each bigger proposal as a Scope question.";
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
    entry = "Run `pragmatic-review` on the branch, or on the fixes after round 1, against the requirements file.";
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
    entry = "Review: pick the rows to fix and judge each requirement, as `references/review.md` says. `final` hands the rows to the final fixer; `loop` fixes them and reviews again.";
  };
  fix = {
    dom = "Diff";
    cod = "Diff";
    exit = null;
    outcomes = [ "done" ];
    runner = "fixer";
    lead = "Review: one fixer for the picked rows, briefed with `state brief fixer`.";
    entry = "Fix the picked rows your prompt names.";
  };
  describe = {
    dom = "Diff";
    cod = "PR";
    exit = null;
    outcomes = [ "done" ];
    runner = "fixer";
    lead = "Describe: the final fixer, briefed with `state brief fixer`.";
    entry = "Fix row R0 and any picked rows your prompt names; nothing reviews your fix.";
  };
  simplify_pr = {
    dom = "PR";
    cod = "PR";
    exit = null;
    outcomes = [ "done" ];
    runner = "fixer";
    lead = "Describe: a fixer on row S0, briefed with `state brief fixer`.";
    entry = "Row S0: `pr-description`'s Simplify; your hand-back ends `Simplified: <head sha>`.";
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
    entry = "Ship: CI on the PR. `green` when every check passes; `red` names the failing checks.";
  };
  fix_pr = {
    dom = "PR";
    cod = "PR";
    exit = null;
    outcomes = [ "done" ];
    runner = "fixer";
    lead = "Ship: one fixer on the failing checks, as `references/review.md`'s CI fix says, briefed with `state brief fixer`.";
    entry = "Fix the failing checks your prompt names.";
  };
  ready = {
    dom = "PR";
    cod = "PR";
    exit = null;
    outcomes = [ "done" ];
    runner = "inline";
    entry = "Ship: the gates below, then mark the PR ready and notify.";
  };
  breakdown = {
    dom = "Plan";
    cod = "[Ctx]";
    exit = null;
    outcomes = [ "done" ];
    runner = "inline";
    entry = "Break the confirmed plan into tasks.";
  };
  merge = {
    dom = "[PR]";
    cod = "PR";
    exit = null;
    outcomes = [ "done" ];
    runner = "inline";
    entry = "Merge the tasks' PRs into one.";
  };
}
