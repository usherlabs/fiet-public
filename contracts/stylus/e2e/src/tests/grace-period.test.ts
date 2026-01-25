import { expect, it } from "vitest";
import { Hex } from "viem";

import { Opcode } from "../types.js";
import { loadEnv } from "../setup.js";
import {
  POLICY_FAILED,
  POLICY_SUCCESS,
  describeE2E,
  installIntentPolicy,
  makeClients,
  makeCallData,
  makePermissionId,
  simulateCheckUserOpPolicy,
} from "./testUtils.js";

describeE2E("grace period remaining validation (e2e)", () => {
  it("fails when remaining grace period is below threshold", async () => {
    const env = loadEnv();
    const permissionId = makePermissionId("grace-period");
    const callData = makeCallData("grace-period");
    const positionId = makePermissionId("position:grace-period") as Hex;
    const poolId = makePermissionId("pool:grace-period") as Hex;

    await installIntentPolicy({ env, permissionId });

    const MockVTSOrchestratorABI = [
      {
        type: "function",
        name: "setCheckpoint",
        stateMutability: "nonpayable",
        inputs: [
          { name: "positionId", type: "bytes32" },
          {
            name: "c",
            type: "tuple",
            components: [
              { name: "timeOfLastTransition", type: "uint256" },
              { name: "isOpen", type: "bool" },
              { name: "gracePeriodExtension0", type: "uint256" },
              { name: "gracePeriodExtension1", type: "uint256" },
            ],
          },
        ],
        outputs: [],
      },
      {
        type: "function",
        name: "setPosition",
        stateMutability: "nonpayable",
        inputs: [
          { name: "positionId", type: "bytes32" },
          { name: "owner", type: "address" },
          { name: "poolId", type: "bytes32" },
        ],
        outputs: [],
      },
      {
        type: "function",
        name: "setPool",
        stateMutability: "nonpayable",
        inputs: [
          { name: "poolId", type: "bytes32" },
          { name: "grace0", type: "uint256" },
          { name: "grace1", type: "uint256" },
          { name: "isPaused", type: "bool" },
        ],
        outputs: [],
      },
    ] as const;

    const { walletClient, publicClient } = await makeClients(env);
    const block = await publicClient.getBlock();
    const now = block.timestamp;

    // Arrange a position in an "open RfS" checkpoint, so grace period is finite (not u64::MAX).
    // `grace_period_remaining` computes:
    // remaining = min(grace0+ext0, grace1+ext1) - (now - timeOfLastTransition), clamped at 0.
    //
    // We set grace=100s, elapsed=95s => remaining ≈ 5s.
    await walletClient.writeContract({
      address: env.vtsOrchestrator,
      abi: MockVTSOrchestratorABI,
      functionName: "setPool",
      args: [poolId, 100n, 100n, false],
    });
    await walletClient.writeContract({
      address: env.vtsOrchestrator,
      abi: MockVTSOrchestratorABI,
      functionName: "setPosition",
      args: [positionId, env.owner.address, poolId],
    });
    await walletClient.writeContract({
      address: env.vtsOrchestrator,
      abi: MockVTSOrchestratorABI,
      functionName: "setCheckpoint",
      args: [
        positionId,
        {
          timeOfLastTransition: now - 95n,
          isOpen: true,
          gracePeriodExtension0: 0n,
          gracePeriodExtension1: 0n,
        },
      ],
    });

    // Remaining ≈ 5s, but we require >= 10s => should fail.
    const fail = await simulateCheckUserOpPolicy({
      env,
      permissionId,
      wallet: env.owner.address,
      callData,
      checks: [{ kind: Opcode.CheckGracePeriodGte, positionId, minSeconds: 10n }],
      nonce: 0n,
      deadline: BigInt(Number.MAX_SAFE_INTEGER),
    });
    expect(fail).toBe(POLICY_FAILED);

    // If we lower the threshold to 1s, it should pass.
    const pass = await simulateCheckUserOpPolicy({
      env,
      permissionId,
      wallet: env.owner.address,
      callData,
      checks: [{ kind: Opcode.CheckGracePeriodGte, positionId, minSeconds: 1n }],
      nonce: 0n,
      deadline: BigInt(Number.MAX_SAFE_INTEGER),
    });
    expect(pass).toBe(POLICY_SUCCESS);
  });
});

