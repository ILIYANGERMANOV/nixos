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
  // A file that does not exist, so Stryker leaves tsconfig.json alone: it would
  // import `typescript` to rewrite its paths, which this one needs no rewrite of
  // and which the lock file must not hold (see default.nix).
  tsconfigFile: "no-tsconfig-to-rewrite.json",
  // Advisory: a score is reported, never enforced.
  thresholds: { high: 90, low: 80, break: null },
  reporters: ["json", "progress-append-only"],
};
