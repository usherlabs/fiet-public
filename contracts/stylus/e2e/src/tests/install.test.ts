import { expect, it } from "vitest";
import { loadEnv } from "../setup.js";
import { IntentPolicyABI } from "../abi/intent-policy.js";
import {
  describeE2E,
  installIntentPolicy,
  makeClients,
  makeCallData,
  makePermissionId,
  POLICY_FAILED,
  simulateCheckUserOpPolicy,
  uninstallIntentPolicy,
} from "./testUtils.js";

describeE2E("intent validator install/uninstall (e2e)", () => {
  it("installs policy instance and toggles initialisation", async () => {
    const env = loadEnv();
    const permissionId = makePermissionId("install-toggle");
    const { publicClient } = await makeClients(env);
    const callData = makeCallData("install-toggle");

    // What we're testing:
    // - `onInstall` should initialise storage for `(wallet, permissionId)` and increment `used_ids[wallet]`.
    // - `onUninstall` should remove that instance and decrement `used_ids[wallet]`.
    //
    // Why it matters:
    // Kernel policies are instance-scoped by `(wallet, permissionId)`. If install/uninstall is broken,
    // the policy may either fail closed (bricking the permission) or fail open (bypassing checks).
    await installIntentPolicy({ env, permissionId });
    const afterInstall = await publicClient.readContract({
      address: env.intentPolicy,
      abi: IntentPolicyABI,
      functionName: "isInitialized",
      args: [env.owner.address],
    });
    expect(afterInstall).toBe(true);

    await uninstallIntentPolicy({ env, permissionId });

    // We avoid asserting `isInitialized(wallet) == false` here because other tests may have installed
    // additional permission ids for the same wallet (which keeps `used_ids[wallet] > 0`).
    //
    // The meaningful security property is: after uninstall, *this* `(wallet, permissionId)` instance
    // should fail closed.
    const afterUninstall = await simulateCheckUserOpPolicy({
      env,
      permissionId,
      wallet: env.owner.address,
      callData,
      checks: [],
      nonce: 0n,
      deadline: BigInt(Number.MAX_SAFE_INTEGER),
    });
    expect(afterUninstall).toBe(POLICY_FAILED);
  });
});

