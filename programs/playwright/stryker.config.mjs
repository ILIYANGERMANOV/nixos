// Run it through `just mutation-diff` or `just mutation`: the runner,
// programs/mutation/mutation_diff.py, names the files to mutate and reads the
// json report. See docs/adr/0010-mutation-testing.md.
/** @type {import("@stryker-mutator/api/core").PartialStrykerOptions} */
export default {
  packageManager: "pnpm",
  testRunner: "vitest",
  plugins: [import.meta.resolve("@stryker-mutator/vitest-runner")],
  ignoreStatic: true,
  incremental: true,
  // Advisory: a score is reported, never enforced.
  thresholds: { high: 90, low: 80, break: null },
  reporters: ["json", "progress-append-only"],
};
