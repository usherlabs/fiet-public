import { expect, it } from "vitest";
import {
  Address,
  Hex,
  encodeAbiParameters,
  encodeFunctionData,
  keccak256,
} from "viem";

import { loadEnv } from "../setup.js";
import { Opcode } from "../types.js";
import { describeE2E, makeClients } from "./testUtils.js";
import { MMPositionManagerABI } from "../abi/mmpm.js";
import {
  buildKernelUserOpForTarget,
  EntryPointV07ABI,
  KernelViewABI,
  permissionId32ToPermissionId4,
  permissionValidationId,
  signKernelDelegationAuthorization,
} from "../kernel7702.js";

describeE2E(
  "MMPositionManager write is gated by Kernel policies (7702 EOA-as-account)",
  () => {
    it("reverts (no write) when atomic facts fail, succeeds when they pass", async () => {
      const env = loadEnv();
      const { publicClient, walletClient } = await makeClients(env);

      /**
       * What this test is proving (end-to-end):
       *
       * - We submit a tx to `EntryPoint.handleOps(...)`, and the *sender account* is an EOA that has
       *   been upgraded via **EIP-7702 delegation** to run Kernel code.
       * - Kernel runs its permission pipeline and aggregates multiple policies:
       *   - CallPolicy (EVM): allowlist of (target, selector)
       *   - IntentPolicy (Stylus): atomic facts + envelope replay protection
       * - On success, the destination contract observes `msg.sender == EOA` (not a separate smart-account address).
       *
       * Why atomicity holds:
       * - The Intent Policy binds its signed envelope to `keccak256(userOp.callData)` (the Kernel `execute(...)` calldata).
       * - It then reads live chain state (via staticcalls) and evaluates the check programme.
       * - Only if those checks pass does EntryPoint proceed to execution.
       *
       * Uniswap v4 callback nuance (production note):
       * - Once MMPositionManager calls `poolManager.unlock`, the PoolManager calls back, so raw `msg.sender`
       *   in callbacks is PoolManager. Routers therefore use a “locker” (`msgSender()`) indirection.
       * - This infra test avoids unlock/callback flows; it focuses on the Kernel->MMPositionManager call boundary,
       *   which is the relevant boundary for `msg.sender` and policy gating.
       */

      // This test is only meaningful if:
      // - EntryPoint exists on the chain (we submit handleOps).
      // - MMPositionManager is the infra mock with a `writes()` counter (or a real deployment exposing a similar signal).
      const epCode = await publicClient.getCode({ address: env.entryPoint as Address });
      if (!epCode || epCode === "0x") {
        return;
      }

      const mmpmCode = await publicClient.getCode({
        address: env.mmPositionManager as Address,
      });
      if (!mmpmCode || mmpmCode === "0x") {
        return;
      }

      // If the EOA has already been upgraded and permission enabled (eg on a persistent chain),
      // we can skip enable-mode. For fresh devnets, enable-mode is required to install policies.
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
          // hook address(0) means not installed.
          // eslint-disable-next-line @typescript-eslint/no-unsafe-member-access
          const hook = (cfg as any).hook as Address;
          if (hook && hook !== "0x0000000000000000000000000000000000000000") {
            enablePermission = false;
          }
        } catch {
          // treat as not enabled (fresh EOA, or not yet delegated)
          enablePermission = true;
        }
      }

      const WritesABI = [
        {
          type: "function",
          name: "writes",
          stateMutability: "view",
          inputs: [],
          outputs: [{ type: "uint256" }],
        },
      ] as const;

      const LastSenderABI = [
        {
          type: "function",
          name: "lastSender",
          stateMutability: "view",
          inputs: [],
          outputs: [{ type: "address" }],
        },
      ] as const;

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

      // We don't need the full protocol calldata to prove the invariant.
      // It's enough to have a state-changing call on the allowlisted target.
      const actions = "0x20" as Hex; // MMActions.COMMIT_SIGNAL (any non-empty action byte is fine for infra mock)
      const params: readonly Hex[] = [
        // ABI encoding for (bytes liquiditySignal, address owner). For the infra mock, these are unused.
        encodeAbiParameters(
          [{ type: "bytes" }, { type: "address" }],
          ["0x", env.owner.address],
        ),
      ];
      const targetCallData = encodeFunctionData({
        abi: MMPositionManagerABI,
        functionName: "modifyLiquiditiesWithoutUnlock",
        args: [actions, [...params]],
      });
      const sender = env.owner.address as Address;

      // Snapshot writes before.
      const before = await publicClient.readContract({
        address: env.mmPositionManager as Address,
        abi: WritesABI,
        functionName: "writes",
      });

      // We use a deterministic pool id and set Slot0 tick out-of-bounds so the check fails.
      const poolId = keccak256("0x1234") as Hex;
      await walletClient.writeContract({
        address: env.stateView as Address,
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

      const now = (await publicClient.getBlock()).timestamp;
      const deadline = now + 3600n;

      // Build and submit the failing op via 7702 + Kernel permission pipeline.
      const { userOp: failOp } = await buildKernelUserOpForTarget({
          env,
          sender,
          target: env.mmPositionManager as Address,
          data: targetCallData,
          intentChecks: [
            {
              kind: Opcode.CheckSlot0TickBounds,
              poolId,
              min: -100,
              max: 100,
            },
          ],
          intentNonce: 0n,
          intentDeadline: deadline,
          enablePermission,
        });
      const failAuth = await signKernelDelegationAuthorization({ env, walletClient });

      const failTxData = encodeFunctionData({
        abi: EntryPointV07ABI,
        functionName: "handleOps",
        args: [[failOp], env.owner.address],
      });

      const failHash = await walletClient.sendTransaction({
        to: env.entryPoint as Address,
        data: failTxData,
        value: 0n,
        type: "eip7702",
        authorizationList: [failAuth],
      } as any);
      const failReceipt = await publicClient.waitForTransactionReceipt({
        hash: failHash,
      });
      expect(failReceipt.status).toBe("reverted");

      const afterFail = await publicClient.readContract({
        address: env.mmPositionManager as Address,
        abi: WritesABI,
        functionName: "writes",
      });
      expect(afterFail).toBe(before);

      // Now flip facts so the tick bounds check passes.
      await walletClient.writeContract({
        address: env.stateView as Address,
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

      const { userOp: passOp } = await buildKernelUserOpForTarget({
          env,
          sender,
          target: env.mmPositionManager as Address,
          data: targetCallData,
          intentChecks: [
            {
              kind: Opcode.CheckSlot0TickBounds,
              poolId,
              min: -100,
              max: 100,
            },
          ],
          intentNonce: 0n,
          intentDeadline: deadline,
          // If we successfully enabled above, we must not enable again.
          enablePermission: false,
        });
      const passAuth = await signKernelDelegationAuthorization({ env, walletClient });

      const passTxData = encodeFunctionData({
        abi: EntryPointV07ABI,
        functionName: "handleOps",
        args: [[passOp], env.owner.address],
      });

      const passHash = await walletClient.sendTransaction({
        to: env.entryPoint as Address,
        data: passTxData,
        value: 0n,
        type: "eip7702",
        authorizationList: [passAuth],
      } as any);
      const passReceipt = await publicClient.waitForTransactionReceipt({
        hash: passHash,
      });
      expect(passReceipt.status).toBe("success");

      const afterPass = await publicClient.readContract({
        address: env.mmPositionManager as Address,
        abi: WritesABI,
        functionName: "writes",
      });
      expect(afterPass).toBe(before + 1n);

      // Explicitly assert the “caller identity” property: MMPositionManager observed the EOA
      // as its caller when the write happened (because the EOA is delegated to Kernel via 7702).
      const lastSender = await publicClient.readContract({
        address: env.mmPositionManager as Address,
        abi: LastSenderABI,
        functionName: "lastSender",
      });
      expect(lastSender).toBe(env.owner.address);
    });
  },
);

