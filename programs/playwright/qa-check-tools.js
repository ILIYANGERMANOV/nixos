// checks.qa, part two, run by `qa-node`: the evidence tools and the shared
// session. `qa-mp4` trims a static lead-in and nothing later, `qa-frames`
// lays N labelled frames out as one sheet, `qa-node` ends a hung script at
// its deadline, a saved login survives a run that rotates it, whether the
// run closes, stops or is killed, `qa-session` keeps one browser
// whose page state survives between separate probe processes, with the
// wallet's decline reachable from a probe and credentials redacted in its
// console log, and `expectState` returns at the first error screen. No
// network: the app is a server on loopback.
'use strict';

const assert = require('assert');
const { execFile, spawn } = require('child_process');
const fs = require('fs');
const http = require('http');
const path = require('path');
const { promisify } = require('util');
const { chromium } = require('playwright');
const { generatePrivateKey } = require('viem/accounts');
const { expectState, redact, MAX_WAIT_MS } = require('qa-kit');

const run = promisify(execFile);
const work = process.argv[2];
const SEPOLIA = 11155111;

async function main() {
  // A minute of waiting, so it runs alongside the rest.
  const waitCap = checkWaitCap();
  await checkLeadInTrim();
  await checkContactSheet();
  checkRedact();
  await checkExpectState();
  await checkDeadline();
  await checkLoginSaved();
  await checkSession();
  await checkSessionSavesLogin();
  await waitCap;
  console.log('qa: evidence tools and session ok');
}

// Given a recording that sat on one screen for 10 s before anything moved,
// then moved for 2 s, then sat still for 3 s, when it is transcoded, then
// its first change is within 1 s and the later still stretch is kept whole.
async function checkLeadInTrim() {
  const webm = path.join(work, 'lead-in.webm');
  await synthesise(webm, 'color=c=gray:s=320x240:r=25:d=10[a];testsrc=s=320x240:r=25:d=2[b];color=c=blue:s=320x240:r=25:d=3[c];[a][b][c]concat=n=3');
  const mp4 = path.join(work, 'lead-in.mp4');
  const { stdout } = await run('qa-mp4', [webm, mp4]);
  assert.match(stdout, /trimmed a 9\.50s static lead-in/);
  assert.ok((await leadingFreeze(mp4)) <= 1, 'the first change is more than 1 s in');
  const duration = await durationOf(mp4);
  assert.ok(duration > 5 && duration < 6, `expected 0.5 + 2 + 3 s, got ${duration}`);

  // A recording that moves from the start loses nothing.
  const moving = path.join(work, 'moving.webm');
  await synthesise(moving, 'testsrc=s=320x240:r=25:d=2[a];color=c=blue:s=320x240:r=25:d=3[b];[a][b]concat=n=2');
  const movingMp4 = path.join(work, 'moving.mp4');
  assert.match((await run('qa-mp4', [moving, movingMp4])).stdout, /trimmed a 0s/);
  assert.ok((await durationOf(movingMp4)) > 4.9);
}

// Seconds until the first frame that differs from frame 0.
async function leadingFreeze(video) {
  const { stderr } = await run('ffmpeg', ['-hide_banner', '-nostats', '-i', video, '-vf', 'freezedetect=d=0.1', '-f', 'null', '-']);
  const start = stderr.match(/freeze_start: ([\d.]+)/);
  if (!start || Number(start[1]) > 0) return 0;
  return Number(stderr.match(/freeze_end: ([\d.]+)/)[1]);
}

// Given 4 timestamps, the sheet is 3 tiles by 2 at 480 px a tile; given 2,
// it is 2 by 1. A timestamp past the end gets the last frame, not an error.
async function checkContactSheet() {
  const video = path.join(work, 'lead-in.mp4');
  const sheet = (times) => run('qa-frames', [video, times, path.join(work, `sheet-${times}.png`)]);
  await sheet('0.2,1,2,3');
  assert.deepStrictEqual(await sizeOf(path.join(work, 'sheet-0.2,1,2,3.png')), [3 * 480 + 2 * 4, 2 * 360 + 4]);
  await sheet('0.2,1');
  assert.deepStrictEqual(await sizeOf(path.join(work, 'sheet-0.2,1.png')), [2 * 480 + 4, 360]);
  const { stderr } = await sheet('0.2,99');
  assert.match(stderr, /99 s is past the end .*; using its last frame \(5\.\d\d s\)/);
  assert.deepStrictEqual(await sizeOf(path.join(work, 'sheet-0.2,99.png')), [2 * 480 + 4, 360]);
  await assert.rejects(sheet('1;rm'), /not a time in seconds/);
}

// Whatever the token, a bearer header, a JWT, a cookie header and a
// credential query parameter never survive redaction; plain text does.
function checkRedact() {
  const random = seeded(42);
  for (let i = 0; i < 200; i += 1) {
    const token = random.token();
    const jwt = `eyJ${random.token()}.eyJ${random.token()}.${random.token()}`;
    const text = [
      `Authorization: Bearer ${token}`,
      `{"authorization":"Bearer ${token}"}`,
      `fetch failed with bearer ${token}`,
      `session ${jwt}`,
      `Cookie: sid=${token}; theme=dark`,
      `set-cookie: sid=${token}; Path=/; HttpOnly`,
      `GET https://api.test/me?access_token=${token}&page=2`,
    ].join('\n');
    const out = redact(text);
    assert.ok(!out.includes(token), `a token survived: ${out}`);
    assert.ok(!out.includes(jwt.split('.')[1]), `a JWT survived: ${out}`);
  }
  assert.strictEqual(redact('Swap 1.5 ETH for USDC at block 42'), 'Swap 1.5 ETH for USDC at block 42');
}

// A deterministic token source: base64url-ish strings of 16-48 characters.
function seeded(seed) {
  let state = seed;
  const next = () => {
    state = (state * 1103515245 + 12345) % 2 ** 31;
    return state;
  };
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  return { token: () => Array.from({ length: 16 + (next() % 33) }, () => alphabet[next() % alphabet.length]).join('') };
}

// Given an error that shows at once and a success that would show after 5 s,
// expectState returns the error well before the success; given only the
// success, it returns that; given neither, it throws at its timeout.
async function checkExpectState() {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const show = (id, ms) => `<script>setTimeout(() => { const p = document.createElement('p'); p.id = '${id}'; p.textContent = '${id} shown'; document.body.append(p); }, ${ms});</script>`;

  await page.setContent(`<body>${show('done', 5000)}${show('error', 200)}</body>`);
  const started = Date.now();
  const failed = await expectState(page.locator('#done'), { error: page.locator('#error') }, { timeout: 10_000 });
  assert.deepStrictEqual(failed, { kind: 'failed', name: 'error', text: 'error shown' });
  assert.ok(Date.now() - started < 2_000, 'expectState waited for the success after the error showed');

  await page.setContent(`<body>${show('done', 100)}</body>`);
  assert.deepStrictEqual(await expectState(page.locator('#done'), { error: page.locator('#error') }), { kind: 'expected' });

  await page.setContent('<body></body>');
  await assert.rejects(expectState(page.locator('#done'), { error: page.locator('#error') }, { timeout: 300 }), /Timeout/);
  await browser.close();
}

// Given an expectState asked to wait two minutes, or forever, with no
// reason, it gives up at the cap; given a reason, the long wait stands.
async function checkWaitCap() {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.setContent(`<body><script>setTimeout(() => { const p = document.createElement('p'); p.id = 'late'; document.body.append(p); p.textContent = 'late'; }, ${MAX_WAIT_MS + 3_000});</script></body>`);
  const capped = async (timeout) => {
    const started = Date.now();
    await assert.rejects(expectState(page.locator('#never'), {}, { timeout }), new RegExp(`Timeout ${MAX_WAIT_MS}ms`));
    assert.ok(Date.now() - started < MAX_WAIT_MS + 2_000, `a ${timeout} ms wait ran past the cap`);
  };
  const [, , reasoned] = await Promise.all([
    capped(120_000),
    capped(0),
    expectState(page.locator('#late'), {}, { timeout: 120_000, reason: 'the test page shows it after the cap' }),
  ]);
  assert.deepStrictEqual(reasoned, { kind: 'expected' });
  await browser.close();
}

// Given a script that hangs, qa-node ends it at QA_NODE_TIMEOUT with 124.
async function checkDeadline() {
  const started = Date.now();
  await assert.rejects(
    run('qa-node', ['-e', 'setTimeout(() => {}, 60_000)'], { env: { ...process.env, QA_NODE_TIMEOUT: '1' } }),
    (error) => error.code === 124,
  );
  assert.ok(Date.now() - started < 10_000, 'qa-node outlived its deadline');
}

// Given a saved login the app rotates on every visit, when a script on
// openContext closes, hangs and meets qa-node's deadline, or is interrupted
// with SIGINT, then the file holds the rotated login and `.bak` the one before; when the app logs out,
// then the empty state is refused and the last login stays.
async function checkLoginSaved() {
  const app = await loginApp();
  const auth = path.join(work, 'auth.json');
  fs.writeFileSync(auth, JSON.stringify(loginState(app, 'v0')));
  const script = (name, route, tail) => {
    const file = writeScript(name, `const { context, close } = await openContext({ auth: process.argv[2] });
  const page = await context.newPage();
  await page.goto(${JSON.stringify(`${app.url}${route}`)});
  ${tail}`);
    return run('qa-node', [file, auth], { env: { ...process.env, QA_NODE_TIMEOUT: '5' } });
  };

  await script('login-close', 'rotate', 'await close();');
  assert.strictEqual(sid(auth), 'v1');
  assert.strictEqual(sid(`${auth}.bak`), 'v0');

  await assert.rejects(script('login-hang', 'rotate', 'await new Promise(() => {});'), (error) => error.code === 124);
  assert.strictEqual(sid(auth), 'v2', 'the deadline lost the rotated login');
  assert.strictEqual(sid(`${auth}.bak`), 'v1');

  const interrupted = await interrupt(writeScript('login-interrupt', `const { context } = await openContext({ auth: process.argv[2] });
  const page = await context.newPage();
  await page.goto(${JSON.stringify(`${app.url}rotate`)});
  console.log('ready');
  await new Promise(() => {});`), auth);
  assert.strictEqual(interrupted, 130);
  assert.strictEqual(sid(auth), 'v3', 'SIGINT lost the rotated login');
  assert.strictEqual(sid(`${auth}.bak`), 'v2');

  const { stderr } = await script('login-out', 'logout', 'await close();');
  assert.match(stderr, /not saving .*auth\.json: the state has no cookies; kept the previous one/);
  assert.strictEqual(sid(auth), 'v3');
  app.close();
}

// Runs `file` under qa-node, sends it SIGINT once it prints `ready`, as
// Ctrl-C does, and resolves to its exit code.
function interrupt(file, ...args) {
  return new Promise((resolve, reject) => {
    const child = spawn('qa-node', [file, ...args], { env: { ...process.env, QA_NODE_TIMEOUT: '30' }, stdio: ['ignore', 'pipe', 'inherit'] });
    child.stdout.on('data', (chunk) => {
      if (chunk.toString().includes('ready')) child.kill('SIGINT');
    });
    child.on('error', reject);
    child.on('exit', (code, signal) => resolve(code ?? signal));
  });
}

// Given a session started on a saved login, when a probe rotates it and
// closes, then the file holds the rotated login; when a later probe rotates
// it again and the session stops, then stop saves that one too.
async function checkSessionSavesLogin() {
  const app = await loginApp();
  const auth = path.join(work, 'session-auth.json');
  fs.writeFileSync(auth, JSON.stringify(loginState(app, 'v0')));
  const runDir = path.join(work, 'session-login-run');
  await run('qa-session', ['start', runDir, '--url', app.url, '--storage-state', auth]);
  const probe = (body) => {
    const file = writeScript('probe-login', `const session = await connect(process.argv[2]);
  ${body}`);
    return run('qa-node', [file, runDir]);
  };

  await probe(`await session.page.goto(${JSON.stringify(`${app.url}rotate`)}); await session.close();`);
  assert.strictEqual(sid(auth), 'v1');
  assert.strictEqual(sid(`${auth}.bak`), 'v0');

  await probe(`await session.page.goto(${JSON.stringify(`${app.url}rotate`)}); process.exit(0);`);
  assert.strictEqual(sid(auth), 'v1');
  await run('qa-session', ['stop', runDir]);
  assert.strictEqual(sid(auth), 'v2', 'stop lost the rotated login');
  app.close();
}

// An app on loopback whose `/rotate` replaces the `sid` cookie with the next
// version, as a refresh-token rotation does, and whose `/logout` clears it.
async function loginApp() {
  let version = 0;
  return listen((req, res) => {
    if (req.url === '/rotate') {
      version += 1;
      res.setHeader('Set-Cookie', `sid=v${version}; Path=/; HttpOnly`);
    } else if (req.url === '/logout') {
      res.setHeader('Set-Cookie', 'sid=; Path=/; Max-Age=0');
    }
    res.end('<!doctype html><p>app</p>');
  });
}

function loginState(app, version) {
  const cookie = { name: 'sid', value: version, domain: new URL(app.url).hostname, path: '/', expires: -1, httpOnly: true, secure: false, sameSite: 'Lax' };
  return { cookies: [cookie], origins: [] };
}

function sid(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8')).cookies.find((c) => c.name === 'sid')?.value;
}

// Given a session started on an app whose first response outlasts the 10 s
// step timeout, as a dev server's first compile does, then it starts; when
// one probe process sets page state and a second attaches, then the second
// sees it, in the same browser process;
// the wallet in the session declines when a probe says so; and what the page
// logs reaches the console log with its credentials redacted.
async function checkSession() {
  const token = seeded(7).token();
  const jwt = `eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJxYSJ9.${seeded(9).token()}`;
  const app = await serve(`<!doctype html><title>app</title><p>app</p><script>
    window.found = [];
    window.addEventListener('eip6963:announceProvider', (e) => window.found.push(e.detail));
    window.dispatchEvent(new Event('eip6963:requestProvider'));
  </script>`, { firstResponseDelayMs: 12_000 });
  const runDir = path.join(work, 'session-run');
  const keyFile = path.join(work, 'session-key');
  fs.writeFileSync(keyFile, `${generatePrivateKey()}\n`, { mode: 0o600 });
  const env = { ...process.env, QA_EVM_KEY_FILE: keyFile };

  const started = await run('qa-session', ['start', runDir, '--url', app.url, '--chain-id', String(SEPOLIA)], { env });
  assert.match(started.stdout, /qa-session: http:\/\/127\.0\.0\.1:\d+/);
  const { pid } = JSON.parse(fs.readFileSync(path.join(runDir, 'qa-session.json'), 'utf8'));
  await assert.rejects(run('qa-session', ['start', runDir], { env }), /already running/);

  const probe = async (name, body) => {
    const file = writeScript(name, `const session = await connect(process.argv[2]);
  const { page } = session;
  ${body}
  await session.close();`);
    return (await run('qa-node', [file, runDir])).stdout.trim();
  };

  await probe('probe-a', `await page.evaluate(() => { window.mark = 'set by a'; });
  console.log(await page.evaluate(([t, j]) => {
    console.log('Authorization: Bearer ' + t);
    console.log('session token ' + j);
    return 'logged';
  }, [${JSON.stringify(token)}, ${JSON.stringify(jwt)}]));`);
  assert.strictEqual(await probe('probe-b', 'console.log(await page.evaluate(() => window.mark));'), 'set by a');

  const declined = await probe('probe-c', `await session.rejectNext('personal_sign');
  console.log(await page.evaluate(async () => {
    const { provider } = window.found[0];
    const [address] = await provider.request({ method: 'eth_requestAccounts' });
    try {
      await provider.request({ method: 'personal_sign', params: ['0x68656c6c6f', address] });
      return 'signed';
    } catch (error) {
      return String(error.code);
    }
  }));`);
  assert.strictEqual(declined, '4001');

  const { pid: pidAfter } = JSON.parse(fs.readFileSync(path.join(runDir, 'qa-session.json'), 'utf8'));
  assert.strictEqual(pidAfter, pid, 'the session was relaunched');

  const log = fs.readFileSync(path.join(runDir, 'qa-session-console.log'), 'utf8');
  assert.match(log, /Bearer \[redacted\]/);
  assert.match(log, /\[redacted-jwt\]/);
  assert.ok(!log.includes(token) && !log.includes(jwt.split('.')[2]), `a credential reached the console log:\n${log}`);

  assert.match((await run('qa-session', ['stop', runDir])).stdout, /stopped/);
  assert.ok(!fs.existsSync(path.join(runDir, 'qa-session.json')), 'stop left the session file');
  assert.throws(() => process.kill(pid, 0), /ESRCH/, 'the session process outlived stop');
  app.close();
}

// Serves `html` on loopback; the first response waits `firstResponseDelayMs`.
async function serve(html, { firstResponseDelayMs = 0 } = {}) {
  let delayMs = firstResponseDelayMs;
  return listen((_req, res) => {
    setTimeout(() => res.end(html), delayMs);
    delayMs = 0;
  });
}

// An HTTP server on a free loopback port.
async function listen(handler) {
  const server = http.createServer(handler);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return { url: `http://127.0.0.1:${server.address().port}/`, close: () => server.close() };
}

// Writes `<work>/<name>.cjs`, a qa-node script running `body` in an async
// function with qa-kit's connect and openContext in scope, exiting 1 on a throw.
function writeScript(name, body) {
  const file = path.join(work, `${name}.cjs`);
  fs.writeFileSync(file, `const { connect, openContext } = require('qa-kit');
(async () => {
  ${body}
})().catch((error) => { console.error(error); process.exit(1); });
`);
  return file;
}

async function synthesise(out, graph) {
  await run('ffmpeg', ['-y', '-loglevel', 'error', '-filter_complex', graph, '-c:v', 'libvpx', '-b:v', '200k', out]);
}

async function durationOf(video) {
  const { stdout } = await run('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', video]);
  return Number(stdout.trim());
}

async function sizeOf(image) {
  const { stdout } = await run('ffprobe', ['-v', 'error', '-show_entries', 'stream=width,height', '-of', 'csv=p=0', image]);
  return stdout.trim().split(',').map(Number);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
