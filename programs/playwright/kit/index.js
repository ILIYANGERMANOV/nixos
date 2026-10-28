// `qa-kit`: what every /qa script shares, resolvable from any directory under
// `qa-node`.
//
//   const { connect, expectState, capture, VIEWPORT } = require('qa-kit');
//
// `connect(runDir)` attaches to the browser `qa-session start <runDir>` holds,
// with its logged-in page as it was left; `close()` detaches and leaves it
// open for the next probe. `expectState(expected, failures)` waits for
// whichever of the expected locator and the named failure locators appears
// first. `capture(context, file)` appends the context's console, page errors
// and failed requests to `file` with credentials redacted; `redact(text)` is
// that redaction.
'use strict';

const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

// The video size and the viewport of every /qa page, so a probe sees the
// layout the recording will show.
const VIEWPORT = Object.freeze({ width: 960, height: 540 });

// Written by `qa-session start` into the run directory.
const SESSION_FILE = 'qa-session.json';

// The binding `qa-session` exposes for the wallet controls a probe needs.
const SESSION_BINDING = '__qaSession';

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
    close: () => browser.close(),
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
 * Waits until the expected locator or one of the failure locators is visible,
 * whichever comes first, so a script stops at an error screen instead of
 * waiting out the timeout for a success that will not come.
 *
 * @param expected  a Locator for the success state
 * @param failures  { name: Locator } for each error state
 * @param options.timeout  milliseconds before neither appearing throws
 * @returns {Promise<{ kind: 'expected' } | { kind: 'failed', name: string, text: string }>}
 */
async function expectState(expected, failures = {}, { timeout = 10_000 } = {}) {
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

module.exports = { connect, expectState, capture, redact, VIEWPORT, SESSION_FILE, SESSION_BINDING };
