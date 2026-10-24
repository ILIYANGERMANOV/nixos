---
name: grilling
description: Grill the user relentlessly about a plan, decision, or idea. Use when the user wants to stress-test their thinking, or uses any 'grill' trigger phrases.
---

Interview the user relentlessly until you reach a shared understanding. Map this as a **design tree**: every decision branches into the decisions that hang off it.

The **frontier** is every decision whose prerequisites are already settled: the questions you can ask _now_ without guessing at answers you haven't heard yet. Pick the most load-bearing question on the frontier - the one that unblocks the most of the tree - and ask it.

Ask **one question at a time** through the `AskUserQuestion` tool: one question per call, never a batch in chat. The person reads it on a phone, so:

- Keep the question to one or two short sentences. Put any context it needs in the option descriptions, not in a preamble.
- Give 2-4 options. Put your recommended option first and end its label with `(Recommended)`.
- Make each option a distinct, concrete answer. The picker's free-text "Other" covers open answers, so never add an "Other" option yourself.

Each answer reshapes the tree: a settled decision pushes the frontier outward and unblocks the questions that depended on it. Recompute the frontier after every answer, then ask the next question.

Finding _facts_ is your job, never the user's. When a frontier question needs a fact from the environment (filesystem, tools, etc.), dispatch a sub-agent in the background to find it; don't ask the user for anything you could look up yourself. Don't block on it: a running exploration is an unsettled prerequisite, so only the questions downstream of it wait for the sub-agent to report; keep asking the rest of the frontier meanwhile. The _decisions_ are the user's: put each to them and wait.

The session is done when the frontier is empty: every branch of the design tree visited, nothing left silently assumed. Do not act on it until the user confirms you have reached a shared understanding: summarise the agreed decisions in a few lines, then confirm with one last `AskUserQuestion` (for example "Shared understanding reached?" with "Yes, proceed (Recommended)" and "No, keep grilling").
