// `qa-wallet address` prints the QA Wallet's address, derived from the key at
// QA_EVM_KEY_FILE; `qa-wallet balance --rpc <url> [--erc20 <address>]...`
// also prints its native and ERC-20 balances. Neither prints the key or its
// path. Exits 1 when the wallet is unavailable (no QA_EVM_KEY_FILE).
import {
  type Address,
  createPublicClient,
  erc20Abi,
  formatEther,
  formatUnits,
  http,
  isAddress,
} from "viem";
import { walletAddress } from "./index.js";

const USAGE =
  "usage: qa-wallet address | qa-wallet balance --rpc <url> [--erc20 <address>]...";

type BalanceArgs = { rpc: string; erc20: Address[] };

async function main([command, ...args]: string[]): Promise<void> {
  const keyFile = process.env.QA_EVM_KEY_FILE;
  if (!keyFile) fail("qa-wallet: unavailable, QA_EVM_KEY_FILE is not set");
  const address = addressOf(keyFile);
  switch (command) {
    case "address":
      console.log(address);
      return;
    case "balance":
      return printBalances(address, parseBalanceArgs(args));
    default:
      fail(USAGE);
  }
}

// readKey's errors name the key file; the command names only the variable.
function addressOf(keyFile: string): Address {
  try {
    return walletAddress(keyFile);
  } catch (error) {
    fail((error as Error).message.replaceAll(keyFile, "$QA_EVM_KEY_FILE"));
  }
}

function parseBalanceArgs(args: string[]): BalanceArgs {
  let rpc: string | undefined;
  const erc20: Address[] = [];
  for (let i = 0; i < args.length; i += 2) {
    const [flag, value] = [args[i], args[i + 1]];
    if (flag === "--rpc") rpc = value;
    else if (flag === "--erc20") erc20.push(parseAddress(value));
    else fail(`qa-wallet: unknown option ${flag}`);
  }
  if (!rpc) fail("qa-wallet: balance needs --rpc <url>");
  return { rpc, erc20 };
}

function parseAddress(value: string | undefined): Address {
  if (value !== undefined && isAddress(value)) return value;
  fail(`qa-wallet: --erc20 needs an address\n${USAGE}`);
}

async function printBalances(
  address: Address,
  { rpc, erc20 }: BalanceArgs,
): Promise<void> {
  const client = createPublicClient({ transport: http(rpc) });
  console.log(`address ${address}`);
  console.log(`native ${formatEther(await client.getBalance({ address }))}`);
  for (const token of erc20) {
    const contract = { address: token, abi: erc20Abi };
    const [symbol, decimals, balance] = await Promise.all([
      client.readContract({ ...contract, functionName: "symbol" }),
      client.readContract({ ...contract, functionName: "decimals" }),
      client.readContract({
        ...contract,
        functionName: "balanceOf",
        args: [address],
      }),
    ]);
    console.log(`${symbol} ${formatUnits(balance, decimals)} (${token})`);
  }
}

function fail(message: string): never {
  console.error(message);
  process.exit(1);
}

main(process.argv.slice(2)).catch((error: Error & { shortMessage?: string }) =>
  fail(`qa-wallet: ${error.shortMessage ?? error.message}`),
);
