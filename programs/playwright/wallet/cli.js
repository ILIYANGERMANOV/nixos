#!/usr/bin/env node
// `qa-wallet address` prints the QA Wallet's address, derived from the key at
// QA_EVM_KEY_FILE; `qa-wallet balance --rpc <url> [--erc20 <address>]...`
// also prints its native and ERC-20 balances. Neither prints the key or its
// path. Exits 1 when the wallet is unavailable (no QA_EVM_KEY_FILE).
'use strict';

const { createPublicClient, http, erc20Abi, formatEther, formatUnits } = require('viem');
const { walletAddress } = require('./index.js');

async function main([command, ...args]) {
  const keyFile = process.env.QA_EVM_KEY_FILE;
  if (!keyFile) return fail('qa-wallet: unavailable, QA_EVM_KEY_FILE is not set');
  const address = addressOf(keyFile);
  switch (command) {
    case 'address':
      return console.log(address);
    case 'balance':
      return printBalances(address, parseBalanceArgs(args));
    default:
      return fail('usage: qa-wallet address | qa-wallet balance --rpc <url> [--erc20 <address>]...');
  }
}

// readKey's errors name the key file; the command names only the variable.
function addressOf(keyFile) {
  try {
    return walletAddress(keyFile);
  } catch (error) {
    return fail(error.message.replaceAll(keyFile, '$QA_EVM_KEY_FILE'));
  }
}

function parseBalanceArgs(args) {
  const options = { rpc: null, erc20: [] };
  for (let i = 0; i < args.length; i += 2) {
    const [flag, value] = [args[i], args[i + 1]];
    if (flag === '--rpc') options.rpc = value;
    else if (flag === '--erc20') options.erc20.push(value);
    else fail(`qa-wallet: unknown option ${flag}`);
  }
  if (!options.rpc) fail('qa-wallet: balance needs --rpc <url>');
  return options;
}

async function printBalances(address, { rpc, erc20 }) {
  const client = createPublicClient({ transport: http(rpc) });
  console.log(`address ${address}`);
  console.log(`native ${formatEther(await client.getBalance({ address }))}`);
  for (const token of erc20) {
    const read = (functionName, args = []) => client.readContract({ address: token, abi: erc20Abi, functionName, args });
    const [symbol, decimals, balance] = await Promise.all([read('symbol'), read('decimals'), read('balanceOf', [address])]);
    console.log(`${symbol} ${formatUnits(balance, decimals)} (${token})`);
  }
}

function fail(message) {
  console.error(message);
  process.exit(1);
}

main(process.argv.slice(2)).catch((error) => fail(`qa-wallet: ${error.shortMessage ?? error.message}`));
