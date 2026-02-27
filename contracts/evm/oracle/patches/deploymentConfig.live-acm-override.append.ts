// FIET_PATCH_LIVE_ACM_OVERRIDE
//
// Purpose:
// - Enable MODE=LIVE deployments to use a freshly deployed AccessControlManager (ACM) on a live network
//   without modifying the `contracts/evm/lib/oracle` submodule source.
//
// Operation:
// - `just deploy-oracle` (MODE=LIVE) deploys ACM first, then sets `LIVE_ACM_ADDRESS=<addr>` and `MODE=LIVE`
//   for the subsequent Hardhat deploy step.
// - This snippet is appended into `lib/oracle/helpers/deploymentConfig.ts` after the submodule is loaded.
// - When oracle deploy scripts import `ADDRESSES`, this code overrides `ADDRESSES[HARDHAT_NETWORK].acm`.
//
// Notes:
// - This is appended into a TypeScript module that already defines `ADDRESSES`.
// - Wrapped in an IIFE to avoid leaking identifiers into the module scope.
(() => {
  const hardhatNetwork = process.env.HARDHAT_NETWORK;
  const liveAcmAddress = process.env.LIVE_ACM_ADDRESS;
  const mode = (process.env.MODE || "").toUpperCase();

  if (mode !== "LIVE" || !hardhatNetwork || !liveAcmAddress) return;

  const entry = (ADDRESSES as any)[hardhatNetwork];
  if (!entry) {
    throw new Error(`FIET_PATCH_LIVE_ACM_OVERRIDE failed: unknown network '${hardhatNetwork}'`);
  }

  entry.acm = liveAcmAddress;
  // eslint-disable-next-line no-console
  console.log(`[deploymentConfig] FIET_PATCH_LIVE_ACM_OVERRIDE active: ${hardhatNetwork} -> ${liveAcmAddress}`);
})();

