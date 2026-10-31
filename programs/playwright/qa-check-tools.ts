// checks.qa, part two, run by `qa-node`: the evidence tools and the shared
// session. `qa-mp4` trims a static lead-in and nothing later, `qa-frames`
// lays N labelled frames out as one sheet, `qa-node` ends a hung script at
// its deadline, a saved login survives a run that rotates it, whether the
// run closes, stops or is killed, `qa-session` keeps one browser
// whose page state survives between separate probe processes, with the
// wallet's decline reachable from a probe and credentials redacted in its
// console log, that flags which cannot make a wallet and a corrupt session
// file stop it, and `expectState` returns at the first error screen. No
// network: the app is a server on loopback.
import assert from "node:assert";
import { execFile, spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { promisify } from "node:util";
import { chromium } from "playwright";
import { expectState, MAX_WAIT_MS, readSession, SESSION_FILE } from "qa-kit";
import { generatePrivateKey } from "viem/accounts";
import {
  DISCOVERY_SCRIPT,
  type Listening,
  listen,
  runCheck,
  SEPOLIA,
} from "./qa-check-lib.js";

const run = promisify(execFile);
const work = process.argv[2] ?? assert.fail("usage: qa-check-tools <work-dir>");

async function main(): Promise<void> {
  // A minute of waiting, so it runs alongside the rest.
  const waitCap = checkWaitCap();
  await checkLeadInTrim();
  await checkContactSheet();
  await checkExpectState();
  await checkDeadline();
  await checkLoginSaved();
  await checkSession();
  await checkSessionSavesLogin();
  await checkSessionRejectsWalletFlags();
  await checkSessionRefusesCorruptFile();
  await waitCap;
  console.log("qa: evidence tools and session ok");
}

// Given a recording that sat on one screen for 10 s before anything moved,
// then moved for 2 s, then sat still for 3 s, when it is transcoded, then
// its first change is within 1 s and the later still stretch is kept whole.
async function checkLeadInTrim(): Promise<void> {
  const webm = path.join(work, "lead-in.webm");
  await synthesise(
    webm,
    "color=c=gray:s=320x240:r=25:d=10[a];testsrc=s=320x240:r=25:d=2[b];color=c=blue:s=320x240:r=25:d=3[c];[a][b][c]concat=n=3",
  );
  const mp4 = path.join(work, "lead-in.mp4");
  const { stdout } = await run("qa-mp4", [webm, mp4]);
  assert.match(stdout, /trimmed a 9\.50s static lead-in/);
  assert.ok(
    (await leadingFreeze(mp4)) <= 1,
    "the first change is more than 1 s in",
  );
  const duration = await durationOf(mp4);
  assert.ok(
    duration > 5 && duration < 6,
    `expected 0.5 + 2 + 3 s, got ${duration}`,
  );

  // A recording that moves from the start loses nothing.
  const moving = path.join(work, "moving.webm");
  await synthesise(
    moving,
    "testsrc=s=320x240:r=25:d=2[a];color=c=blue:s=320x240:r=25:d=3[b];[a][b]concat=n=2",
  );
  const movingMp4 = path.join(work, "moving.mp4");
  assert.match(
    (await run("qa-mp4", [moving, movingMp4])).stdout,
    /trimmed a 0s/,
  );
  assert.ok((await durationOf(movingMp4)) > 4.9);
}

// Seconds until the first frame that differs from frame 0.
async function leadingFreeze(video: string): Promise<number> {
  const { stderr } = await run("ffmpeg", [
    "-hide_banner",
    "-nostats",
    "-i",
    video,
    "-vf",
    "freezedetect=d=0.1",
    "-f",
    "null",
    "-",
  ]);
  const start = stderr.match(/freeze_start: ([\d.]+)/);
  if (!start || Number(start[1]) > 0) return 0;
  return Number(stderr.match(/freeze_end: ([\d.]+)/)?.[1]);
}

// Given 4 timestamps, the sheet is 3 tiles by 2 at 480 px a tile; given 2,
// it is 2 by 1. A timestamp past the end gets the last frame, not an error.
async function checkContactSheet(): Promise<void> {
  const video = path.join(work, "lead-in.mp4");
  const sheet = (times: string) =>
    run("qa-frames", [video, times, path.join(work, `sheet-${times}.png`)]);
  await sheet("0.2,1,2,3");
  assert.deepStrictEqual(await sizeOf(path.join(work, "sheet-0.2,1,2,3.png")), [
    3 * 480 + 2 * 4,
    2 * 360 + 4,
  ]);
  await sheet("0.2,1");
  assert.deepStrictEqual(await sizeOf(path.join(work, "sheet-0.2,1.png")), [
    2 * 480 + 4,
    360,
  ]);
  const { stderr } = await sheet("0.2,99");
  assert.match(
    stderr,
    /99 s is past the end .*; using its last frame \(5\.\d\d s\)/,
  );
  assert.deepStrictEqual(await sizeOf(path.join(work, "sheet-0.2,99.png")), [
    2 * 480 + 4,
    360,
  ]);
  await assert.rejects(sheet("1;rm"), /not a time in seconds/);
}

// Given an error that shows at once and a success that would show after 5 s,
// expectState returns the error well before the success; given only the
// success, it returns that; given neither, it throws at its timeout.
async function checkExpectState(): Promise<void> {
  const browser = await chromium.launch();
  const page = await browser.newPage();

  await page.setContent(
    `<body>${showAfter("done", 5000)}${showAfter("error", 200)}</body>`,
  );
  const started = Date.now();
  const failed = await expectState(
    page.locator("#done"),
    { error: page.locator("#error") },
    { timeout: 10_000 },
  );
  assert.deepStrictEqual(failed, {
    kind: "failed",
    name: "error",
    text: "error shown",
  });
  assert.ok(
    Date.now() - started < 2_000,
    "expectState waited for the success after the error showed",
  );

  await page.setContent(`<body>${showAfter("done", 100)}</body>`);
  assert.deepStrictEqual(
    await expectState(page.locator("#done"), { error: page.locator("#error") }),
    { kind: "expected" },
  );

  await page.setContent("<body></body>");
  await assert.rejects(
    expectState(
      page.locator("#done"),
      { error: page.locator("#error") },
      { timeout: 300 },
    ),
    /Timeout/,
  );
  await browser.close();
}

// A script adding `<p id="id">id shown</p>` to the page after `ms`.
function showAfter(id: string, ms: number): string {
  return `<script>setTimeout(() => { const p = document.createElement('p'); p.id = '${id}'; p.textContent = '${id} shown'; document.body.append(p); }, ${ms});</script>`;
}

// Given an expectState asked to wait two minutes, or forever, with no
// reason, it gives up at the cap; given a reason, the long wait stands.
async function checkWaitCap(): Promise<void> {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.setContent(
    `<body>${showAfter("late", MAX_WAIT_MS + 3_000)}</body>`,
  );
  const capped = async (timeout: number) => {
    const started = Date.now();
    await assert.rejects(
      expectState(page.locator("#never"), {}, { timeout }),
      new RegExp(`Timeout ${MAX_WAIT_MS}ms`),
    );
    assert.ok(
      Date.now() - started < MAX_WAIT_MS + 2_000,
      `a ${timeout} ms wait ran past the cap`,
    );
  };
  const [, , reasoned] = await Promise.all([
    capped(120_000),
    capped(0),
    expectState(
      page.locator("#late"),
      {},
      { timeout: 120_000, reason: "the test page shows it after the cap" },
    ),
  ]);
  assert.deepStrictEqual(reasoned, { kind: "expected" });
  await browser.close();
}

// Given a script that hangs, qa-node ends it at QA_NODE_TIMEOUT with 124.
async function checkDeadline(): Promise<void> {
  const started = Date.now();
  await assert.rejects(
    run("qa-node", ["-e", "setTimeout(() => {}, 60_000)"], {
      env: { ...process.env, QA_NODE_TIMEOUT: "1" },
    }),
    exitedWith(124),
  );
  assert.ok(Date.now() - started < 10_000, "qa-node outlived its deadline");
}

// Given a saved login the app rotates on every visit, when a script on
// openContext closes, hangs and meets qa-node's deadline, or is interrupted
// with SIGINT, then the file holds the rotated login and `.bak` the one
// before; when the app logs out, then the empty state is refused and the last
// login stays. `timeout` signals node and then its group, so a signal can
// arrive twice: `signalAgain` makes the second land right after the first,
// with the save still running.
async function checkLoginSaved(): Promise<void> {
  const app = await loginApp();
  const auth = path.join(work, "auth.json");
  fs.writeFileSync(auth, JSON.stringify(loginState(app, "v0")));
  const script = (name: string, route: string, tail: string) => {
    const file = writeScript(
      name,
      `const { context, close } = await openContext({ auth: process.argv[2] });
  const page = await context.newPage();
  await page.goto(${JSON.stringify(`${app.url}${route}`)});
  ${tail}`,
    );
    return run("qa-node", [file, auth], {
      env: { ...process.env, QA_NODE_TIMEOUT: "5" },
    });
  };

  await script("login-close", "rotate", "await close();");
  assert.strictEqual(sid(auth), "v1");
  assert.strictEqual(sid(`${auth}.bak`), "v0");

  const signalAgain = (signal: NodeJS.Signals) =>
    `process.once('${signal}', () => process.kill(process.pid, '${signal}'));`;
  await assert.rejects(
    script(
      "login-hang",
      "rotate",
      `${signalAgain("SIGTERM")} await new Promise(() => {});`,
    ),
    exitedWith(124),
  );
  assert.strictEqual(sid(auth), "v2", "the deadline lost the rotated login");
  assert.strictEqual(sid(`${auth}.bak`), "v1");

  const interrupted = await interrupt(
    writeScript(
      "login-interrupt",
      `const { context } = await openContext({ auth: process.argv[2] });
  const page = await context.newPage();
  await page.goto(${JSON.stringify(`${app.url}rotate`)});
  ${signalAgain("SIGINT")}
  console.log('ready');
  await new Promise(() => {});`,
    ),
    auth,
  );
  assert.strictEqual(interrupted, 130);
  assert.strictEqual(sid(auth), "v3", "SIGINT lost the rotated login");
  assert.strictEqual(sid(`${auth}.bak`), "v2");

  const { stderr } = await script("login-out", "logout", "await close();");
  assert.match(
    stderr,
    /not saving .*auth\.json: the state has no cookies; kept the previous one/,
  );
  assert.strictEqual(sid(auth), "v3");
  app.close();
}

function exitedWith(code: number): (error: unknown) => boolean {
  return (error) => (error as { code?: number }).code === code;
}

// Runs `file` under qa-node, sends it SIGINT once it prints `ready`, as
// Ctrl-C does, and resolves to its exit code.
function interrupt(
  file: string,
  ...args: string[]
): Promise<number | NodeJS.Signals | null> {
  return new Promise((resolve, reject) => {
    const child = spawn("qa-node", [file, ...args], {
      env: { ...process.env, QA_NODE_TIMEOUT: "30" },
      stdio: ["ignore", "pipe", "inherit"],
    });
    child.stdout.on("data", (chunk) => {
      if (chunk.toString().includes("ready")) child.kill("SIGINT");
    });
    child.on("error", reject);
    child.on("exit", (code, signal) => resolve(code ?? signal));
  });
}

// Given a session started on a saved login, when a probe rotates it and
// closes, then the file holds the rotated login; when a later probe rotates
// it again and the session stops, then stop saves that one too.
async function checkSessionSavesLogin(): Promise<void> {
  const app = await loginApp();
  const auth = path.join(work, "session-auth.json");
  fs.writeFileSync(auth, JSON.stringify(loginState(app, "v0")));
  const runDir = path.join(work, "session-login-run");
  await run("qa-session", [
    "start",
    runDir,
    "--url",
    app.url,
    "--storage-state",
    auth,
  ]);
  const probe = (body: string) => {
    const file = writeScript(
      "probe-login",
      `const session = await connect(process.argv[2]);
  ${body}`,
    );
    return run("qa-node", [file, runDir]);
  };

  await probe(
    `await session.page.goto(${JSON.stringify(`${app.url}rotate`)}); await session.close();`,
  );
  assert.strictEqual(sid(auth), "v1");
  assert.strictEqual(sid(`${auth}.bak`), "v0");

  await probe(
    `await session.page.goto(${JSON.stringify(`${app.url}rotate`)}); process.exit(0);`,
  );
  assert.strictEqual(sid(auth), "v1");
  await run("qa-session", ["stop", runDir]);
  assert.strictEqual(sid(auth), "v2", "stop lost the rotated login");
  app.close();
}

// An app on loopback whose `/rotate` replaces the `sid` cookie with the next
// version, as a refresh-token rotation does, and whose `/logout` clears it.
async function loginApp(): Promise<Listening> {
  let version = 0;
  return listen((req, res) => {
    if (req.url === "/rotate") {
      version += 1;
      res.setHeader("Set-Cookie", `sid=v${version}; Path=/; HttpOnly`);
    } else if (req.url === "/logout") {
      res.setHeader("Set-Cookie", "sid=; Path=/; Max-Age=0");
    }
    res.end("<!doctype html><p>app</p>");
  });
}

function loginState(app: Listening, version: string): unknown {
  const cookie = {
    name: "sid",
    value: version,
    domain: new URL(app.url).hostname,
    path: "/",
    expires: -1,
    httpOnly: true,
    secure: false,
    sameSite: "Lax",
  };
  return { cookies: [cookie], origins: [] };
}

function sid(file: string): string | undefined {
  const state: { cookies: { name: string; value: string }[] } = JSON.parse(
    fs.readFileSync(file, "utf8"),
  );
  return state.cookies.find((c) => c.name === "sid")?.value;
}

// Given a session started on an app whose first response outlasts the 10 s
// step timeout, as a dev server's first compile does, then it starts; when
// one probe process sets page state and a second attaches, then the second
// sees it, in the same browser process; the wallet in the session declines
// when a probe says so; and what the page logs reaches the console log with
// its credentials redacted.
async function checkSession(): Promise<void> {
  const token = "tQ7x-Lm2vZ9bK4wR_c8Y";
  const jwtSignature = "pH3nD6sF_j1Gy5Xq-a0T";
  const jwt = `eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJxYSJ9.${jwtSignature}`;
  const app = await serve(
    `<!doctype html><title>app</title><p>app</p>${DISCOVERY_SCRIPT}`,
    12_000,
  );
  const runDir = path.join(work, "session-run");
  const keyFile = path.join(work, "session-key");
  fs.writeFileSync(keyFile, `${generatePrivateKey()}\n`, { mode: 0o600 });
  const env = { ...process.env, QA_EVM_KEY_FILE: keyFile };

  const started = await run(
    "qa-session",
    ["start", runDir, "--url", app.url, "--chain-id", String(SEPOLIA)],
    { env },
  );
  assert.match(started.stdout, /qa-session: http:\/\/127\.0\.0\.1:\d+/);
  const pid = sessionPid(runDir);
  await assert.rejects(
    run("qa-session", ["start", runDir], { env }),
    /already running/,
  );

  const probe = async (name: string, body: string) => {
    const file = writeScript(
      name,
      `const session = await connect(process.argv[2]);
  const { page } = session;
  ${body}
  await session.close();`,
    );
    return (await run("qa-node", [file, runDir])).stdout.trim();
  };

  await probe(
    "probe-a",
    `await page.evaluate(() => { window.mark = 'set by a'; });
  console.log(await page.evaluate(([t, j]) => {
    console.log('Authorization: Bearer ' + t);
    console.log('session token ' + j);
    return 'logged';
  }, [${JSON.stringify(token)}, ${JSON.stringify(jwt)}]));`,
  );
  assert.strictEqual(
    await probe(
      "probe-b",
      "console.log(await page.evaluate(() => window.mark));",
    ),
    "set by a",
  );

  const declined = await probe(
    "probe-c",
    `await session.rejectNext('personal_sign');
  console.log(await page.evaluate(async () => {
    const { provider } = window.found[0];
    const [address] = await provider.request({ method: 'eth_requestAccounts' });
    try {
      await provider.request({ method: 'personal_sign', params: ['0x68656c6c6f', address] });
      return 'signed';
    } catch (error) {
      return String(error.code);
    }
  }));`,
  );
  assert.strictEqual(declined, "4001");

  assert.strictEqual(sessionPid(runDir), pid, "the session was relaunched");

  const log = fs.readFileSync(
    path.join(runDir, "qa-session-console.log"),
    "utf8",
  );
  assert.match(log, /Bearer \[redacted\]/);
  assert.match(log, /\[redacted-jwt\]/);
  assert.ok(
    !log.includes(token) && !log.includes(jwtSignature),
    `a credential reached the console log:\n${log}`,
  );

  assert.match((await run("qa-session", ["stop", runDir])).stdout, /stopped/);
  assert.ok(
    !fs.existsSync(path.join(runDir, SESSION_FILE)),
    "stop left the session file",
  );
  assert.throws(
    () => process.kill(pid, 0),
    /ESRCH/,
    "the session process outlived stop",
  );
  app.close();
}

// Given flags that cannot make a wallet, when a session starts, then it fails
// with a usage error before anything launches, the run directory included.
async function checkSessionRejectsWalletFlags(): Promise<void> {
  const rpc = ["--rpc", "http://rpc.test/"];
  const forward = ["--forward-rpc", "rpc"];
  const chain = ["--chain-id", String(SEPOLIA)];
  const cases: [string[], RegExp][] = [
    [rpc, /--rpc and --forward-rpc need --chain-id/],
    [forward, /--rpc and --forward-rpc need --chain-id/],
    [[...rpc, ...forward], /--rpc and --forward-rpc need --chain-id/],
    [[...chain, ...forward], /--forward-rpc needs --rpc/],
    [[...chain, "--rpc", ""], /--rpc needs a value/],
  ];
  const runDir = path.join(work, "bad-flags-run");
  for (const [flags, usage] of cases) {
    await assert.rejects(run("qa-session", ["start", runDir, ...flags]), usage);
    assert.ok(!fs.existsSync(runDir), `started with ${flags.join(" ")}`);
  }
}

// Given a session file that holds no session, then neither stop nor start
// reads that as none running: its browser may be alive, and a new one would
// leak it.
async function checkSessionRefusesCorruptFile(): Promise<void> {
  const runDir = path.join(work, "corrupt-run");
  const file = path.join(runDir, SESSION_FILE);
  fs.mkdirSync(runDir);
  fs.writeFileSync(file, '{"endpoint":"http://127');
  for (const command of ["stop", "start"]) {
    await assert.rejects(run("qa-session", [command, runDir]), /cannot read/);
  }
  assert.ok(fs.existsSync(file), "the session file was replaced");
}

function sessionPid(runDir: string): number {
  const session = readSession(runDir);
  assert.ok(session, "no session is running");
  return session.pid;
}

// Serves `html` on loopback; the first response waits `firstResponseDelayMs`.
function serve(html: string, firstResponseDelayMs: number): Promise<Listening> {
  let delayMs = firstResponseDelayMs;
  return listen((_req, res) => {
    setTimeout(() => res.end(html), delayMs);
    delayMs = 0;
  });
}

// Writes `<work>/<name>.cjs`, a qa-node script running `body` in an async
// function with qa-kit's connect and openContext in scope, exiting 1 on a throw.
function writeScript(name: string, body: string): string {
  const file = path.join(work, `${name}.cjs`);
  fs.writeFileSync(
    file,
    `const { connect, openContext } = require('qa-kit');
(async () => {
  ${body}
})().catch((error) => { console.error(error); process.exit(1); });
`,
  );
  return file;
}

async function synthesise(out: string, graph: string): Promise<void> {
  await run("ffmpeg", [
    "-y",
    "-loglevel",
    "error",
    "-filter_complex",
    graph,
    "-c:v",
    "libvpx",
    "-b:v",
    "200k",
    out,
  ]);
}

async function durationOf(video: string): Promise<number> {
  const { stdout } = await run("ffprobe", [
    "-v",
    "error",
    "-show_entries",
    "format=duration",
    "-of",
    "csv=p=0",
    video,
  ]);
  return Number(stdout.trim());
}

async function sizeOf(image: string): Promise<number[]> {
  const { stdout } = await run("ffprobe", [
    "-v",
    "error",
    "-show_entries",
    "stream=width,height",
    "-of",
    "csv=p=0",
    image,
  ]);
  return stdout.trim().split(",").map(Number);
}

runCheck(main);
