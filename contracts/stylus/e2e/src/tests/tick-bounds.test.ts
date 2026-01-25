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

describeE2E("tick bounds validation (e2e)", () => {
  it("fails when tick out of bounds and passes when within bounds", async () => {
    const env = loadEnv();
    const permissionId = makePermissionId("tick-bounds");
    const callData = makeCallData("tick-bounds");
    const poolId = makePermissionId("pool:tick-bounds") as Hex;

    await installIntentPolicy({ env, permissionId });

    // MockStateView is deployed by `just infra_deploy` and wired into `e2e/.env`.
    // We set Slot0 directly so the policy's staticcall-based facts provider has deterministic inputs.
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

    // 1) Out-of-bounds tick should fail closed.
    await walletClient.writeContract({
      address: env.stateView,
      abi: MockStateViewABI,
      functionName: "setSlot0",
      args: [
        poolId,
        {
          sqrtPriceX96: 79228162514264337593543950336n,
          tick: 250,
          protocolFee: 0,
          lpFee: 0,
        },
      ],
    });

    const fail = await simulateCheckUserOpPolicy({
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
    expect(fail).toBe(POLICY_FAILED);

    // 2) In-bounds tick should pass.
    await walletClient.writeContract({
      address: env.stateView,
      abi: MockStateViewABI,
      functionName: "setSlot0",
      args: [
        poolId,
        {
          sqrtPriceX96: 79228162514264337593543950336n,
          tick: 10,
          protocolFee: 0,
          lpFee: 0,
        },
      ],
    });

    const pass = await simulateCheckUserOpPolicy({
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
    expect(pass).toBe(POLICY_SUCCESS);
  });
});

