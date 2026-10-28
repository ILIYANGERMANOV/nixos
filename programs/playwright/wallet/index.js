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
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const { createWalletClient, http, toHex } = require('viem');
const { privateKeyToAccount } = require('viem/accounts');

const BINDING = '__qaWalletRequest';
const WALLET_INFO = {
  name: 'QA Wallet',
  rdns: 'dev.qa.wallet',
  // A plain grey circle: wallet pickers render an icon for every entry.
  icon: 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAzMiAzMiI+PGNpcmNsZSBjeD0iMTYiIGN5PSIxNiIgcj0iMTYiIGZpbGw9IiM4ODgiLz48L3N2Zz4=',
};

// The requests a real wallet asks its user to approve, so the only ones a user
// can decline.
const APPROVABLE = [
  'eth_requestAccounts',
  'wallet_requestPermissions',
  'wallet_switchEthereumChain',
  'personal_sign',
  'eth_sign',
  'eth_signTypedData_v4',
  'eth_sendTransaction',
];

// EIP-1193 error codes the provider answers with.
const USER_REJECTED = 4001;
const UNSUPPORTED = 4200;
const UNRECOGNISED_CHAIN = 4902;

/**
 * Installs the wallet on a Playwright BrowserContext or Page.
 *
 * @param target  a BrowserContext (every page) or a Page (that page only)
 * @param options.keyFile  path to a file holding a 0x-prefixed or bare hex private key
 * @param options.chainId  the chain the wallet is on, as a number
 * @param options.rpcUrl   JSON-RPC endpoint for reads and transactions; without
 *                         it only accounts, chain and signing requests work
 * @returns {Promise<{ address: string, rejectNext: (method: string) => void }>}
 *   `rejectNext(method)` declines the next request of `method`, one of
 *   APPROVABLE, with 4001 "User rejected the request."; one-shot per method
 */
async function installWallet(target, { keyFile, rpcUrl, chainId }) {
  const account = privateKeyToAccount(readKey(keyFile));
  const handle = requestHandler({ account, rpcUrl, chainId });
  const toReject = new Set();
  await target.exposeFunction(BINDING, async (method, params) => {
    try {
      if (toReject.delete(method)) throw rpcError(USER_REJECTED, 'User rejected the request.');
      return { result: await handle(method, params ?? []) };
    } catch (error) {
      return { error: toRpcError(error) };
    }
  });
  await target.addInitScript(pageProvider, {
    binding: BINDING,
    info: { uuid: crypto.randomUUID(), ...WALLET_INFO },
  });
  const rejectNext = (method) => {
    if (!APPROVABLE.includes(method)) {
      throw new Error(`qa-wallet: a user cannot decline ${method}; one of ${APPROVABLE.join(', ')}`);
    }
    toReject.add(method);
  };
  return { address: account.address, rejectNext };
}

function readKey(keyFile) {
  if (!keyFile) throw new Error('qa-wallet: no keyFile given (is QA_EVM_KEY_FILE set?)');
  let raw;
  try {
    raw = fs.readFileSync(keyFile, 'utf8').trim();
  } catch (error) {
    throw new Error(`qa-wallet: cannot read the key file ${keyFile} (${error.code})`);
  }
  const key = raw.startsWith('0x') ? raw : `0x${raw}`;
  // The message names the file, never its content.
  if (!/^0x[0-9a-fA-F]{64}$/.test(key)) {
    throw new Error(`qa-wallet: ${keyFile} does not hold a 32-byte hex private key`);
  }
  return key;
}

function requestHandler({ account, rpcUrl, chainId }) {
  const chainHex = toHex(chainId);
  const wallet = rpcUrl ? createWalletClient({ account, transport: http(rpcUrl) }) : null;

  const needRpc = (method) => {
    if (wallet) return wallet;
    throw rpcError(UNSUPPORTED, `qa-wallet: ${method} needs an rpcUrl`);
  };

  const methods = {
    eth_requestAccounts: () => [account.address],
    eth_accounts: () => [account.address],
    eth_chainId: () => chainHex,
    net_version: () => String(chainId),
    wallet_requestPermissions: () => [{ parentCapability: 'eth_accounts' }],
    wallet_getPermissions: () => [{ parentCapability: 'eth_accounts' }],
    wallet_switchEthereumChain: ([{ chainId: wanted }]) => {
      if (Number(wanted) !== chainId) {
        throw rpcError(UNRECOGNISED_CHAIN, `qa-wallet: only chain ${chainId} is available`);
      }
      return null;
    },
    personal_sign: ([message]) => account.signMessage({ message: { raw: message } }),
    eth_sign: ([, message]) => account.signMessage({ message: { raw: message } }),
    eth_signTypedData_v4: ([, typedData]) =>
      account.signTypedData(typeof typedData === 'string' ? JSON.parse(typedData) : typedData),
    eth_sendTransaction: ([tx]) =>
      needRpc('eth_sendTransaction').sendTransaction({
        chain: null,
        to: tx.to,
        data: tx.data,
        value: tx.value === undefined ? undefined : BigInt(tx.value),
        gas: tx.gas === undefined ? undefined : BigInt(tx.gas),
      }),
  };

  return async (method, params) => {
    const local = methods[method];
    if (local) return local(params);
    return needRpc(method).request({ method, params });
  };
}

function rpcError(code, message) {
  return Object.assign(new Error(message), { code });
}

function toRpcError(error) {
  return {
    code: typeof error.code === 'number' ? error.code : -32603,
    message: error.shortMessage ?? error.message,
  };
}

// Runs in the page, serialised by addInitScript, so it closes over nothing in
// this module: only the binding name and the wallet's public info are passed.
function pageProvider({ binding, info }) {
  const listeners = {};
  const emit = (event, value) => (listeners[event] ?? []).forEach((listener) => listener(value));

  const provider = {
    isQaWallet: true,
    async request({ method, params }) {
      const { result, error } = await window[binding](method, params ?? []);
      if (error) throw Object.assign(new Error(error.message), { code: error.code });
      if (method === 'eth_requestAccounts') emit('accountsChanged', result);
      return result;
    },
    on(event, listener) {
      (listeners[event] ??= []).push(listener);
      return provider;
    },
    removeListener(event, listener) {
      listeners[event] = (listeners[event] ?? []).filter((l) => l !== listener);
      return provider;
    },
  };

  const detail = Object.freeze({ info: Object.freeze(info), provider });
  const announce = () => window.dispatchEvent(new CustomEvent('eip6963:announceProvider', { detail }));
  window.addEventListener('eip6963:requestProvider', announce);
  announce();
  if (!window.ethereum) window.ethereum = provider;
}

module.exports = { installWallet };
