---
name: grilling
description: Grill the user relentlessly about a plan, decision, or idea. Use when the user wants to stress-test their thinking, or uses any 'grill' trigger phrases.
---

Interview the user relentlessly until you reach a shared understanding. Map this as a **design tree**: every decision branches into the decisions that hang off it.

The **frontier** is every decision whose prerequisites are already settled: the questions you can ask _now_ without guessing at answers you haven't heard yet. Pick the most load-bearing question on the frontier - the one that unblocks the most of the tree - and ask it.

Ask **one question at a time**, as plain text that ends your turn, never a batch. The person reads it on a phone and often dictates the reply, so follow the Asking rules in your instructions: notify the user first, then context, `Q:`, 2-4 lettered options with your recommendation first marked `(Recommended)`, then "Reply with a letter or your own words."

- Make each option a distinct, concrete answer. The user's own words cover open answers, so never add an "Other" option yourself.

Each answer reshapes the tree: a settled decision pushes the frontier outward and unblocks the questions that depended on it. Recompute the frontier after every answer, then ask the next question.

Finding _facts_ is your job, never the user's. When a frontier question needs a fact from the environment (filesystem, tools, etc.), dispatch a `subagent_type: researcher` agent in the background to find it; don't ask the user for anything you could look up yourself. Don't block on it: a running exploration is an unsettled prerequisite, so only the questions downstream of it wait for the sub-agent to report; keep asking the rest of the frontier meanwhile. The _decisions_ are the user's: put each to them and wait.

The session is done when the frontier is empty: every branch of the design tree visited, nothing left silently assumed. Do not act on it until the user confirms you have reached a shared understanding: summarise the agreed decisions in a few lines, then confirm with one last question (for example "Q: Shared understanding reached?" with "A) Yes, proceed (Recommended)" and "B) No, keep grilling"). Skip that confirmation when your caller says so, such as `engineer` or `10x-engineer`, which confirm the plan next.
