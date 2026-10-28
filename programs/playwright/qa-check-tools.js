// checks.qa, part two, run by `qa-node`: the evidence tools and the shared
// session. `qa-mp4` trims a static lead-in and nothing later, `qa-frames`
// lays N labelled frames out as one sheet, `qa-session` keeps one browser
// whose page state survives between separate probe processes, with the
// wallet's decline reachable from a probe and credentials redacted in its
// console log, and `expectState` returns at the first error screen. No
// network: the app is a server on loopback.
'use strict';

const assert = require('assert');
const { execFile } = require('child_process');
const fs = require('fs');
const http = require('http');
const path = require('path');
const { promisify } = require('util');
const { chromium } = require('playwright');
const { generatePrivateKey } = require('viem/accounts');
const { expectState, redact } = require('qa-kit');

const run = promisify(execFile);
const work = process.argv[2];
const SEPOLIA = 11155111;

async function main() {
  await checkLeadInTrim();
  await checkContactSheet();
  checkRedact();
  await checkExpectState();
  await checkSession();
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
// it is 2 by 1. A timestamp past the end is an error, not a short sheet.
async function checkContactSheet() {
  const video = path.join(work, 'lead-in.mp4');
  const sheet = (times) => run('qa-frames', [video, times, path.join(work, `sheet-${times}.png`)]);
  await sheet('0.2,1,2,3');
  assert.deepStrictEqual(await sizeOf(path.join(work, 'sheet-0.2,1,2,3.png')), [3 * 480 + 2 * 4, 2 * 360 + 4]);
  await sheet('0.2,1');
  assert.deepStrictEqual(await sizeOf(path.join(work, 'sheet-0.2,1.png')), [2 * 480 + 4, 360]);
  await assert.rejects(sheet('99'), /no frame at 99/);
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

// Given a session on an app page, when one probe process sets page state and
// a second attaches, then the second sees it, in the same browser process;
// the wallet in the session declines when a probe says so; and what the page
// logs reaches the console log with its credentials redacted.
async function checkSession() {
  const token = seeded(7).token();
  const jwt = `eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJxYSJ9.${seeded(9).token()}`;
  const app = await serve(`<!doctype html><title>app</title><p>app</p><script>
    window.found = [];
    window.addEventListener('eip6963:announceProvider', (e) => window.found.push(e.detail));
    window.dispatchEvent(new Event('eip6963:requestProvider'));
  </script>`);
  const runDir = path.join(work, 'session-run');
  const keyFile = path.join(work, 'session-key');
  fs.writeFileSync(keyFile, `${generatePrivateKey()}\n`, { mode: 0o600 });
  const env = { ...process.env, QA_EVM_KEY_FILE: keyFile };

  const started = await run('qa-session', ['start', runDir, '--url', app.url, '--chain-id', String(SEPOLIA)], { env });
  assert.match(started.stdout, /qa-session: http:\/\/127\.0\.0\.1:\d+/);
  const { pid } = JSON.parse(fs.readFileSync(path.join(runDir, 'qa-session.json'), 'utf8'));
  await assert.rejects(run('qa-session', ['start', runDir], { env }), /already running/);

  const probe = async (name, body) => {
    const file = path.join(work, `${name}.cjs`);
    fs.writeFileSync(file, `const { connect } = require('qa-kit');
(async () => {
  const session = await connect(process.argv[2]);
  const { page } = session;
  ${body}
  await session.close();
})().catch((error) => { console.error(error); process.exit(1); });\n`);
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

async function serve(html) {
  const server = http.createServer((_req, res) => res.end(html));
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return { url: `http://127.0.0.1:${server.address().port}/`, close: () => server.close() };
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
