// `qa-kit`: what every /qa script shares, resolvable from any directory under
// `qa-node`.
//
//   const { connect, openContext, expectState, capture, VIEWPORT } = require('qa-kit');
//
// `connect(runDir)` attaches to the browser `qa-session start <runDir>` holds,
// with its logged-in page as it was left; `close()` saves the login back to
// the session's --storage-state file, detaches and leaves the browser open for
// the next probe. `openContext({ auth, ...contextOptions })` launches Chromium
// with a context on the saved login `auth` and saves it back on `close()`,
// SIGTERM and SIGINT, as a refresh token that rotated is spent in the old file.
// Every save keeps the previous file as `<auth>.bak` and refuses a state with
// no cookies, keeping the old one. `expectState(expected, failures)` waits for
// whichever of the expected locator and the named failure locators appears
// first; a timeout above 60 s is capped unless `{ reason }` says why it needs
// longer. `capture(context, file)` appends the context's console, page errors
// and failed requests to `file` with credentials redacted; `redact(text)` is
// that redaction.
//
// `qa-node` kills its script after QA_NODE_TIMEOUT (default 300 s, any
// `timeout` duration such as 600 or 10m, 0 for none) with SIGTERM and exits
// 124, so a script that hangs still ends and still saves its login.
import fs from "node:fs";
import path from "node:path";
import {
  type Browser,
  type BrowserContext,
  type BrowserContextOptions,
  chromium,
  type Locator,
  type Page,
} from "playwright";
import type { Receipt, WalletControls } from "qa-wallet";

// The video size and the viewport of every /qa page, so a probe sees the
// layout the recording will show.
export const VIEWPORT = Object.freeze({ width: 960, height: 540 });

// Written by `qa-session start` into the run directory.
export const SESSION_FILE = "qa-session.json";

// The binding `qa-session` exposes for the controls a probe needs: saving
// the login and the wallet's.
export const SESSION_BINDING = "__qaSession";

// The longest expectState waits without a reason: past a minute, a screen
// that has not come is almost always one that will not.
export const MAX_WAIT_MS = 60_000;

// How long one step of a /qa script waits by default.
export const STEP_TIMEOUT_MS = 10_000;

/** What `qa-session` writes to SESSION_FILE. */
export type SessionFile = { endpoint: string; pid: number };

export type SaveResult =
  | { kind: "saved" }
  | { kind: "refused"; reason: string };

/** A session with no --storage-state has no login to save. */
export type SessionSaveResult = SaveResult | { kind: "no-login" };

export type SessionControls = WalletControls & {
  saveState: () => Promise<SessionSaveResult>;
};

export type Session = Pick<WalletControls, "waitForReceipt"> & {
  context: BrowserContext;
  page: Page;
  close: () => Promise<void>;
  rejectNext: (
    ...args: Parameters<WalletControls["rejectNext"]>
  ) => Promise<void>;
};

export type OwnedContext = {
  browser: Browser;
  context: BrowserContext;
  close: () => Promise<void>;
};

export type ExpectStateOptions = { timeout?: number; reason?: string };

export type ExpectedState =
  | { kind: "expected" }
  | { kind: "failed"; name: string; text: string };

declare global {
  interface Window {
    [SESSION_BINDING]: (op: string, args: unknown[]) => Promise<unknown>;
  }
}

/**
 * Attaches to the session browser of `runDir`. `rejectNext` and
 * `waitForReceipt` are the session wallet's, as `installWallet` returns them;
 * they fail when the session has no wallet.
 */
export async function connect(runDir: string): Promise<Session> {
  const { endpoint } = readSession(runDir);
  const browser = await chromium.connectOverCDP(endpoint);
  const context = browser.contexts().find((c) => c.pages().length > 0);
  const page = context?.pages()[0];
  if (!context || !page) {
    throw new Error(
      "qa-kit: the session has no open page; restart it with qa-session",
    );
  }
  context.setDefaultTimeout(STEP_TIMEOUT_MS);
  const control = <Op extends keyof SessionControls>(
    op: Op,
    args: Parameters<SessionControls[Op]>,
  ) =>
    page.evaluate(([binding, op, args]) => window[binding](op, args), [
      SESSION_BINDING,
      op,
      args,
    ] as [typeof SESSION_BINDING, string, unknown[]]) as Promise<
      Awaited<ReturnType<SessionControls[Op]>>
    >;
  return {
    context,
    page,
    close: async () => {
      const saved = await control("saveState", []);
      if (saved.kind === "refused") {
        console.error(
          `qa-kit: the session kept its previous login: ${saved.reason}`,
        );
      }
      await browser.close();
    },
    rejectNext: async (method, options) => {
      await control("rejectNext", [method, options]);
    },
    waitForReceipt: (hash, options): Promise<Receipt> =>
      control("waitForReceipt", [hash, options]),
  };
}

export function readSession(runDir: string): SessionFile {
  const file = path.join(runDir, SESSION_FILE);
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    const { code, message } = error as NodeJS.ErrnoException;
    throw new Error(
      `qa-kit: no session in ${runDir} (${code ?? message}); run qa-session start ${runDir}`,
    );
  }
}

/**
 * Launches Chromium and opens a context on the saved login `auth` (a
 * storageState file), saving the login back to it on `close()` and when the
 * process gets SIGTERM or SIGINT, which is what `qa-node`'s deadline sends.
 * It launches the browser itself because Playwright's own signal handlers
 * would close it before the login could be read.
 */
export async function openContext({
  auth,
  ...contextOptions
}: { auth: string } & BrowserContextOptions): Promise<OwnedContext> {
  const browser = await chromium.launch({
    handleSIGTERM: false,
    handleSIGINT: false,
  });
  const context = await browser.newContext({
    viewport: VIEWPORT,
    ...contextOptions,
    storageState: auth,
  });
  // `timeout` signals node and then its group, so one signal can arrive twice.
  // The listeners stay on, as without one the next signal kills node mid-save.
  // biome-ignore lint/correctness/noUnusedVariables: `??=` reads it, which is how a second signal skips the save.
  let exiting: Promise<unknown> | undefined;
  const onSignal = (signal: NodeJS.Signals) => {
    const code = signal === "SIGINT" ? 130 : 143;
    exiting ??= saveState(context, auth)
      .catch((error: Error) =>
        console.error(`qa-kit: could not save ${auth}: ${error.message}`),
      )
      .finally(() => process.exit(code));
  };
  process.on("SIGTERM", onSignal);
  process.on("SIGINT", onSignal);
  return {
    browser,
    context,
    close: async () => {
      process.off("SIGTERM", onSignal);
      process.off("SIGINT", onSignal);
      await saveState(context, auth);
      await browser.close();
    },
  };
}

/**
 * Writes the login of `context` to `file`, keeping the file it replaces as
 * `<file>.bak`. A state with no cookies is a lost login, not a newer one, so
 * it is refused and the old file stays.
 */
export async function saveState(
  context: BrowserContext,
  file: string,
): Promise<SaveResult> {
  const state = await context.storageState();
  if (state.cookies.length === 0) {
    const reason = "the state has no cookies";
    console.error(
      `qa-kit: not saving ${file}: ${reason}; kept the previous one`,
    );
    return { kind: "refused", reason };
  }
  if (fs.existsSync(file)) fs.copyFileSync(file, `${file}.bak`);
  // Written beside the file and renamed over it, so a kill mid-write cannot
  // leave half a login behind.
  const tmp = `${file}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, file);
  return { kind: "saved" };
}

/**
 * Waits until the expected locator or one of the failure locators is visible,
 * whichever comes first, so a script stops at an error screen instead of
 * waiting out the timeout for a success that will not come.
 *
 * @param expected  a Locator for the success state
 * @param failures  { name: Locator } for each error state
 * @param options.timeout  milliseconds before neither appearing throws,
 *   capped at MAX_WAIT_MS unless `options.reason` says why it needs longer
 */
export async function expectState(
  expected: Locator,
  failures: Record<string, Locator> = {},
  { timeout = STEP_TIMEOUT_MS, reason }: ExpectStateOptions = {},
): Promise<ExpectedState> {
  const capped = (timeout === 0 || timeout > MAX_WAIT_MS) && !reason;
  if (capped) {
    console.error(
      `qa-kit: capped expectState's ${timeout === 0 ? "unbounded" : `${timeout} ms`} timeout to ${MAX_WAIT_MS} ms; pass { reason } to wait longer`,
    );
  }
  const outcomes: [string, Locator][] = [
    ["expected", expected],
    ...Object.entries(failures),
  ];
  const any = outcomes
    .map(([, locator]) => locator)
    .reduce((all, locator) => all.or(locator));
  await any
    .first()
    .waitFor({ state: "visible", timeout: capped ? MAX_WAIT_MS : timeout });
  for (const [name, locator] of outcomes) {
    const first = locator.first();
    if (!(await first.isVisible())) continue;
    return name === "expected"
      ? { kind: "expected" }
      : { kind: "failed", name, text: await first.innerText() };
  }
  // Rare: the state appeared and vanished between the wait and the check.
  throw new Error(
    "qa-kit: expectState saw a state that vanished before it could be read",
  );
}

/**
 * Appends what the pages of `context` log - console messages, uncaught
 * errors, failed requests and HTTP error responses - to `file`, one line each,
 * every line redacted. The only console capture a /qa script needs.
 */
export function capture(context: BrowserContext, file: string): void {
  const write = (line: string) => fs.appendFileSync(file, `${redact(line)}\n`);
  context.on("console", (message) =>
    write(`console.${message.type()} ${message.text()}`),
  );
  context.on("weberror", (error) =>
    write(`pageerror ${error.error().message}`),
  );
  context.on("requestfailed", (request) =>
    write(
      `requestfailed ${request.method()} ${request.url()} ${request.failure()?.errorText ?? ""}`,
    ),
  );
  context.on("response", (response) => {
    if (response.status() >= 400) {
      write(
        `http ${response.status()} ${response.request().method()} ${response.url()}`,
      );
    }
  });
}

// Credentials as they show up in logged text: auth headers, bearer tokens,
// JWTs, cookie headers and credential query parameters. Order matters: the
// header rules run before the bare-token rules would split them.
const REDACTIONS: readonly (readonly [RegExp, string])[] = [
  [
    /(authorization["']?\s*[:=]\s*["']?)(\w+\s+)?[^\s"',;]+/gi,
    "$1$2[redacted]",
  ],
  [/\bbearer\s+(?!\[redacted\])[A-Za-z0-9._~+/=-]+/gi, "Bearer [redacted]"],
  [/\beyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*/g, "[redacted-jwt]"],
  [/(\b(?:set-)?cookie["']?\s*[:=]\s*["']?)[^\n"']*/gi, "$1[redacted]"],
  [
    /([?&](?:access_token|id_token|refresh_token|token|code|api[_-]?key|key|secret|password|signature)=)[^&#\s"']+/gi,
    "$1[redacted]",
  ],
];

/** `text` with every credential REDACTIONS recognises replaced. */
export function redact(text: unknown): string {
  return REDACTIONS.reduce(
    (out, [pattern, replacement]) => out.replace(pattern, replacement),
    String(text),
  );
}
