// `qa-session`: one headless Chromium that outlives the scripts driving it,
// so a probe reuses the logged-in page the last one left instead of
// relaunching, logging in and navigating again.
//
//   qa-session start <run-dir> [--url <url>] [--storage-state <file>]
//                    [--chain-id <n> [--rpc <url> [--forward-rpc <regex>]...]]
//   qa-session stop <run-dir>
//
// `start` returns once the page is open, having written the CDP endpoint to
// <run-dir>/qa-session.json; scripts attach with `require('qa-kit').connect`.
// `--chain-id` installs the QA Wallet (QA_EVM_KEY_FILE) in the session, which
// must be the process holding it: its signing lives in this process.
// `--storage-state` is the saved login, written back by every probe's
// `close()` and by `stop` (see qa-kit's saveState). Console
// output, page errors and failed requests go, redacted, to
// <run-dir>/qa-session-console.log. Unrecorded: the evidence run records its
// own context.
import { spawn } from "node:child_process";
import fs from "node:fs";
import net, { type AddressInfo } from "node:net";
import path from "node:path";
import { type BrowserContext, chromium } from "playwright";
import type { WalletChain, WalletControls } from "qa-wallet";
import {
  capture,
  readSession,
  SESSION_BINDING,
  SESSION_FILE,
  type SessionFile,
  type SessionSaveResult,
  STEP_TIMEOUT_MS,
  saveState,
  VIEWPORT,
} from "./index.js";

const USAGE = `usage: qa-session start <run-dir> [--url <url>] [--storage-state <file>]
                  [--chain-id <n> [--rpc <url> [--forward-rpc <regex>]...]]
       qa-session stop <run-dir>`;
const START_TIMEOUT_MS = 60_000;

type Options = {
  url?: string;
  storageState?: string;
  wallet: WalletChain | undefined;
};

async function main([command, runDir, ...args]: string[]): Promise<void> {
  if (!runDir) fail(USAGE);
  const dir = path.resolve(runDir);
  switch (command) {
    case "start":
      return start(dir, args);
    case "serve":
      return serve(dir, parseOptions(args));
    case "stop":
      return stop(dir);
    default:
      fail(USAGE);
  }
}

// Forks `serve` detached and waits for it to report the page open, so the
// caller never polls for readiness.
async function start(dir: string, args: string[]): Promise<void> {
  const running = runningSession(dir);
  if (running) {
    fail(
      `qa-session: already running (pid ${running.pid}); qa-session stop ${dir} first`,
    );
  }
  parseOptions(args);
  fs.mkdirSync(dir, { recursive: true });
  const log = fs.openSync(path.join(dir, "qa-session.log"), "a");
  const child = spawn(
    process.execPath,
    [import.meta.filename, "serve", dir, ...args],
    {
      detached: true,
      stdio: ["ignore", log, log, "ipc"],
    },
  );
  const endpoint = await new Promise<string>((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error("did not open the page in time")),
      START_TIMEOUT_MS,
    );
    child.once("message", (message) => {
      clearTimeout(timer);
      resolve((message as Pick<SessionFile, "endpoint">).endpoint);
    });
    child.once("exit", (code) => {
      clearTimeout(timer);
      reject(new Error(`exited with ${code}`));
    });
  }).catch((error: Error) =>
    fail(
      `qa-session: ${error.message}; see ${path.join(dir, "qa-session.log")}`,
    ),
  );
  child.disconnect();
  child.unref();
  console.log(
    `qa-session: ${endpoint} (pid ${child.pid}); console log ${path.join(dir, "qa-session-console.log")}`,
  );
}

function parseOptions(args: string[]): Options {
  const options: Omit<Options, "wallet"> = {};
  const forwardRpc: RegExp[] = [];
  let chainId: number | undefined;
  let rpcUrl: string | undefined;
  for (let i = 0; i < args.length; i += 2) {
    const [flag, value] = [args[i], args[i + 1]];
    if (!value) fail(`qa-session: ${flag} needs a value`);
    else if (flag === "--url") options.url = value;
    else if (flag === "--storage-state") options.storageState = value;
    else if (flag === "--chain-id") chainId = Number(value);
    else if (flag === "--rpc") rpcUrl = value;
    else if (flag === "--forward-rpc") forwardRpc.push(new RegExp(value));
    else fail(`qa-session: unknown option ${flag}\n${USAGE}`);
  }
  return { ...options, wallet: parseWallet(chainId, rpcUrl, forwardRpc) };
}

function parseWallet(
  chainId: number | undefined,
  rpcUrl: string | undefined,
  forwardRpc: RegExp[],
): WalletChain | undefined {
  if (chainId === undefined) {
    if (rpcUrl !== undefined || forwardRpc.length > 0) {
      fail(`qa-session: --rpc and --forward-rpc need --chain-id\n${USAGE}`);
    }
    return undefined;
  }
  if (!Number.isInteger(chainId)) fail("qa-session: --chain-id takes a number");
  if (rpcUrl !== undefined) return { chainId, rpcUrl, forwardRpc };
  if (forwardRpc.length > 0) {
    fail(`qa-session: --forward-rpc needs --rpc\n${USAGE}`);
  }
  return { chainId };
}

// The detached process: owns the browser until SIGTERM or the browser exits.
async function serve(
  dir: string,
  { url, storageState: stateArg, wallet }: Options,
): Promise<void> {
  const storageState = stateArg && path.resolve(stateArg);
  const port = await freePort();
  // Playwright's own SIGTERM handler would close the browser before shutdown
  // could save the login.
  const browser = await chromium.launch({
    args: [`--remote-debugging-port=${port}`],
    handleSIGTERM: false,
  });
  const context = await browser.newContext({
    viewport: VIEWPORT,
    ...(storageState ? { storageState } : {}),
  });
  context.setDefaultTimeout(STEP_TIMEOUT_MS);
  capture(context, path.join(dir, "qa-session-console.log"));
  // The session saves the login, not the probe: over CDP the probe's view of
  // this context reads no cookies.
  const save = async (): Promise<SessionSaveResult> =>
    storageState ? saveState(context, storageState) : { kind: "no-login" };
  const controls = wallet ? await walletControls(context, wallet) : {};
  await exposeControls(context, { saveState: save, ...controls });
  const page = await context.newPage();
  // A dev server compiles a route on its first hit, which outlasts the 10 s
  // step timeout; the load gets the whole start budget instead.
  if (url) await page.goto(url, { timeout: START_TIMEOUT_MS });

  const sessionFile = path.join(dir, SESSION_FILE);
  const endpoint = `http://127.0.0.1:${port}`;
  const session: SessionFile = { endpoint, pid: process.pid };
  fs.writeFileSync(sessionFile, `${JSON.stringify(session)}\n`);
  const shutdown = async () => {
    fs.rmSync(sessionFile, { force: true });
    await save().catch((error: Error) =>
      console.error(
        `qa-session: could not save ${storageState}: ${error.message}`,
      ),
    );
    await browser.close();
    process.exit(0);
  };
  process.on("SIGTERM", shutdown);
  browser.on("disconnected", () => {
    fs.rmSync(sessionFile, { force: true });
    process.exit(1);
  });
  process.send?.({ endpoint });
  process.disconnect();
}

// The controls a probe calls from its page through the binding. The arguments
// come from qa-kit's `connect`, which types them.
async function exposeControls(
  context: BrowserContext,
  controls: Record<string, (...args: never[]) => unknown>,
): Promise<void> {
  await context.exposeBinding(
    SESSION_BINDING,
    (_source, op: string, args: never[]) => {
      const control = Object.hasOwn(controls, op) ? controls[op] : undefined;
      if (!control) throw new Error(`qa-session: unknown control ${op}`);
      return control(...args);
    },
  );
}

// The wallet's controls; signing stays in this process.
async function walletControls(
  context: BrowserContext,
  chain: WalletChain,
): Promise<WalletControls> {
  const keyFile = process.env.QA_EVM_KEY_FILE;
  if (!keyFile) {
    fail(
      "qa-session: --chain-id needs the wallet, and QA_EVM_KEY_FILE is not set",
    );
  }
  const { installWallet } = await import("qa-wallet");
  const { rejectNext, waitForReceipt } = await installWallet(context, {
    keyFile,
    ...chain,
  });
  return { rejectNext, waitForReceipt };
}

async function stop(dir: string): Promise<void> {
  const running = runningSession(dir);
  if (!running) {
    console.log("qa-session: no session running");
    return;
  }
  process.kill(running.pid, "SIGTERM");
  for (let waited = 0; isAlive(running.pid); waited += 100) {
    if (waited > 10_000) fail(`qa-session: pid ${running.pid} did not stop`);
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  console.log("qa-session: stopped");
}

function runningSession(dir: string): SessionFile | null {
  const session = readSession(dir);
  return session && isAlive(session.pid) ? session : null;
}

function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = net.createServer().once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address() as AddressInfo;
      server.close(() => resolve(port));
    });
  });
}

function fail(message: string): never {
  console.error(message);
  process.exit(1);
}

main(process.argv.slice(2)).catch((error: Error) =>
  fail(`qa-session: ${error.message}`),
);
