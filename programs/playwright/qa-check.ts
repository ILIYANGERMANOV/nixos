// checks.qa, run by `qa-node`: the wallet helper against a synthetic dApp
// served from a Playwright route, with a key generated for this run, and a
// recorded video through `qa-mp4`, `waitForReceipt`, and the `qa-wallet`
// command. No network: the dApp origin never resolves, and the RPC is a fake
// JSON-RPC node on loopback.
import assert from "node:assert";
import { execFile, execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import {
  type Browser,
  type BrowserContext,
  chromium,
  type Page,
} from "playwright";
import { installWallet } from "qa-wallet";
import {
  type Address,
  decodeFunctionData,
  encodeFunctionResult,
  erc20Abi,
  type Hex,
  keccak256,
  toHex,
  verifyMessage,
  verifyTypedData,
} from "viem";
import { generatePrivateKey } from "viem/accounts";
import {
  DISCOVERY_SCRIPT,
  type Listening,
  listen,
  runCheck,
  SEPOLIA,
} from "./qa-check-lib.js";

type Announced = {
  info: { uuid: string; name: string; icon: string; rdns: string };
  provider: NonNullable<Window["ethereum"]>;
};

type RpcRequest = { id: number; method: string; params: unknown[] };

type RpcError = Error & { code: number };

type RpcOutcome = {
  result?: unknown;
  error?: { code: number; message: string };
};

declare global {
  interface Window {
    found: Announced[];
  }
}

const work = process.argv[2] ?? assert.fail("usage: qa-check <work-dir>");

const DAPP = "http://dapp.test/";
const RPC = "http://rpc.test/v1/";
const TOKEN: Address = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238";

const DAPP_HTML = `<!doctype html><title>dApp</title><p>dApp</p>${DISCOVERY_SCRIPT}`;

const TYPED_DATA = {
  domain: { name: "QA", version: "1", chainId: SEPOLIA },
  types: { Greeting: [{ name: "text", type: "string" }] },
  primaryType: "Greeting" as const,
  message: { text: "hello" },
};

async function main(): Promise<void> {
  const key = generatePrivateKey();
  const keyFile = path.join(work, "key");
  fs.writeFileSync(keyFile, `${key}\n`, { mode: 0o600 });
  const videos = path.join(work, "videos");

  const browser = await chromium.launch();
  const context = await browser.newContext({ recordVideo: { dir: videos } });
  const logs: string[] = [];
  context.on("console", (message) => logs.push(message.text()));
  await routeDapp(context);
  const { address, rejectNext } = await installWallet(context, {
    keyFile,
    chainId: SEPOLIA,
  });

  const page = await context.newPage();
  page.on("pageerror", (error) => logs.push(String(error)));
  await page.goto(DAPP);

  // Given the dApp asked for providers, when the wallet answered,
  // then the QA wallet answered, and nothing else did.
  const announced = await page.evaluate(() => window.found.map((d) => d.info));
  assert.deepStrictEqual(
    announced.map((i) => i.rdns),
    ["dev.qa.wallet"],
  );
  const [wallet] = announced;
  assert.ok(
    wallet?.uuid && wallet.name && wallet.icon.startsWith("data:image/"),
  );

  const call = providerCall(page);

  // Connect, as wagmi's injected connector does.
  assert.deepStrictEqual((await call("eth_requestAccounts")).result, [address]);
  assert.strictEqual((await call("eth_chainId")).result, "0xaa36a7");

  // personal_sign takes hex data and the address; the signature verifies.
  const message = "Sign in to the QA dApp";
  const hexMessage = toHex(message);
  const signature = (await call("personal_sign", [hexMessage, address]))
    .result as Hex;
  assert.ok(
    await verifyMessage({ address, message, signature }),
    "personal_sign does not verify",
  );

  const typed = (
    await call("eth_signTypedData_v4", [address, JSON.stringify(TYPED_DATA)])
  ).result as Hex;
  assert.ok(
    await verifyTypedData({ address, signature: typed, ...TYPED_DATA }),
    "typed data does not verify",
  );

  // Given the user will decline the next signature, when the dApp asks twice,
  // then the first is rejected as a user would and the second is signed.
  rejectNext("personal_sign");
  const declined = await call("personal_sign", [hexMessage, address]);
  assert.deepStrictEqual(declined.error, {
    code: 4001,
    message: "User rejected the request.",
  });
  const signedAfter = (await call("personal_sign", [hexMessage, address]))
    .result as Hex;
  assert.ok(
    await verifyMessage({ address, message, signature: signedAfter }),
    "the request after a decline is not signed",
  );

  // A decline is per method, and reaches a transaction before any network.
  rejectNext("eth_sendTransaction");
  assert.strictEqual(
    (await call("eth_signTypedData_v4", [address, JSON.stringify(TYPED_DATA)]))
      .result,
    typed,
  );
  assert.strictEqual(
    (await call("eth_sendTransaction", [{ to: address }])).error?.code,
    4001,
  );
  assert.strictEqual(
    (await call("eth_sendTransaction", [{ to: address }])).error?.code,
    4200,
  );
  assert.throws(() => rejectNext("eth_blockNumber"), /cannot decline/);

  // Without an rpcUrl, reads fail as unsupported instead of reaching a network.
  assert.strictEqual((await call("eth_blockNumber")).error?.code, 4200);
  assert.strictEqual(
    (await call("wallet_switchEthereumChain", [{ chainId: "0x1" }])).error
      ?.code,
    4902,
  );
  const mainnetTyped = {
    ...TYPED_DATA,
    domain: { ...TYPED_DATA.domain, chainId: 1 },
  };
  assert.strictEqual(
    (
      await call("eth_signTypedData_v4", [
        address,
        JSON.stringify(mainnetTyped),
      ])
    ).error?.code,
    4902,
  );

  // The key is nowhere the page can reach: not the DOM, not any global, not
  // the provider's source, not a console line.
  const pageText = await page.evaluate(() => {
    const parts = [document.documentElement.outerHTML];
    for (const name of Object.getOwnPropertyNames(window)) {
      try {
        const value = (window as unknown as Record<string, unknown>)[name];
        parts.push(
          typeof value === "function" ? String(value) : JSON.stringify(value),
        );
      } catch {
        // Cross-origin or cyclic globals are not where a key would hide.
      }
    }
    parts.push(...Object.values(window.found[0]?.provider ?? {}).map(String));
    return parts.join("\n");
  });
  const bareKey = key.slice(2);
  assert.ok(
    !pageText.includes(bareKey),
    "the private key is visible to the page",
  );
  assert.ok(
    !logs.join("\n").includes(bareKey),
    "the private key reached a console line",
  );

  const video = page.video();
  assert.ok(video, "the page is not being recorded");
  await context.close();

  const rpc = await fakeRpc();
  try {
    await checkCommand(keyFile, address, rpc.url);
    await checkForwardingAndDelayedDecline(browser, keyFile, rpc.url);
    await checkReceipt(browser, keyFile, rpc.url);
  } finally {
    rpc.close();
  }
  await browser.close();

  // The recording transcodes to an H.264 mp4 GitHub plays inline.
  const mp4 = path.join(work, "proof.mp4");
  execFileSync("qa-mp4", [await video.path(), mp4], { stdio: "inherit" });
  const codec = execFileSync("ffprobe", [
    "-v",
    "error",
    "-select_streams",
    "v:0",
    "-show_entries",
    "stream=codec_name",
    "-of",
    "default=noprint_wrappers=1:nokey=1",
    mp4,
  ])
    .toString()
    .trim();
  assert.strictEqual(codec, "h264");

  console.log("qa: wallet and video pipeline ok");
}

async function routeDapp(context: BrowserContext): Promise<void> {
  await context.route(DAPP, (route) =>
    route.fulfill({ contentType: "text/html", body: DAPP_HTML }),
  );
}

// A request through the announced provider, as the dApp makes it.
function providerCall(page: Page) {
  return (method: string, params: unknown[] = []) =>
    page.evaluate(
      async ([method, params]) => {
        try {
          const provider = window.found[0]?.provider;
          return { result: await provider?.request({ method, params }) };
        } catch (error) {
          const { code, message } = error as RpcError;
          return { error: { code, message } };
        }
      },
      [method, params] as const,
    ) as Promise<RpcOutcome>;
}

// `qa-wallet` derives the address, reads the balances from the RPC, and never
// names the key file, not even when the file is unreadable. Asynchronous, so
// the fake RPC in this process can answer it.
async function checkCommand(
  keyFile: string,
  address: Address,
  rpcUrl: string,
): Promise<void> {
  const run = (args: string[], env: NodeJS.ProcessEnv) =>
    new Promise<{
      status: number | string | null | undefined;
      stdout: string;
      stderr: string;
    }>((resolve) => {
      const options = { env: { ...process.env, QA_EVM_KEY_FILE: "", ...env } };
      execFile("qa-wallet", args, options, (error, stdout, stderr) =>
        resolve({ status: error ? error.code : 0, stdout, stderr }),
      );
    });

  assert.strictEqual(
    (await run(["address"], { QA_EVM_KEY_FILE: keyFile })).stdout.trim(),
    address,
  );

  const balance = await run(["balance", "--rpc", rpcUrl, "--erc20", TOKEN], {
    QA_EVM_KEY_FILE: keyFile,
  });
  assert.strictEqual(balance.status, 0, balance.stderr);
  assert.deepStrictEqual(balance.stdout.trim().split("\n"), [
    `address ${address}`,
    "native 1.5",
    `USDC 12.25 (${TOKEN})`,
  ]);

  const unset = await run(["address"], {});
  assert.strictEqual(unset.status, 1);
  assert.match(unset.stderr, /unavailable/);

  const missing = path.join(work, "no-such-key");
  const unreadable = await run(["address"], { QA_EVM_KEY_FILE: missing });
  assert.strictEqual(unreadable.status, 1);
  assert.match(unreadable.stderr, /\$QA_EVM_KEY_FILE/);
  assert.ok(
    !unreadable.stderr.includes(missing),
    "qa-wallet named the key file",
  );
}

// `forwardRpc` answers the page's own POSTs for this chain from `rpcUrl`, and
// lets GETs and other chains go out untouched (here: to a host that never
// resolves). `rejectNext(m, { afterMs })` declines only after the pause.
async function checkForwardingAndDelayedDecline(
  browser: Browser,
  keyFile: string,
  rpcUrl: string,
): Promise<void> {
  const context = await browser.newContext();
  await routeDapp(context);
  const { address, rejectNext } = await installWallet(context, {
    keyFile,
    rpcUrl,
    chainId: SEPOLIA,
    forwardRpc: [/^http:\/\/rpc\.test\//],
  });
  const page = await context.newPage();
  await page.goto(DAPP);

  const post = (url: string) =>
    page.evaluate(async (url) => {
      try {
        const response = await fetch(url, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            jsonrpc: "2.0",
            id: 1,
            method: "eth_blockNumber",
            params: [],
          }),
        });
        return { body: await response.json() };
      } catch (error) {
        return { failed: String(error) };
      }
    }, url);

  assert.deepStrictEqual(await post(`${RPC}?chainId=eip155:${SEPOLIA}`), {
    body: { jsonrpc: "2.0", id: 1, result: "0x2a" },
  });
  assert.deepStrictEqual(await post(RPC), {
    body: { jsonrpc: "2.0", id: 1, result: "0x2a" },
  });
  assert.ok(
    (await post(`${RPC}?chainId=eip155:1`)).failed,
    "another chain was forwarded",
  );
  const get = await page.evaluate(
    (url) =>
      fetch(url).then(
        () => "answered",
        () => "failed",
      ),
    RPC,
  );
  assert.strictEqual(get, "failed", "a GET was forwarded");

  const call = providerCall(page);
  const hex = toHex("hello");
  const afterMs = 400;
  rejectNext("personal_sign", { afterMs });
  const started = Date.now();
  assert.deepStrictEqual((await call("personal_sign", [hex, address])).error, {
    code: 4001,
    message: "User rejected the request.",
  });
  assert.ok(
    Date.now() - started >= afterMs,
    "the decline did not wait afterMs",
  );
  assert.ok(
    (await call("personal_sign", [hex, address])).result,
    "the request after a delayed decline is not signed",
  );

  await context.close();
}

// Given the dApp sent a transaction through the wallet, when the script waits
// for its receipt, then it resolves once the node mines it, a few blocks on,
// with the outcome; with nothing sent and no hash, it says so.
async function checkReceipt(
  browser: Browser,
  keyFile: string,
  rpcUrl: string,
): Promise<void> {
  const context = await browser.newContext();
  await routeDapp(context);
  const { address, waitForReceipt } = await installWallet(context, {
    keyFile,
    rpcUrl,
    chainId: SEPOLIA,
  });
  const page = await context.newPage();
  await page.goto(DAPP);
  assert.throws(() => waitForReceipt(), /has sent nothing/);

  const hash = (await page.evaluate(
    (to) =>
      window.found[0]?.provider.request({
        method: "eth_sendTransaction",
        params: [{ to, value: "0x1" }],
      }),
    address,
  )) as Hex;
  assert.deepStrictEqual(await waitForReceipt(undefined, { timeout: 20_000 }), {
    transactionHash: hash,
    status: "success",
    blockNumber: 44,
  });
  assert.deepStrictEqual((await waitForReceipt(hash)).transactionHash, hash);
  await context.close();
}

// A JSON-RPC node on loopback: 1.5 ETH and one ERC-20 (USDC, 6 decimals)
// holding 12.25 for anyone, at block 42. A sent transaction is mined two
// blocks later; the chain advances a block per eth_blockNumber only while
// one is pending.
async function fakeRpc(): Promise<Listening> {
  // As a real node answers a method it does not serve (viem probes
  // eth_fillTransaction before filling a transaction itself).
  const METHOD_NOT_FOUND = Symbol("method not found");
  let block = 42;
  const pending: { hash: Hex; at: number }[] = [];
  const mined = new Map<Hex, number>();
  const answer = ({ method, params }: RpcRequest) => {
    switch (method) {
      case "eth_chainId":
        return toHex(SEPOLIA);
      case "eth_blockNumber":
        if (pending.length > 0) {
          block += 1;
          while (pending[0] && pending[0].at <= block) {
            mined.set(pending[0].hash, block);
            pending.shift();
          }
        }
        return toHex(block);
      case "eth_getTransactionCount":
        return "0x0";
      case "eth_estimateGas":
        return "0x5208";
      case "eth_gasPrice":
      case "eth_maxPriorityFeePerGas":
        return "0x1";
      case "eth_getBlockByNumber":
        return {
          number: toHex(block),
          hash: `0x${"ab".repeat(32)}`,
          baseFeePerGas: "0x1",
          timestamp: "0x0",
          gasLimit: "0x1c9c380",
          gasUsed: "0x0",
          transactions: [],
        };
      case "eth_sendRawTransaction": {
        const hash = keccak256(params[0] as Hex);
        pending.push({ hash, at: block + 2 });
        return hash;
      }
      case "eth_getTransactionReceipt": {
        const at = mined.get(params[0] as Hex);
        if (at === undefined) return null;
        return {
          transactionHash: params[0],
          blockHash: `0x${"cd".repeat(32)}`,
          blockNumber: toHex(at),
          status: "0x1",
          logs: [],
          logsBloom: `0x${"00".repeat(256)}`,
          gasUsed: "0x5208",
          cumulativeGasUsed: "0x5208",
          effectiveGasPrice: "0x1",
          transactionIndex: "0x0",
          type: "0x2",
          contractAddress: null,
          from: `0x${"00".repeat(20)}`,
          to: `0x${"00".repeat(20)}`,
        };
      }
      case "eth_getBalance":
        return toHex(15n * 10n ** 17n);
      case "eth_call": {
        const [{ data, input }] = params as [{ data?: Hex; input: Hex }];
        const { functionName } = decodeFunctionData({
          abi: erc20Abi,
          data: data ?? input,
        });
        switch (functionName) {
          case "symbol":
            return encodeFunctionResult({
              abi: erc20Abi,
              functionName,
              result: "USDC",
            });
          case "decimals":
            return encodeFunctionResult({
              abi: erc20Abi,
              functionName,
              result: 6,
            });
          case "balanceOf":
            return encodeFunctionResult({
              abi: erc20Abi,
              functionName,
              result: 12_250_000n,
            });
          default:
            return METHOD_NOT_FOUND;
        }
      }
      default:
        return METHOD_NOT_FOUND;
    }
  };
  const respond = (request: RpcRequest | RpcRequest[]): unknown => {
    if (Array.isArray(request)) return request.map(respond);
    const result = answer(request);
    return result === METHOD_NOT_FOUND
      ? {
          jsonrpc: "2.0",
          id: request.id,
          error: {
            code: -32601,
            message: `the method ${request.method} does not exist`,
          },
        }
      : { jsonrpc: "2.0", id: request.id, result };
  };
  return listen((req, res) => {
    let body = "";
    req.on("data", (chunk) => {
      body += chunk;
    });
    req.on("end", () => {
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify(respond(JSON.parse(body))));
    });
  });
}

runCheck(main);
