# The QA wallet helper

Read this only when `QA_EVM_KEY_FILE` is set. Never read the key itself.
`QA.md` says whether a repo opts in.

```js
const { installWallet } = require('qa-wallet');
// Before the dApp's first navigation. Context: every page; Page: that page.
const { address, rejectNext, waitForReceipt } = await installWallet(context, {
  keyFile: process.env.QA_EVM_KEY_FILE,
  rpcUrl: 'https://...',   // reads and eth_sendTransaction; omit for signing only
  chainId: 11155111,       // a number
  forwardRpc: [/^https:\/\/rpc\.example\//], // optional, from QA.md
});
rejectNext('eth_sendTransaction'); // the user declines the next one
rejectNext('eth_sendTransaction', { afterMs: 2000 }); // after a 2s look
await waitForReceipt(); // the last transaction it sent, once mined
```

It announces an EIP-1193 provider named "QA Wallet" (rdns `dev.qa.wallet`)
through EIP-6963 and sets `window.ethereum` when nothing else has. It answers
accounts, chain, `personal_sign`, `eth_signTypedData_v4`,
`wallet_switchEthereumChain` (to its own chain only) and
`eth_sendTransaction`, signing in Node; anything else goes to `rpcUrl`. The
key never enters the page.

`rejectNext(method)` makes the next request of that method fail as a user's
decline (`{ code: 4001, message: 'User rejected the request.' }`), once; call
it mid-run, e.g. after the approval and before the swap. It takes the
requests a user approves: `eth_requestAccounts`, `wallet_requestPermissions`,
`wallet_switchEthereumChain`, `personal_sign`, `eth_sign`,
`eth_signTypedData_v4`, `eth_sendTransaction`. A decline answered at once
can leave the dApp's pending state on screen for under a frame; `afterMs`
holds it long enough to record.

`waitForReceipt(hash?, { timeout })` resolves with `{ transactionHash,
status, blockNumber }` once the transaction is mined (`status` is `success`
or `reverted`), so a script waits on the chain, not on a guessed delay.
Without a hash it is the last one the wallet sent. In a session, the same two
controls are on the object `connect` returns.

`forwardRpc` answers the dApp's own JSON-RPC POSTs to matching URLs from
`rpcUrl`, for a dApp whose default RPC refuses headless traffic. `QA.md` says
when a host needs it.
