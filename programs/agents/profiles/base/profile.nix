# What every setup gets. agent.md reaches every agent, subagent roles included;
# lead.md is the lead's own role, and the lead also gets the trivial and
# quality topics.
{
  mkFragment,
  mkInstructions,
  topics,
  qa,
}:
{
  # Every skill is here, ui-coding included, because a model-invoked skill costs
  # only its description until a task needs it.
  skills = [
    "address-pr-feedback"
    "architect"
    "engineer"
    "engineering"
    "final-review"
    "give-feedback"
    "grill-with-docs"
    "grilling"
    "domain-modeling"
    "grill-me"
    "pr-description"
    "pragmatic-review"
    "qa"
    "refactor"
    "researcher"
    "setup-matt-pocock-skills"
    "skeptic"
    "ui-coding"
  ];
  instructions = mkInstructions {
    forAll = [
      (mkFragment {
        layer = "agent";
        file = ../../instructions/agent.md;
      })
    ];
    forLead = [
      (mkFragment {
        layer = "role";
        file = ../../instructions/lead.md;
      })
      topics.trivial
      topics.quality
    ];
  };
  # On PATH in every session, whatever the project: /qa's `qa-node` (Playwright,
  # Chromium, viem and the qa-wallet helper) and `qa-mp4` (ffmpeg).
  runtime = [ qa ];
  # /qa's wallet key, handed out as the decrypted file's PATH for qa-wallet to
  # read, never as a value. A host without the secret gets no variable.
  secretFiles.QA_EVM_KEY_FILE = "qa-sepolia-key";
}
