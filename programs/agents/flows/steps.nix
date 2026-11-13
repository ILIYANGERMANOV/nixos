# The step table of #351's flows (#360 "Step table schema"): plain data, one
# row per step of the kernel's `State.Cap`. `dom`, `cod` and `exit` are the
# step's types (`in` is a Nix keyword), `outcomes` its exit outcome first, then
# the continuing one; `skipped` is no outcome, a mode's skip appends it.
# `runner` is `inline` (the lead) or the role a subagent runs; `entry` is the
# text `state next` prints for the step. The kernel's test holds the types and
# outcomes equal to `State.Cap`. Tools, skills, prose and ops come in PR 5.
{
  research = {
    dom = "Ctx";
    cod = "Ctx";
    exit = null;
    outcomes = [ "done" ];
    runner = "researcher";
    entry = "Gather: researchers in parallel, each prompted per the researcher skill's `## Callers`, one per open fact group. When all are back: `state record research.done <n>`.";
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
    entry = "Propose: one researcher in the background on the researcher skill's `references/proposal.md`, mode simplify, naming the plan and the notes directory.";
  };
  alternative = {
    dom = "Plan";
    cod = "Plan";
    exit = null;
    outcomes = [ "done" ];
    runner = "researcher";
    entry = "Propose: one researcher in the background on the researcher skill's `references/proposal.md`, mode alternative, naming the plan and the notes directory.";
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
    entry = "Build: implementers per slice, one after another, in parallel only when independent; brief each with `state brief implementer` plus its slice.";
  };
  refactor = {
    dom = "Diff";
    cod = "Diff";
    exit = null;
    outcomes = [ "done" ];
    runner = "refactorer";
    entry = "Build: one refactorer, briefed with `state brief refactorer`; its bigger proposals are a Scope question.";
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
    entry = "Review: the review-lead runs `pragmatic-review` on the branch, or on the fixes after round 1, against the requirements file.";
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
    entry = "Review: one fixer for the picked rows, briefed with `state brief fixer`.";
  };
  describe = {
    dom = "Diff";
    cod = "PR";
    exit = null;
    outcomes = [ "done" ];
    runner = "fixer";
    entry = "Describe: the final fixer, row R0 and any picked rows; nothing reviews it.";
  };
  simplify_pr = {
    dom = "PR";
    cod = "PR";
    exit = null;
    outcomes = [ "done" ];
    runner = "fixer";
    entry = "Describe: a fixer on row S0, `pr-description`'s Simplify; its hand-back ends `Simplified: <head sha>`.";
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
    entry = "Ship: wait for CI on the PR, never by polling in a loop.";
  };
  fix_pr = {
    dom = "PR";
    cod = "PR";
    exit = null;
    outcomes = [ "done" ];
    runner = "fixer";
    entry = "Ship: one fixer on the failing checks, as `references/review.md`'s CI fix says.";
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
