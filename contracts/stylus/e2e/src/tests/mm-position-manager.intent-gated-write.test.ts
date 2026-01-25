import { expect, it } from "vitest";
import {
  Address,
  Hex,
  concatHex,
  encodeAbiParameters,
  encodeFunctionData,
  keccak256,
} from "viem";
import { entryPoint07Abi, toPackedUserOperation } from "viem/account-abstraction";

import { loadEnv, buildKernelClient, buildSignedEnvelope } from "../setup.js";
import { Opcode } from "../types.js";
import { describeE2E, makeClients } from "./testUtils.js";
import { MMPositionManagerABI } from "../abi/mmpm.js";

describeE2E(
  "MMPositionManager write is gated by Intent Policy (end-to-end UserOp)",
  () => {
    it("reverts (no write) when atomic facts fail, succeeds when they pass", async () => {
      const env = loadEnv();
      const { publicClient, walletClient, account, entryPoint } =
        await buildKernelClient(env);

      /**
       * What this test is proving (end-to-end):
       *
       * - The on-chain *transaction* we submit is to `EntryPoint.handleOps(...)`.
       * - The on-chain *state change* we care about is inside `MMPositionManager.modifyLiquidities*`.
       * - The Intent Policy contract is *not* an executor/routing contract. It is a validator:
       *   during Kernel validation, PermissionValidator calls `IntentPolicy.checkUserOpPolicy(...)`.
       *
       * Why atomicity holds:
       * - The Intent Policy binds its signed envelope to `keccak256(userOp.callData)` (the Kernel wallet callData).
       * - It then reads live chain state (via staticcalls) and evaluates the check programme.
       * - Only if those checks pass does EntryPoint proceed to execution.
       *
       * msg.sender expectations:
       * - `EntryPoint.handleOps` is called by a bundler/EOA (tx.sender).
       * - EntryPoint then calls the *Kernel wallet* to execute the UserOp.
       * - The Kernel wallet calls `MMPositionManager`, so inside `MMPositionManager` we expect:
       *     `msg.sender == <Kernel wallet address>`
       *   (not EntryPoint, and not the Intent Policy).
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
      const epCode = await publicClient.getCode({ address: entryPoint.address });
      if (!epCode || epCode === "0x") {
        return;
      }

      const mmpmCode = await publicClient.getCode({
        address: env.mmPositionManager as Address,
      });
      if (!mmpmCode || mmpmCode === "0x") {
        return;
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

      // Kernel callData is what the policy binds to.
      const kernelCallData = await account.encodeCalls([
        { to: env.mmPositionManager as Address, value: 0n, data: targetCallData },
      ]);

      const sender = (await account.getAddress()) as Address;
      const { factory, factoryData } = await account.getFactoryArgs();

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

      const envelopeFail = await buildSignedEnvelope({
        env,
        smartAccount: sender,
        checks: [
          {
            kind: Opcode.CheckSlot0TickBounds,
            poolId,
            min: -100,
            max: 100,
          },
        ],
        callBundleHash: keccak256(kernelCallData),
        nonce: 0n,
        deadline,
      });

      // Sign the UserOp with the PermissionValidator (sudo validator).
      // Then append policy-local signature slices:
      // - CallPolicy: no per-op signature, so empty bytes
      // - IntentPolicy: the signed envelope (must match the policy's parser exactly)
      //
      // Note: this packing assumes the PermissionValidator expects `bytes[] policySigs` after the validator signature.
      // If the upstream contract changes its signature layout, update this encoding accordingly.
      const baseUserOp = {
        sender,
        nonce: await account.getNonce(),
        callData: kernelCallData,
        callGasLimit: 2_500_000n,
        verificationGasLimit: 2_500_000n,
        preVerificationGas: 150_000n,
        maxFeePerGas: 1n,
        maxPriorityFeePerGas: 1n,
        factory: factory as Address,
        factoryData: factoryData as Hex,
        signature: "0x" as Hex,
      } as const;

      const baseSig = (await account.signUserOperation(baseUserOp as any)) as Hex;
      const policySigs = encodeAbiParameters(
        [{ name: "policySigs", type: "bytes[]" }],
        [["0x", envelopeFail]],
      ) as Hex;
      const userOpFail = {
        ...baseUserOp,
        signature: concatHex([baseSig, policySigs]),
      };

      const packedFail = toPackedUserOperation(userOpFail as any);

      await expect(
        walletClient.writeContract({
          address: entryPoint.address,
          abi: entryPoint07Abi,
          functionName: "handleOps",
          args: [[packedFail as any], env.owner.address],
        }),
      ).rejects.toBeTruthy();

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

      const envelopePass = await buildSignedEnvelope({
        env,
        smartAccount: sender,
        checks: [
          {
            kind: Opcode.CheckSlot0TickBounds,
            poolId,
            min: -100,
            max: 100,
          },
        ],
        callBundleHash: keccak256(kernelCallData),
        nonce: 0n,
        deadline,
      });

      const policySigsPass = encodeAbiParameters(
        [{ name: "policySigs", type: "bytes[]" }],
        [["0x", envelopePass]],
      ) as Hex;
      const userOpPass = {
        ...baseUserOp,
        signature: concatHex([baseSig, policySigsPass]),
      };
      const packedPass = toPackedUserOperation(userOpPass as any);

      await walletClient.writeContract({
        address: entryPoint.address,
        abi: entryPoint07Abi,
        functionName: "handleOps",
        args: [[packedPass as any], env.owner.address],
      });

      const afterPass = await publicClient.readContract({
        address: env.mmPositionManager as Address,
        abi: WritesABI,
        functionName: "writes",
      });
      expect(afterPass).toBe(before + 1n);

      // Explicitly assert the “caller identity” property: MMPositionManager observed the Kernel wallet
      // as its caller when the write happened.
      const lastSender = await publicClient.readContract({
        address: env.mmPositionManager as Address,
        abi: LastSenderABI,
        functionName: "lastSender",
      });
      expect(lastSender).toBe(sender);
    });
  },
);

