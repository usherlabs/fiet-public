import { expect, it } from "vitest";
import { Address, Hex, encodeFunctionData, keccak256 } from "viem";

import { loadEnv } from "../setup.js";
import { describeE2E, makeClients } from "./testUtils.js";
import {
  buildKernelUserOpForTarget,
  EntryPointV07ABI,
  KernelViewABI,
  permissionId32ToPermissionId4,
  permissionValidationId,
  signKernelDelegationAuthorization,
} from "../kernel7702.js";

describeE2E("policy aggregation: CallPolicy can block even when IntentPolicy passes", () => {
  it("reverts when CallPolicy disallows the call (IntentPolicy passes)", async () => {
    const env = loadEnv();
    const { publicClient, walletClient } = await makeClients(env);

    const epCode = await publicClient.getCode({ address: env.entryPoint as Address });
    if (!epCode || epCode === "0x") return;
    const svCode = await publicClient.getCode({ address: env.stateView as Address });
    if (!svCode || svCode === "0x") return;

    // Detect whether the permission is already enabled for this EOA.
    let enablePermission = true;
    const eoaCode = await publicClient.getCode({ address: env.owner.address });
    if (eoaCode && eoaCode !== "0x") {
      try {
        const permissionId4 = permissionId32ToPermissionId4(env.permissionId);
        const vId = permissionValidationId(permissionId4);
        const cfg = await publicClient.readContract({
          address: env.owner.address,
          abi: KernelViewABI,
          functionName: "validationConfig",
          args: [vId as any],
        });
        // eslint-disable-next-line @typescript-eslint/no-unsafe-member-access
        const hook = (cfg as any).hook as Address;
        if (hook && hook !== "0x0000000000000000000000000000000000000000") {
          enablePermission = false;
        }
      } catch {
        enablePermission = true;
      }
    }

    // This call is *not* allowlisted by CallPolicy (we only allow MMPositionManager + PositionManager selectors).
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

    const poolId = keccak256("0xdead") as Hex;
    const targetCallData = encodeFunctionData({
      abi: MockStateViewABI,
      functionName: "setSlot0",
      args: [
        poolId,
        {
          sqrtPriceX96: 79228162514264337593543950336n,
          tick: 0,
          protocolFee: 0,
          lpFee: 0,
        },
      ],
    });

    const now = (await publicClient.getBlock()).timestamp;
    const deadline = now + 3600n;

    const { userOp } = await buildKernelUserOpForTarget({
      env,
      sender: env.owner.address as Address,
      target: env.stateView as Address,
      data: targetCallData,
      // Empty programme => IntentPolicy should pass (it still binds to callBundleHash).
      intentChecks: [],
      intentNonce: 0n,
      intentDeadline: deadline,
      enablePermission,
    });

    const auth = await signKernelDelegationAuthorization({ env, walletClient });

    const txData = encodeFunctionData({
      abi: EntryPointV07ABI,
      functionName: "handleOps",
      args: [[userOp], env.owner.address],
    });

    const hash = await walletClient.sendTransaction({
      to: env.entryPoint as Address,
      data: txData,
      value: 0n,
      type: "eip7702",
      authorizationList: [auth],
    } as any);

    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    expect(receipt.status).toBe("reverted");
  });
});

