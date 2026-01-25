import { expect, it } from "vitest";
import { Hex, keccak256 } from "viem";

import { Opcode } from "../types.js";
import {
  POLICY_FAILED,
  POLICY_SUCCESS,
  describeE2E,
  installIntentPolicy,
  makeCallData,
  makePackedUserOp,
  makePermissionId,
  makeClients,
  simulateCheckUserOpPolicy,
  uninstallIntentPolicy,
} from "./testUtils.js";
import { buildSignedEnvelope, loadEnv } from "../setup.js";
import { IntentPolicyABI } from "../abi/intent-policy.js";

describeE2E("7702 Intent Policy — full-suite (policy-level E2E)", () => {
  it("fails when not installed (wallet, permissionId) gating", async () => {
    const env = loadEnv();
    const permissionId = makePermissionId("not-installed");
    const callData = makeCallData("not-installed");

    // This verifies the policy's *first* line of defence: unless the policy instance has been
    // installed for this `(wallet, permissionId)`, the policy fails closed without attempting
    // to parse or authenticate any envelope bytes.
    const result = await simulateCheckUserOpPolicy({
      env,
      permissionId,
      wallet: env.owner.address,
      callData,
      checks: [],
      nonce: 0n,
      deadline: BigInt(Number.MAX_SAFE_INTEGER),
    });

    expect(result).toBe(POLICY_FAILED);
  });

  it("rejects expired deadline (prevents stale intents)", async () => {
    const env = loadEnv();
    const permissionId = makePermissionId("expired-deadline");
    const callData = makeCallData("expired-deadline");

    await installIntentPolicy({ env, permissionId });

    const { publicClient } = await makeClients(env);
    const block = await publicClient.getBlock();
    const now = block.timestamp;

    // The envelope carries a `deadline` to bound how long a signed intent remains valid.
    // Without this, a user could sign an intent once and it would remain replayable forever.
    const result = await simulateCheckUserOpPolicy({
      env,
      permissionId,
      wallet: env.owner.address,
      callData,
      checks: [],
      nonce: 0n,
      deadline: now - 1n,
    });

    expect(result).toBe(POLICY_FAILED);
  });

  it("rejects call bundle hash mismatch (binds policy payload to exact callData)", async () => {
    const env = loadEnv();
    const permissionId = makePermissionId("bundle-mismatch");
    const callData = makeCallData("bundle-mismatch:callData");

    await installIntentPolicy({ env, permissionId });

    // The policy binds the signed envelope to `keccak256(userOp.callData)`.
    // Purpose: if the envelope only authenticated the policy program and not the execution payload,
    // an attacker could swap `callData` while reusing a previously-signed, benign envelope.
    const result = await simulateCheckUserOpPolicy({
      env,
      permissionId,
      wallet: env.owner.address,
      callData,
      checks: [],
      nonce: 0n,
      deadline: BigInt(Number.MAX_SAFE_INTEGER),
      callBundleHashOverride: makeCallData("bundle-mismatch:wrongHash"),
    });

    expect(result).toBe(POLICY_FAILED);
  });

  it("rejects invalid envelope signature (prevents policy-local slice tampering)", async () => {
    const env = loadEnv();
    const permissionId = makePermissionId("invalid-signature");
    const callData = makeCallData("invalid-signature");

    await installIntentPolicy({ env, permissionId });

    // The policy-local envelope is *not* covered by the PermissionValidator's signer.
    // If we didn't authenticate this envelope separately, an attacker could tamper with it
    // (eg, replace `programBytes` with an empty program) without invalidating the UserOp signature.
    //
    // This test signs the envelope with the wrong key, so ecrecover != configured signer.
    const wrongKey = (`0x${"11".repeat(32)}`) as Hex;
    const result = await simulateCheckUserOpPolicy({
      env,
      permissionId,
      wallet: env.owner.address,
      callData,
      checks: [],
      nonce: 0n,
      deadline: BigInt(Number.MAX_SAFE_INTEGER),
      envelopeSignerPrivateKey: wrongKey,
    });

    expect(result).toBe(POLICY_FAILED);
  });

  it("consumes nonce on success (replay protection)", async () => {
    const env = loadEnv();
    const permissionId = makePermissionId("nonce-consumption");
    const callData = makeCallData("nonce-consumption");

    await installIntentPolicy({ env, permissionId });

    const { publicClient, walletClient } = await makeClients(env);
    const block = await publicClient.getBlock();
    const deadline = block.timestamp + 3600n;

    // Precondition: nonce=0 should validate successfully.
    const before = await simulateCheckUserOpPolicy({
      env,
      permissionId,
      wallet: env.owner.address,
      callData,
      checks: [],
      nonce: 0n,
      deadline,
    });
    expect(before).toBe(POLICY_SUCCESS);

    // Execute as a state-changing tx so the policy can persist nonce consumption.
    //
    // Note: this is a policy-level E2E: we're directly calling `checkUserOpPolicy` to observe
    // the policy's storage behaviour. In production, this state change happens during EntryPoint
    // validation when Kernel runs the permission pipeline.
    const envelope0 = await buildSignedEnvelope({
      env,
      smartAccount: env.owner.address,
      permissionId,
      checks: [],
      callBundleHash: keccak256(callData),
      nonce: 0n,
      deadline,
    });
    const userOp = makePackedUserOp({
      sender: env.owner.address,
      callData,
      signature: envelope0,
    });
    await walletClient.writeContract({
      address: env.intentPolicy,
      abi: IntentPolicyABI,
      functionName: "checkUserOpPolicy",
      args: [permissionId, userOp],
    });

    // After nonce consumption, the same (nonce=0) envelope must now fail.
    const after = await simulateCheckUserOpPolicy({
      env,
      permissionId,
      wallet: env.owner.address,
      callData,
      checks: [],
      nonce: 0n,
      deadline,
    });
    expect(after).toBe(POLICY_FAILED);

    // And the next nonce should validate.
    const next = await simulateCheckUserOpPolicy({
      env,
      permissionId,
      wallet: env.owner.address,
      callData,
      checks: [],
      nonce: 1n,
      deadline,
    });
    expect(next).toBe(POLICY_SUCCESS);
  });

  it("runs a real check program: Slot0 tick bounds (happy path)", async () => {
    const env = loadEnv();
    const permissionId = makePermissionId("tick-bounds:pass");
    const callData = makeCallData("tick-bounds:pass");

    await installIntentPolicy({ env, permissionId });

    // We purposely use the infra-deployed MockStateView, because the policy reads on-chain facts
    // via strict staticcall allowlists. This keeps the test deterministic and fast.
    const MockStateViewABI = [
      {
        type: "function",
        name: "setSlot0",
        stateMutability: "nonpayable",
        inputs: [
          { name: "poolId", type: "bytes32" },
          {
            name: "s",
            type: "tuple",
            components: [
              { name: "sqrtPriceX96", type: "uint160" },
              { name: "tick", type: "int24" },
              { name: "protocolFee", type: "uint24" },
              { name: "lpFee", type: "uint24" },
            ],
          },
        ],
        outputs: [],
      },
    ] as const;

    const { walletClient } = await makeClients(env);
    const poolId = makePermissionId("pool:tick-bounds") as Hex;

    // Arrange: set the pool tick inside bounds.
    await walletClient.writeContract({
      address: env.stateView,
      abi: MockStateViewABI,
      functionName: "setSlot0",
      args: [
        poolId,
        {
          sqrtPriceX96: 79228162514264337593543950336n, // 1:1
          tick: 10,
          protocolFee: 0,
          lpFee: 0,
        },
      ],
    });

    const result = await simulateCheckUserOpPolicy({
      env,
      permissionId,
      wallet: env.owner.address,
      callData,
      checks: [
        {
          kind: Opcode.CheckSlot0TickBounds,
          poolId,
          min: -100,
          max: 100,
        },
      ],
      nonce: 0n,
      deadline: BigInt(Number.MAX_SAFE_INTEGER),
    });

    expect(result).toBe(POLICY_SUCCESS);
  });

  it("uninstall removes initialisation for that permission id (clean teardown)", async () => {
    const env = loadEnv();
    const permissionId = makePermissionId("install-uninstall");
    const callData = makeCallData("install-uninstall");

    const { publicClient } = await makeClients(env);

    // Start from a known state: install, verify initialised, uninstall, verify not initialised.
    await installIntentPolicy({ env, permissionId });
    const init1 = await publicClient.readContract({
      address: env.intentPolicy,
      abi: IntentPolicyABI,
      functionName: "isInitialized",
      args: [env.owner.address],
    });
    expect(init1).toBe(true);

    await uninstallIntentPolicy({ env, permissionId });

    // The key property: after uninstall, this permission instance must fail closed.
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

