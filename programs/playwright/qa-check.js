// checks.qa, run by `qa-node`: the wallet helper against a synthetic dApp
// served from a Playwright route, with a key generated for this run, and a
// recorded video through `qa-mp4`. No network: the dApp origin never resolves
// and the wallet gets no rpcUrl.
'use strict';

const assert = require('assert');
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');
const { verifyMessage, verifyTypedData } = require('viem');
const { generatePrivateKey } = require('viem/accounts');
const { installWallet } = require('qa-wallet');

const work = process.argv[2];
const SEPOLIA = 11155111;
const DAPP = 'http://dapp.test/';

// The page a wagmi or AppKit dApp would be, reduced to EIP-6963 discovery.
const DAPP_HTML = `<!doctype html><title>dApp</title><p>dApp</p><script>
  window.found = [];
  window.addEventListener('eip6963:announceProvider', (e) => window.found.push(e.detail));
  window.dispatchEvent(new Event('eip6963:requestProvider'));
</script>`;

const TYPED_DATA = {
  domain: { name: 'QA', version: '1', chainId: SEPOLIA },
  types: { Greeting: [{ name: 'text', type: 'string' }] },
  primaryType: 'Greeting',
  message: { text: 'hello' },
};

async function main() {
  const key = generatePrivateKey();
  const keyFile = path.join(work, 'key');
  fs.writeFileSync(keyFile, `${key}\n`, { mode: 0o600 });
  const videos = path.join(work, 'videos');

  const browser = await chromium.launch();
  const context = await browser.newContext({ recordVideo: { dir: videos } });
  const logs = [];
  context.on('console', (message) => logs.push(message.text()));
  await context.route(DAPP, (route) => route.fulfill({ contentType: 'text/html', body: DAPP_HTML }));
  const { address, rejectNext } = await installWallet(context, { keyFile, chainId: SEPOLIA });

  const page = await context.newPage();
  page.on('pageerror', (error) => logs.push(String(error)));
  await page.goto(DAPP);

  // Given the dApp asked for providers, when the wallet answered,
  // then the QA wallet answered, and nothing else did.
  const announced = await page.evaluate(() => window.found.map((d) => d.info));
  assert.deepStrictEqual(announced.map((i) => i.rdns), ['dev.qa.wallet']);
  assert.ok(announced[0].uuid && announced[0].name && announced[0].icon.startsWith('data:image/'));

  const call = (method, params) =>
    page.evaluate(
      async ([method, params]) => {
        const { provider } = window.found[0];
        try {
          return { result: await provider.request({ method, params }) };
        } catch (error) {
          return { error: { code: error.code, message: error.message } };
        }
      },
      [method, params],
    );

  // Connect, as wagmi's injected connector does.
  assert.deepStrictEqual((await call('eth_requestAccounts')).result, [address]);
  assert.strictEqual((await call('eth_chainId')).result, '0xaa36a7');

  // personal_sign takes hex data and the address; the signature verifies.
  const message = 'Sign in to the QA dApp';
  const signature = (await call('personal_sign', [`0x${Buffer.from(message).toString('hex')}`, address])).result;
  assert.ok(await verifyMessage({ address, message, signature }), 'personal_sign does not verify');

  const typed = (await call('eth_signTypedData_v4', [address, JSON.stringify(TYPED_DATA)])).result;
  assert.ok(await verifyTypedData({ address, signature: typed, ...TYPED_DATA }), 'typed data does not verify');

  // Given the user will decline the next signature, when the dApp asks twice,
  // then the first is rejected as a user would and the second is signed.
  rejectNext('personal_sign');
  const declined = await call('personal_sign', [`0x${Buffer.from(message).toString('hex')}`, address]);
  assert.deepStrictEqual(declined.error, { code: 4001, message: 'User rejected the request.' });
  const signedAfter = (await call('personal_sign', [`0x${Buffer.from(message).toString('hex')}`, address])).result;
  assert.ok(await verifyMessage({ address, message, signature: signedAfter }), 'the request after a decline is not signed');

  // A decline is per method, and reaches a transaction before any network.
  rejectNext('eth_sendTransaction');
  assert.strictEqual((await call('eth_signTypedData_v4', [address, JSON.stringify(TYPED_DATA)])).result, typed);
  assert.strictEqual((await call('eth_sendTransaction', [{ to: address }])).error.code, 4001);
  assert.strictEqual((await call('eth_sendTransaction', [{ to: address }])).error.code, 4200);
  assert.throws(() => rejectNext('eth_blockNumber'), /cannot decline/);

  // Without an rpcUrl, reads fail as unsupported instead of reaching a network.
  assert.strictEqual((await call('eth_blockNumber')).error.code, 4200);
  assert.strictEqual((await call('wallet_switchEthereumChain', [{ chainId: '0x1' }])).error.code, 4902);

  // The key is nowhere the page can reach: not the DOM, not any global, not
  // the provider's source, not a console line.
  const pageText = await page.evaluate(() => {
    const parts = [document.documentElement.outerHTML];
    for (const name of Object.getOwnPropertyNames(window)) {
      try {
        const value = window[name];
        parts.push(typeof value === 'function' ? String(value) : JSON.stringify(value));
      } catch {
        // Cross-origin or cyclic globals are not where a key would hide.
      }
    }
    const { provider } = window.found[0];
    parts.push(...Object.values(provider).map(String));
    return parts.join('\n');
  });
  const bareKey = key.slice(2);
  assert.ok(!pageText.includes(bareKey), 'the private key is visible to the page');
  assert.ok(!logs.join('\n').includes(bareKey), 'the private key reached a console line');

  const video = page.video();
  await context.close();
  await browser.close();

  // The recording transcodes to an H.264 mp4 GitHub plays inline.
  const mp4 = path.join(work, 'proof.mp4');
  execFileSync('qa-mp4', [await video.path(), mp4], { stdio: 'inherit' });
  const codec = execFileSync('ffprobe', [
    '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=codec_name',
    '-of', 'default=noprint_wrappers=1:nokey=1', mp4,
  ]).toString().trim();
  assert.strictEqual(codec, 'h264');

  console.log('qa: wallet and video pipeline ok');
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
