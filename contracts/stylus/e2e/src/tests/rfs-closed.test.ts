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
  makeBytes32Id,
  makePermissionId,
  simulateCheckUserOpPolicy,
} from "./testUtils.js";

describeE2E("RfS closed validation (e2e)", () => {
  it("fails when RfS open and passes when closed", async () => {
    const env = loadEnv();
    const permissionId = makePermissionId("rfs-closed");
    const callData = makeCallData("rfs-closed");
    const positionId = makeBytes32Id("position:rfs-closed") as Hex;

    await installIntentPolicy({ env, permissionId });

    // MockVTSOrchestrator is deployed by `just infra_deploy`.
    // The policy checks RfS closure by calling `positionToCheckpoint(positionId)` and reading `isOpen`.
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
    ] as const;

    const { walletClient, publicClient } = await makeClients(env);
    const block = await publicClient.getBlock();

    // 1) If RfS is open, the "closed" check must fail.
    await walletClient.writeContract({
      address: env.vtsOrchestrator,
      abi: MockVTSOrchestratorABI,
      functionName: "setCheckpoint",
      args: [
        positionId,
        {
          timeOfLastTransition: block.timestamp,
          isOpen: true,
          gracePeriodExtension0: 0n,
          gracePeriodExtension1: 0n,
        },
      ],
    });

    const fail = await simulateCheckUserOpPolicy({
      env,
      permissionId,
      wallet: env.owner.address,
      callData,
      checks: [{ kind: Opcode.CheckRfsClosed, positionId }],
      nonce: 0n,
      deadline: BigInt(Number.MAX_SAFE_INTEGER),
    });
    expect(fail).toBe(POLICY_FAILED);

    // 2) If RfS is closed, the check must pass.
    await walletClient.writeContract({
      address: env.vtsOrchestrator,
      abi: MockVTSOrchestratorABI,
      functionName: "setCheckpoint",
      args: [
        positionId,
        {
          timeOfLastTransition: block.timestamp,
          isOpen: false,
          gracePeriodExtension0: 0n,
          gracePeriodExtension1: 0n,
        },
      ],
    });

    const pass = await simulateCheckUserOpPolicy({
      env,
      permissionId,
      wallet: env.owner.address,
      callData,
      checks: [{ kind: Opcode.CheckRfsClosed, positionId }],
      nonce: 0n,
      deadline: BigInt(Number.MAX_SAFE_INTEGER),
    });
    expect(pass).toBe(POLICY_SUCCESS);
  });
});

