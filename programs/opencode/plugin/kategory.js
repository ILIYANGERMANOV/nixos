// opencode-kategory's plugin: plain JavaScript importing only a Node builtin,
// which Bun resolves with nothing installed, so OpenCode loads it from the
// read-only config dir. OpenCode takes every export for a plugin function.
//
// The one plugin the harness ships. It does two things.
//
// shell.env: the wrapper (launch.sh) moved XDG_CONFIG_HOME, XDG_DATA_HOME and
// XDG_CACHE_HOME away from the user's for OpenCode itself, and saved the
// user's own as one JSON object in the variable below. Every shell OpenCode
// runs gets them back, so gh and git read the user's config. XDG_STATE_HOME
// stays moved: `state` keeps OpenCode's own run store.
//
// The profile's hooks: each OpenCode hook below runs agent-hook-opencode
// (hooks/opencode_adapter.py) with one envelope on stdin, and does what it
// answers: a deny fails the tool call with its reason, a rewrite sets the
// call's args, context reaches the model in the tool's output or, for the
// session's events, in the next request's system prompt. The adapter owns
// every mapping to the neutral contract. This file keeps only what an
// envelope needs from earlier calls: each session's parent and agent, whether
// it was created and has had a message, its bash commands, its last model
// calls' tokens, the background children running, and the context waiting for
// its place.
//
// The adapter runs synchronously, with the user's XDG dirs as a shell gets
// them and XDG_STATE_HOME moved, so the hooks' `state` shares the shells'
// kernel.db. One that fails lets the call go on, with a note saying so.
//
// Known gaps, as docs/KATEGORY.md says:
// - No agent can stop another: OpenCode has no such tool.
// - A child starts at its first chat.message and stops when its task result
//   reaches its parent: close to Claude Code's SubagentStart and Stop, not
//   the same.
// - The context guard acts only once message.updated has told a model call's
//   tokens; until then it lets the call go.
// - A tool that fails skips tool.execute.after: its after-hooks never run.
// - `opencode debug agent --tool` runs the tool directly: no tool hook runs.
// - A child session created by an earlier OpenCode process, resumed with
//   task_id, is taken for a lead: its parent is known only from
//   session.created.
import { spawnSync } from "node:child_process";

// Parsed once, at load: the wrapper always sets it, so a missing or broken
// value is a bug and fails the load.
const userXdg = JSON.parse(process.env["@userXdgVar@"]);

const adapter = "@hookAdapter@";
const adapterArgs = ["@hookTools@", "@hookManifest@"];

// The tool ids whose `command` is a shell command, from codegen/tools.nix.
const shellTools = new Set("@shellTools@".split(" "));

// The bash commands an envelope carries: enough for the wait guard, which
// looks back at the last few.
const historyLength = 50;

// The model calls whose tokens an envelope carries. The newest may still be
// streaming, with none counted yet: the adapter needs the two before it.
const callsKept = 3;

export const Kategory = async ({ directory }) => {
  // id -> {parentID, agent, created, started}: created once session.created
  // was seen, started once its first chat.message was.
  const sessions = new Map();
  // id -> its bash commands, oldest first.
  const commands = new Map();
  // id -> [{message, tokens}]: its last model calls' tokens, oldest first.
  const calls = new Map();
  // The background children started and not yet idle.
  const running = new Set();
  // callID -> a before-hook's context, for the call's output.
  const held = new Map();
  // id -> context for the session's next system prompt.
  const queued = new Map();

  const ask = (sessionID, hook, fields) =>
    answer({
      hook,
      sessionID,
      rootID: rootOf(sessions, sessionID),
      agent: sessions.get(sessionID)?.agent ?? null,
      directory,
      ...fields,
    });
  const runningUnder = (sessionID) => {
    const root = rootOf(sessions, sessionID);
    return [...running].filter((child) => rootOf(sessions, child) === root);
  };
  const queue = (sessionID, context) => {
    if (context !== undefined) {
      queued.set(sessionID, [...(queued.get(sessionID) ?? []), context]);
    }
  };

  return {
    "shell.env": async (_input, output) => {
      Object.assign(output.env, userXdg);
    },

    "tool.execute.before": async ({ tool, sessionID, callID }, output) => {
      const said = ask(sessionID, "before", {
        tool,
        args: output.args,
        history: commands.get(sessionID) ?? [],
      });
      if (shellTools.has(tool)) {
        commands.set(
          sessionID,
          [...(commands.get(sessionID) ?? []), output.args.command].slice(
            -historyLength,
          ),
        );
      }
      if (said.deny !== undefined) {
        throw new Error(said.deny);
      }
      if (said.args !== undefined) {
        replaceKeys(output.args, said.args);
      }
      if (said.context !== undefined) {
        held.set(callID, said.context);
      }
    },

    "tool.execute.after": async ({ tool, sessionID, callID, args }, output) => {
      // Only the task tool runs a child in the background.
      if (output.metadata?.background === true) {
        running.add(output.metadata.sessionId);
      }
      const said = ask(sessionID, "after", {
        tool,
        args,
        output,
        tokens: (calls.get(sessionID) ?? []).map((call) => call.tokens),
        running: runningUnder(sessionID),
      });
      const notes = [held.get(callID), said.context].filter(
        (note) => note !== undefined,
      );
      held.delete(callID);
      if (notes.length > 0) {
        output.output = [output.output, ...notes].join("\n\n");
      }
    },

    "chat.message": async ({ sessionID, agent }, output) => {
      const known = sessions.get(sessionID) ?? { created: false };
      sessions.set(sessionID, {
        ...known,
        agent: known.agent ?? agent ?? null,
        started: true,
      });
      const said = ask(sessionID, "message", {
        first: !known.started,
        created: known.created,
        parts: output.parts,
        agents: agentsOf(sessions),
        running: runningUnder(sessionID),
      });
      queue(sessionID, said.context);
    },

    "command.execute.before": async ({ command, sessionID }) => {
      queue(sessionID, ask(sessionID, "command", { command }).context);
    },

    "experimental.chat.system.transform": async ({ sessionID }, output) => {
      output.system.push(...(queued.get(sessionID) ?? []));
      queued.delete(sessionID);
    },

    // OpenCode calls this synchronously as it publishes, and does not await
    // it: the maps are current before the next hook runs.
    event: async ({ event }) => {
      switch (event.type) {
        case "session.created": {
          const { info } = event.properties;
          sessions.set(info.id, {
            ...sessions.get(info.id),
            parentID: info.parentID,
            agent: info.agent ?? null,
            created: true,
          });
          break;
        }
        case "message.updated": {
          // Only a model call's message has tokens, a user's none.
          const { info } = event.properties;
          if (info.tokens !== undefined) {
            calls.set(
              info.sessionID,
              updated(calls.get(info.sessionID) ?? [], info.id, info.tokens),
            );
          }
          break;
        }
        case "session.idle": {
          const { sessionID } = event.properties;
          running.delete(sessionID);
          queue(
            sessionID,
            ask(sessionID, "idle", { running: runningUnder(sessionID) })
              .context,
          );
          break;
        }
      }
    },
  };
};

// The adapter's answer to one envelope, or a note that it failed.
function answer(envelope) {
  const run = spawnSync(adapter, adapterArgs, {
    input: JSON.stringify(envelope),
    encoding: "utf8",
    env: { ...process.env, ...userXdg },
  });
  return run.status === 0
    ? JSON.parse(run.stdout)
    : {
        context: `agent-hook-opencode failed, so no hook judged this: ${run.error?.message ?? run.stderr}`,
      };
}

// A session's root, the lead's: found through each parent.
function rootOf(sessions, id) {
  const parent = sessions.get(id)?.parentID;
  return parent === undefined ? id : rootOf(sessions, parent);
}

function agentsOf(sessions) {
  return Object.fromEntries(
    [...sessions]
      .filter(([, session]) => session.agent !== null)
      .map(([id, session]) => [id, session.agent]),
  );
}

// OpenCode runs the call with this same args object: only its keys can change.
function replaceKeys(target, source) {
  for (const key of Object.keys(target)) {
    if (!(key in source)) {
      delete target[key];
    }
  }
  Object.assign(target, source);
}

// A session's model calls with one call's newest tokens. OpenCode updates a
// call's message as it streams, so a message replaces its own tokens.
function updated(known, message, tokens) {
  return known.some((call) => call.message === message)
    ? known.map((call) =>
        call.message === message ? { message, tokens } : call,
      )
    : [...known, { message, tokens }].slice(-callsKept);
}
