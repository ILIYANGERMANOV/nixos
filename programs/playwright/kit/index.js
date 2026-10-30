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
'use strict';

const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

// The video size and the viewport of every /qa page, so a probe sees the
// layout the recording will show.
const VIEWPORT = Object.freeze({ width: 960, height: 540 });

// Written by `qa-session start` into the run directory.
const SESSION_FILE = 'qa-session.json';

// The binding `qa-session` exposes for the controls a probe needs: saving
// the login and the wallet's.
const SESSION_BINDING = '__qaSession';

// The longest expectState waits without a reason: past a minute, a screen
// that has not come is almost always one that will not.
const MAX_WAIT_MS = 60_000;

/**
 * Attaches to the session browser of `runDir`.
 *
 * @returns {Promise<{ context, page, close: () => Promise<void>,
 *   rejectNext: (method: string, options?: { afterMs?: number }) => Promise<void>,
 *   waitForReceipt: (hash?: string, options?: { timeout?: number }) => Promise<object> }>}
 *   `rejectNext` and `waitForReceipt` are the session wallet's, as
 *   `installWallet` returns them; they fail when the session has no wallet.
 */
async function connect(runDir) {
  const { endpoint } = readSession(runDir);
  const browser = await chromium.connectOverCDP(endpoint);
  const context = browser.contexts().find((c) => c.pages().length > 0);
  if (!context) throw new Error('qa-kit: the session has no open page; restart it with qa-session');
  context.setDefaultTimeout(10_000);
  const page = context.pages()[0];
  const control = (op, args) =>
    page.evaluate(([binding, op, args]) => window[binding](op, args), [SESSION_BINDING, op, args]);
  return {
    context,
    page,
    close: async () => {
      const saved = await control('saveState', []);
      if (saved.kind === 'refused') console.error(`qa-kit: the session kept its previous login: ${saved.reason}`);
      await browser.close();
    },
    rejectNext: (method, options) => control('rejectNext', [method, options]),
    waitForReceipt: (hash, options) => control('waitForReceipt', [hash, options]),
  };
}

function readSession(runDir) {
  const file = path.join(runDir, SESSION_FILE);
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    throw new Error(`qa-kit: no session in ${runDir} (${error.code ?? error.message}); run qa-session start ${runDir}`);
  }
}

/**
 * Launches Chromium and opens a context on the saved login `auth` (a
 * storageState file), saving the login back to it on `close()` and when the
 * process gets SIGTERM or SIGINT, which is what `qa-node`'s deadline sends.
 * It launches the browser itself because Playwright's own signal handlers
 * would close it before the login could be read.
 *
 * @returns {Promise<{ browser, context, close: () => Promise<void> }>}
 */
async function openContext({ auth, ...contextOptions }) {
  const browser = await chromium.launch({ handleSIGTERM: false, handleSIGINT: false });
  const context = await browser.newContext({ viewport: VIEWPORT, ...contextOptions, storageState: auth });
  const onSignal = (signal) => {
    const code = signal === 'SIGINT' ? 130 : 143;
    saveState(context, auth)
      .catch((error) => console.error(`qa-kit: could not save ${auth}: ${error.message}`))
      .finally(() => process.exit(code));
  };
  process.once('SIGTERM', onSignal);
  process.once('SIGINT', onSignal);
  return {
    browser,
    context,
    close: async () => {
      process.off('SIGTERM', onSignal);
      process.off('SIGINT', onSignal);
      await saveState(context, auth);
      await browser.close();
    },
  };
}

/**
 * Writes the login of `context` to `file`, keeping the file it replaces as
 * `<file>.bak`. A state with no cookies is a lost login, not a newer one, so
 * it is refused and the old file stays.
 *
 * @returns {Promise<{ kind: 'saved' } | { kind: 'refused', reason: string }>}
 */
async function saveState(context, file) {
  const state = await context.storageState();
  if (state.cookies.length === 0) {
    const reason = 'the state has no cookies';
    console.error(`qa-kit: not saving ${file}: ${reason}; kept the previous one`);
    return { kind: 'refused', reason };
  }
  if (fs.existsSync(file)) fs.copyFileSync(file, `${file}.bak`);
  // Written beside the file and renamed over it, so a kill mid-write cannot
  // leave half a login behind.
  const tmp = `${file}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, file);
  return { kind: 'saved' };
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
 * @returns {Promise<{ kind: 'expected' } | { kind: 'failed', name: string, text: string }>}
 */
async function expectState(expected, failures = {}, { timeout = 10_000, reason } = {}) {
  if ((timeout === 0 || timeout > MAX_WAIT_MS) && !reason) {
    console.error(`qa-kit: capped expectState's ${timeout === 0 ? 'unbounded' : `${timeout} ms`} timeout to ${MAX_WAIT_MS} ms; pass { reason } to wait longer`);
    timeout = MAX_WAIT_MS;
  }
  const outcomes = [['expected', expected], ...Object.entries(failures)];
  const any = outcomes.map(([, locator]) => locator).reduce((all, locator) => all.or(locator));
  await any.first().waitFor({ state: 'visible', timeout });
  for (const [name, locator] of outcomes) {
    const first = locator.first();
    if (!(await first.isVisible())) continue;
    return name === 'expected' ? { kind: 'expected' } : { kind: 'failed', name, text: await first.innerText() };
  }
  // Rare: the state appeared and vanished between the wait and the check.
  throw new Error('qa-kit: expectState saw a state that vanished before it could be read');
}

/**
 * Appends what the pages of `context` log - console messages, uncaught
 * errors, failed requests and HTTP error responses - to `file`, one line each,
 * every line redacted. The only console capture a /qa script needs.
 */
function capture(context, file) {
  const write = (line) => fs.appendFileSync(file, `${redact(line)}\n`);
  context.on('console', (message) => write(`console.${message.type()} ${message.text()}`));
  context.on('weberror', (error) => write(`pageerror ${error.error().message}`));
  context.on('requestfailed', (request) =>
    write(`requestfailed ${request.method()} ${request.url()} ${request.failure()?.errorText ?? ''}`),
  );
  context.on('response', (response) => {
    if (response.status() >= 400) write(`http ${response.status()} ${response.request().method()} ${response.url()}`);
  });
}

// Credentials as they show up in logged text: auth headers, bearer tokens,
// JWTs, cookie headers and credential query parameters. Order matters: the
// header rules run before the bare-token rules would split them.
const REDACTIONS = [
  [/(authorization["']?\s*[:=]\s*["']?)(\w+\s+)?[^\s"',;]+/gi, '$1$2[redacted]'],
  [/\bbearer\s+(?!\[redacted\])[A-Za-z0-9._~+/=-]+/gi, 'Bearer [redacted]'],
  [/\beyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*/g, '[redacted-jwt]'],
  [/(\b(?:set-)?cookie["']?\s*[:=]\s*["']?)[^\n"']*/gi, '$1[redacted]'],
  [/([?&](?:access_token|id_token|refresh_token|token|code|api[_-]?key|key|secret|password|signature)=)[^&#\s"']+/gi, '$1[redacted]'],
];

/** `text` with every credential REDACTIONS recognises replaced. */
function redact(text) {
  return REDACTIONS.reduce((out, [pattern, replacement]) => out.replace(pattern, replacement), String(text));
}

module.exports = { connect, openContext, saveState, expectState, capture, redact, VIEWPORT, MAX_WAIT_MS, SESSION_FILE, SESSION_BINDING };
