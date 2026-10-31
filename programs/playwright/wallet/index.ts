// An EIP-1193 wallet for Playwright, announced through EIP-6963, that signs in
// Node. The page gets a provider whose every request crosses into this process
// through `exposeFunction`; the private key is read here, held by a viem
// account, and never serialised into the page, an error or a log line.
//
//   const { installWallet } = require('qa-wallet');
//   const { address, rejectNext } = await installWallet(context, {
//     keyFile: process.env.QA_EVM_KEY_FILE,
//     rpcUrl: 'https://ethereum-sepolia-rpc.publicnode.com',
//     chainId: 11155111,
//   });
//
// Call it before the dApp's first navigation: the provider is an init script,
// so pages loaded earlier never see it.
//
// `rejectNext('eth_sendTransaction')` makes the wallet decline the next request
// of that method as a user would (EIP-1193 4001); later ones are answered.
// `rejectNext(method, { afterMs: 2000 })` declines after a pause, as a user
// reading the prompt would, so the dApp's pending state lasts long enough to
// be recorded.
//
// `waitForReceipt(hash)` waits for a transaction's receipt on `rpcUrl`;
// without a hash, for the last one the wallet sent. It resolves when mined,
// reverted included, so a script asserts the outcome instead of guessing a
// wait.
//
// `forwardRpc: [/^https:\/\/rpc\.walletconnect\.org\//]` answers the dApp's own
// JSON-RPC POSTs to matching URLs from `rpcUrl`, for a dApp whose default RPC
// refuses headless or localhost traffic (its receipt waits then never end).
//
// `walletAddress(keyFile)` derives the address without installing anything;
// the `qa-wallet` command prints it and the balances a run needs.
import crypto from "node:crypto";
import fs from "node:fs";
import type { BrowserContext, Route } from "playwright";
import {
  type Address,
  createPublicClient,
  createWalletClient,
  type Hash,
  type Hex,
  http,
  type TypedDataDefinition,
  toHex,
} from "viem";
import { type PrivateKeyAccount, privateKeyToAccount } from "viem/accounts";

const BINDING = "__qaWalletRequest";
const WALLET_INFO = {
  name: "QA Wallet",
  rdns: "dev.qa.wallet",
  // A plain grey circle: wallet pickers render an icon for every entry.
  icon: "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAzMiAzMiI+PGNpcmNsZSBjeD0iMTYiIGN5PSIxNiIgcj0iMTYiIGZpbGw9IiM4ODgiLz48L3N2Zz4=",
};

// The requests a real wallet asks its user to approve, so the only ones a user
// can decline.
const APPROVABLE: readonly string[] = [
  "eth_requestAccounts",
  "wallet_requestPermissions",
  "wallet_switchEthereumChain",
  "personal_sign",
  "eth_sign",
  "eth_signTypedData_v4",
  "eth_sendTransaction",
];

// EIP-1193 error codes the provider answers with.
const USER_REJECTED = 4001;
const UNSUPPORTED = 4200;
const UNRECOGNISED_CHAIN = 4902;

/** Either a BrowserContext (every page) or a Page (that page only). */
export type WalletTarget = Pick<
  BrowserContext,
  "exposeFunction" | "addInitScript" | "route"
>;

export type WalletRpc =
  /** Offline: only accounts, chain and signing requests work. */
  | { rpcUrl?: undefined; forwardRpc?: undefined }
  | {
      /** JSON-RPC endpoint for reads and transactions. */
      rpcUrl: string;
      /**
       * URL patterns whose JSON-RPC POSTs are answered from `rpcUrl` instead;
       * needs a BrowserContext.
       */
      forwardRpc?: readonly RegExp[];
    };

export type WalletChain = {
  /** The chain the wallet is on. */
  chainId: number;
} & WalletRpc;

export type WalletOptions = {
  /** A file holding a 0x-prefixed or bare hex private key. */
  keyFile: string | undefined;
} & WalletChain;

export type Receipt = {
  transactionHash: Hash;
  status: "success" | "reverted";
  blockNumber: number;
};

export type WalletControls = {
  /**
   * Declines the next request of `method`, one of APPROVABLE, with 4001 "User
   * rejected the request.", after `afterMs` (default 0); one-shot per method.
   */
  rejectNext: (method: string, options?: { afterMs?: number }) => void;
  /**
   * Resolves once the transaction is mined; throws after `timeout` (default
   * 120 s).
   */
  waitForReceipt: (
    hash?: Hash,
    options?: { timeout?: number },
  ) => Promise<Receipt>;
};

export type Wallet = WalletControls & { address: Address };

type RpcFailure = { code: number; message: string };

type WalletResponse = { result: unknown } | { error: RpcFailure };

type Eip1193Request = { method: string; params?: unknown[] };

type TransactionParams = { to?: Address; data?: Hex; value?: Hex; gas?: Hex };

type Listener = (value: unknown) => void;

type Eip1193Provider = {
  isQaWallet: boolean;
  request: (request: Eip1193Request) => Promise<unknown>;
  on: (event: string, listener: Listener) => Eip1193Provider;
  removeListener: (event: string, listener: Listener) => Eip1193Provider;
};

declare global {
  interface Window {
    [BINDING]: (method: string, params: unknown[]) => Promise<WalletResponse>;
    ethereum?: Eip1193Provider;
  }
}

/** Installs the wallet on a Playwright BrowserContext or Page. */
export async function installWallet(
  target: WalletTarget,
  { keyFile, rpcUrl, chainId, forwardRpc = [] }: WalletOptions,
): Promise<Wallet> {
  const account = privateKeyToAccount(readKey(keyFile));
  const handle = requestHandler(account, rpcUrl, chainId);
  const toReject = new Map<string, number>();
  let lastSent: Hash | undefined;
  if (forwardRpc.length > 0) {
    await forwardTo(target, forwardRpc, rpcUrl, chainId);
  }
  await target.exposeFunction(
    BINDING,
    async (method: string, params?: unknown[]): Promise<WalletResponse> => {
      try {
        const afterMs = toReject.get(method);
        if (afterMs !== undefined) {
          toReject.delete(method);
          await new Promise((resolve) => setTimeout(resolve, afterMs));
          throw rpcError(USER_REJECTED, "User rejected the request.");
        }
        const result = await handle(method, params ?? []);
        if (method === "eth_sendTransaction") lastSent = result as Hash;
        return { result };
      } catch (error) {
        return { error: toRpcError(error) };
      }
    },
  );
  await target.addInitScript(pageProvider, {
    binding: BINDING as typeof BINDING,
    info: { uuid: crypto.randomUUID(), ...WALLET_INFO },
  });
  const rejectNext: Wallet["rejectNext"] = (method, { afterMs = 0 } = {}) => {
    if (!APPROVABLE.includes(method)) {
      throw new Error(
        `qa-wallet: a user cannot decline ${method}; one of ${APPROVABLE.join(", ")}`,
      );
    }
    toReject.set(method, afterMs);
  };
  const waitForReceipt: Wallet["waitForReceipt"] = (
    hash = lastSent,
    { timeout = 120_000 } = {},
  ) => {
    if (!rpcUrl) throw new Error("qa-wallet: waitForReceipt needs an rpcUrl");
    if (!hash) {
      throw new Error(
        "qa-wallet: waitForReceipt has no hash, and the wallet has sent nothing",
      );
    }
    return receiptOf(rpcUrl, hash, timeout);
  };
  return { address: account.address, rejectNext, waitForReceipt };
}

/** The wallet's address, derived from the key; the key itself never leaves. */
export function walletAddress(keyFile: string | undefined): Address {
  return privateKeyToAccount(readKey(keyFile)).address;
}

function readKey(keyFile: string | undefined): Hex {
  if (!keyFile) {
    throw new Error("qa-wallet: no keyFile given (is QA_EVM_KEY_FILE set?)");
  }
  const raw = readKeyFile(keyFile);
  const key = raw.startsWith("0x") ? raw : `0x${raw}`;
  // The message names the file, never its content.
  if (!isPrivateKey(key)) {
    throw new Error(
      `qa-wallet: ${keyFile} does not hold a 32-byte hex private key`,
    );
  }
  return key;
}

function readKeyFile(keyFile: string): string {
  try {
    return fs.readFileSync(keyFile, "utf8").trim();
  } catch (error) {
    throw new Error(
      `qa-wallet: cannot read the key file ${keyFile} (${(error as NodeJS.ErrnoException).code})`,
    );
  }
}

function isPrivateKey(key: string): key is Hex {
  return /^0x[0-9a-fA-F]{64}$/.test(key);
}

function requestHandler(
  account: PrivateKeyAccount,
  rpcUrl: string | undefined,
  chainId: number,
): (method: string, params: unknown[]) => Promise<unknown> {
  const chainHex = toHex(chainId);
  const wallet = rpcUrl
    ? createWalletClient({ account, transport: http(rpcUrl) })
    : null;

  const needRpc = (method: string) => {
    if (wallet) return wallet;
    throw rpcError(UNSUPPORTED, `qa-wallet: ${method} needs an rpcUrl`);
  };

  const requireChain = (wanted: string | number | bigint) => {
    if (Number(wanted) !== chainId) {
      throw rpcError(
        UNRECOGNISED_CHAIN,
        `qa-wallet: only chain ${chainId} is available`,
      );
    }
  };

  const signMessage = (message: Hex) =>
    account.signMessage({ message: { raw: message } });

  // A typed-data domain names the chain the signature is valid on: one for
  // another chain (a mainnet Permit, say) is refused, as for a chain switch.
  const signTypedData = (typedData: TypedDataDefinition) => {
    const wanted = typedData.domain?.chainId;
    if (wanted !== undefined) requireChain(wanted);
    return account.signTypedData(typedData);
  };

  // Each method's params are what EIP-1193 says the page sends: the handler
  // takes them unchecked, and a malformed request fails as an RPC error.
  const methods: Record<string, (params: never) => unknown> = {
    eth_requestAccounts: () => [account.address],
    eth_accounts: () => [account.address],
    eth_chainId: () => chainHex,
    net_version: () => String(chainId),
    wallet_requestPermissions: () => [{ parentCapability: "eth_accounts" }],
    wallet_getPermissions: () => [{ parentCapability: "eth_accounts" }],
    wallet_switchEthereumChain: ([{ chainId: wanted }]: [
      { chainId: string },
    ]) => {
      requireChain(wanted);
      return null;
    },
    personal_sign: ([message]: [Hex]) => signMessage(message),
    eth_sign: ([, message]: [Address, Hex]) => signMessage(message),
    eth_signTypedData_v4: ([, typedData]: [
      Address,
      string | TypedDataDefinition,
    ]) =>
      signTypedData(
        typeof typedData === "string" ? JSON.parse(typedData) : typedData,
      ),
    eth_sendTransaction: ([tx]: [TransactionParams]) =>
      needRpc("eth_sendTransaction").sendTransaction({
        chain: null,
        to: tx.to,
        data: tx.data,
        value: optionalBigInt(tx.value),
        gas: optionalBigInt(tx.gas),
      }),
  };

  return async (method, params) => {
    const local = methods[method];
    if (local) return local(params as never);
    return needRpc(method).request({ method, params } as never);
  };
}

function optionalBigInt(hex: Hex | undefined): bigint | undefined {
  return hex === undefined ? undefined : BigInt(hex);
}

function rpcError(code: number, message: string): Error {
  return Object.assign(new Error(message), { code });
}

// Answers the page's JSON-RPC POSTs to `patterns` from `rpcUrl`. Anything
// else goes out untouched: GETs, other hosts, and a URL whose `chainId` query
// parameter (AppKit's `eip155:<id>`) names another chain.
async function forwardTo(
  target: WalletTarget,
  patterns: readonly RegExp[],
  rpcUrl: string | undefined,
  chainId: number,
): Promise<void> {
  // WalletRpc rules this out, but a /qa script is plain JavaScript.
  if (!rpcUrl) throw new Error("qa-wallet: forwardRpc needs an rpcUrl");
  const forward = async (route: Route) => {
    const request = route.request();
    const wanted = new URL(request.url()).searchParams.get("chainId");
    const otherChain =
      wanted !== null && wanted.split(":").pop() !== String(chainId);
    if (request.method() !== "POST" || otherChain) return route.continue();
    try {
      const response = await fetch(rpcUrl, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: request.postData(),
      });
      await route.fulfill({
        status: response.status,
        contentType: "application/json",
        headers: { "access-control-allow-origin": "*" },
        body: await response.text(),
      });
    } catch {
      await route.abort();
    }
  };
  for (const pattern of patterns) await target.route(pattern, forward);
}

// A receipt reduced to what a QA verdict reads, as plain JSON so it crosses
// into a page and back.
async function receiptOf(
  rpcUrl: string,
  hash: Hash,
  timeout: number,
): Promise<Receipt> {
  const client = createPublicClient({
    transport: http(rpcUrl),
    pollingInterval: 1_000,
  });
  // The QA wallet is the transaction's only sender and never replaces one.
  const receipt = await client.waitForTransactionReceipt({
    hash,
    timeout,
    checkReplacement: false,
  });
  return {
    transactionHash: receipt.transactionHash,
    status: receipt.status,
    blockNumber: Number(receipt.blockNumber),
  };
}

function toRpcError(error: unknown): RpcFailure {
  const { code, shortMessage, message } = error as Error & {
    code?: unknown;
    shortMessage?: string;
  };
  return {
    code: typeof code === "number" ? code : -32603,
    message: shortMessage ?? message,
  };
}

// Runs in the page, serialised by addInitScript, so it closes over nothing in
// this module: only the binding name and the wallet's public info are passed.
function pageProvider({
  binding,
  info,
}: {
  binding: typeof BINDING;
  info: typeof WALLET_INFO & { uuid: string };
}): void {
  const listeners: Record<string, Listener[]> = {};
  const emit = (event: string, value: unknown) => {
    for (const listener of listeners[event] ?? []) listener(value);
  };

  const provider: Eip1193Provider = {
    isQaWallet: true,
    async request({ method, params }) {
      const response = await window[binding](method, params ?? []);
      if ("error" in response) {
        const { code, message } = response.error;
        throw Object.assign(new Error(message), { code });
      }
      if (method === "eth_requestAccounts") {
        emit("accountsChanged", response.result);
      }
      return response.result;
    },
    on(event, listener) {
      listeners[event] ??= [];
      listeners[event].push(listener);
      return provider;
    },
    removeListener(event, listener) {
      listeners[event] = (listeners[event] ?? []).filter((l) => l !== listener);
      return provider;
    },
  };

  const detail = Object.freeze({ info: Object.freeze(info), provider });
  const announce = () =>
    window.dispatchEvent(
      new CustomEvent("eip6963:announceProvider", { detail }),
    );
  window.addEventListener("eip6963:requestProvider", announce);
  announce();
  if (!window.ethereum) window.ethereum = provider;
}
