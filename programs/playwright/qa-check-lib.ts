// What the two checks.qa scripts share.
import http from "node:http";
import type { AddressInfo } from "node:net";

export type Listening = { url: string; close: () => void };

export const SEPOLIA = 11155111;

// The page a wagmi or AppKit dApp would be, reduced to EIP-6963 discovery.
export const DISCOVERY_SCRIPT = `<script>
  window.found = [];
  window.addEventListener('eip6963:announceProvider', (e) => window.found.push(e.detail));
  window.dispatchEvent(new Event('eip6963:requestProvider'));
</script>`;

/** An HTTP server on a free loopback port. */
export async function listen(
  handler: http.RequestListener,
): Promise<Listening> {
  const server = http.createServer(handler);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  return { url: `http://127.0.0.1:${port}/`, close: () => server.close() };
}

/** Runs a check script's `main`, failing the process on a throw. */
export function runCheck(main: () => Promise<void>): void {
  main().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}
