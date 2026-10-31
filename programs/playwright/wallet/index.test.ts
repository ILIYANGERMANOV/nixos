import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fc, test } from "@fast-check/vitest";
import {
  type Hex,
  keccak256,
  toBytes,
  toHex,
  verifyMessage,
  verifyTypedData,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { afterEach, beforeEach, describe, expect } from "vitest";
import {
  installWallet,
  type WalletRpc,
  type WalletTarget,
  walletAddress,
} from "./index.js";

const CHAIN_ID = 11155111;
const KEY = `0x${"11".repeat(32)}` as const;
const ADDRESS = privateKeyToAccount(KEY).address;
const RPC_URL = "http://rpc.test/";

// secp256k1's order: a private key is in [1, order).
const CURVE_ORDER =
  0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;

const TYPED_DATA = {
  domain: { name: "QA", version: "1", chainId: CHAIN_ID },
  types: { Greeting: [{ name: "text", type: "string" }] },
  primaryType: "Greeting",
  message: { text: "hello" },
} as const;

type Response = {
  result?: unknown;
  error?: { code: number; message: string };
};

type PageRequest = (method: string, params?: unknown[]) => Promise<Response>;

let directory: string;

beforeEach(() => {
  directory = fs.mkdtempSync(path.join(os.tmpdir(), "qa-wallet-"));
});

afterEach(() => {
  fs.rmSync(directory, { recursive: true });
});

function keyFile(content: string): string {
  const file = path.join(directory, "key");
  fs.writeFileSync(file, content);
  return file;
}

// A BrowserContext reduced to what the page reaches: the exposed function, and
// the argument the init script is serialised with.
function fakeContext() {
  const page: {
    request?: PageRequest;
    initScriptArgument?: unknown;
  } = {};
  const target = {
    exposeFunction: async (_name: string, callback: PageRequest) => {
      page.request = callback;
    },
    addInitScript: async (_script: unknown, argument: unknown) => {
      page.initScriptArgument = argument;
    },
  } as unknown as WalletTarget;
  const request = (method: string, params?: unknown[]): Promise<Response> => {
    if (!page.request) throw new Error("the wallet is not installed");
    return page.request(method, params);
  };
  return { target, request, page };
}

async function installed(options: WalletRpc = {}) {
  const { target, request, page } = fakeContext();
  const wallet = await installWallet(target, {
    keyFile: keyFile(KEY),
    chainId: CHAIN_ID,
    ...options,
  });
  return { ...wallet, request, page };
}

function signedByWallet(message: Hex, signature: unknown): Promise<boolean> {
  return verifyMessage({
    address: ADDRESS,
    message: { raw: message },
    signature: signature as Hex,
  });
}

describe("walletAddress", () => {
  test.prop([fc.bigInt({ min: 1n, max: CURVE_ORDER - 1n })])(
    "derives the key's address, with or without 0x and around whitespace",
    (scalar) => {
      const key = `0x${scalar.toString(16).padStart(64, "0")}` as Hex;
      const expected = privateKeyToAccount(key).address;

      expect(walletAddress(keyFile(`${key}\n`))).toBe(expected);
      expect(walletAddress(keyFile(`  ${key.slice(2)}  `))).toBe(expected);
    },
  );

  test.prop([
    fc
      .string({ minLength: 8 })
      .filter((content) => !/^(0x)?[0-9a-fA-F]{64}$/.test(content.trim())),
  ])("refuses a file with no key and never echoes its content", (content) => {
    const read = () => walletAddress(keyFile(content));

    expect(read).toThrow(/does not hold a 32-byte hex private key/);
    expect(read).not.toThrow(content);
  });

  test("refuses a key one digit short", () => {
    expect(() => walletAddress(keyFile(KEY.slice(0, -1)))).toThrow(
      /does not hold a 32-byte hex private key/,
    );
  });

  test("names the reason a key file cannot be read", () => {
    expect(() => walletAddress(path.join(directory, "absent"))).toThrow(
      /cannot read the key file .*absent \(ENOENT\)/,
    );
  });

  test("asks for a key file when none is given", () => {
    expect(() => walletAddress(undefined)).toThrow(/is QA_EVM_KEY_FILE set\?/);
  });
});

describe("the provider's requests", () => {
  test("answers the account and chain without an RPC", async () => {
    const { request } = await installed();

    expect(await request("eth_requestAccounts")).toEqual({ result: [ADDRESS] });
    expect(await request("eth_accounts")).toEqual({ result: [ADDRESS] });
    expect(await request("eth_chainId")).toEqual({ result: toHex(CHAIN_ID) });
    expect(await request("net_version")).toEqual({
      result: String(CHAIN_ID),
    });
  });

  test.prop([fc.uint8Array({ maxLength: 256 })])(
    "signs a personal_sign message the signer's address verifies",
    async (bytes) => {
      const { request } = await installed();
      const message = toHex(bytes);

      const { result } = await request("personal_sign", [message, ADDRESS]);

      expect(await signedByWallet(message, result)).toBe(true);
    },
  );

  test("eth_sign takes the address first", async () => {
    const { request } = await installed();
    const message = keccak256(toBytes("hello"));

    const { result } = await request("eth_sign", [ADDRESS, message]);

    expect(await signedByWallet(message, result)).toBe(true);
  });

  test("signs typed data given as JSON or as an object, the same", async () => {
    const { request } = await installed();

    const json = await request("eth_signTypedData_v4", [
      ADDRESS,
      JSON.stringify(TYPED_DATA),
    ]);
    const object = await request("eth_signTypedData_v4", [ADDRESS, TYPED_DATA]);

    expect(object).toEqual(json);
    expect(
      await verifyTypedData({
        address: ADDRESS,
        signature: json.result as Hex,
        ...TYPED_DATA,
      }),
    ).toBe(true);
  });

  test("refuses typed data for another chain", async () => {
    const { request } = await installed();
    const mainnet = { ...TYPED_DATA, domain: { chainId: 1 } };

    const { error } = await request("eth_signTypedData_v4", [ADDRESS, mainnet]);

    expect(error?.code).toBe(4902);
  });

  test("switches to its own chain", async () => {
    const { request } = await installed();

    const answer = await request("wallet_switchEthereumChain", [
      { chainId: toHex(CHAIN_ID) },
    ]);

    expect(answer).toEqual({ result: null });
  });

  test("refuses a switch to another chain", async () => {
    const { request } = await installed();

    const { error } = await request("wallet_switchEthereumChain", [
      { chainId: "0x1" },
    ]);

    expect(error?.code).toBe(4902);
  });

  test("answers a read as unsupported when it has no RPC", async () => {
    const { request } = await installed();

    const { error } = await request("eth_blockNumber");

    expect(error).toEqual({
      code: 4200,
      message: "qa-wallet: eth_blockNumber needs an rpcUrl",
    });
  });

  test("answers a malformed request as an RPC error", async () => {
    const { request } = await installed();

    const { error } = await request("personal_sign", []);

    expect(error?.code).toBe(-32603);
  });
});

describe("rejectNext", () => {
  test("declines the next request of that method only, once", async () => {
    const { request, rejectNext } = await installed();
    const hello = toHex("hello");
    rejectNext("personal_sign");

    const accounts = await request("eth_requestAccounts");
    const declined = await request("personal_sign", [hello, ADDRESS]);
    const signed = await request("personal_sign", [hello, ADDRESS]);

    expect(accounts).toEqual({ result: [ADDRESS] });
    expect(declined).toEqual({
      error: { code: 4001, message: "User rejected the request." },
    });
    expect(signed.result).toEqual(expect.stringMatching(/^0x/));
  });

  test("refuses a method no user approves", async () => {
    const { rejectNext } = await installed();

    expect(() => rejectNext("eth_blockNumber")).toThrow(/cannot decline/);
  });
});

describe("waitForReceipt", () => {
  test("needs an rpcUrl", async () => {
    const { waitForReceipt } = await installed();

    expect(() => waitForReceipt(KEY)).toThrow(/needs an rpcUrl/);
  });

  test("says so when there is no hash and nothing was sent", async () => {
    const { waitForReceipt } = await installed({ rpcUrl: RPC_URL });

    expect(() => waitForReceipt()).toThrow(/has sent nothing/);
  });
});

describe("forwardRpc", () => {
  const forwardRpc = [/^http:\/\/rpc\.test\//];

  test("needs an rpcUrl", async () => {
    // @ts-expect-error A /qa script is plain JavaScript, so it can still pass this.
    await expect(installed({ forwardRpc })).rejects.toThrow(
      /forwardRpc needs an rpcUrl/,
    );
  });

  test("needs a target that can route", async () => {
    await expect(installed({ rpcUrl: RPC_URL, forwardRpc })).rejects.toThrow(
      /needs a BrowserContext or Page/,
    );
  });
});

describe("the key", () => {
  test("never reaches the page, in an answer or the init script", async () => {
    const { request, page } = await installed();
    const bareKey = KEY.slice(2);

    const answers = await Promise.all([
      request("eth_accounts"),
      request("eth_blockNumber"),
      request("personal_sign", []),
      request("personal_sign", [toHex("hello"), ADDRESS]),
    ]);

    expect(JSON.stringify([answers, page.initScriptArgument])).not.toContain(
      bareKey,
    );
  });
});
