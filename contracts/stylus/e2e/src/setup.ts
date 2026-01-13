import "dotenv/config";
import {
  createKernelAccount,
  createKernelAccountClient,
  createZeroDevPaymasterClient,
  getEntryPoint,
} from "@zerodev/sdk";
import { toPermissionValidator } from "@zerodev/permissions";
import { createPublicClient, createWalletClient, http, Hex, PrivateKeyAccount, pad, hexToBytes, toHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrumSepolia } from "viem/chains";
import { buildCallPolicy } from "./policies.js";
import { encodeEnvelope, encodeProgram } from "./encoder.js";
import { Check, IntentEnvelope } from "./types.js";

export interface TestEnv {
  rpcUrl: string;
  bundlerUrl: string;
  chainId: bigint;
  entryPointVersion: "0.7" | "0.6";
  kernelVersion: string;
  owner: PrivateKeyAccount;
  intentPolicy: Hex;
  stateView: Hex;
  vtsOrchestrator: Hex;
  liquidityHub: Hex;
  mmPositionManager: Hex;
  positionManager: Hex;
}

export function loadEnv(): TestEnv {
  const required = [
    "ZERODEV_RPC",
    "OWNER_PRIVATE_KEY",
    "INTENT_POLICY_ADDRESS",
    "STATE_VIEW_ADDRESS",
    "VTS_ORCHESTRATOR_ADDRESS",
    "LIQUIDITY_HUB_ADDRESS",
    "MM_POSITION_MANAGER_ADDRESS",
    "POSITION_MANAGER_ADDRESS",
  ] as const;
  for (const key of required) {
    if (!process.env[key]) {
      throw new Error(`Missing env ${key}`);
    }
  }

  const chainId = BigInt(process.env.CHAIN_ID ?? "421614"); // default Arbitrum Sepolia
  const entryPointVersion = (process.env.ENTRYPOINT_VERSION ?? "0.7") as "0.7" | "0.6";

  return {
    rpcUrl: process.env.ZERODEV_RPC!,
    bundlerUrl: process.env.ZERODEV_RPC!,
    chainId,
    entryPointVersion,
    kernelVersion: process.env.KERNEL_VERSION ?? "3.3",
    owner: privateKeyToAccount(process.env.OWNER_PRIVATE_KEY! as Hex),
    intentPolicy: process.env.INTENT_POLICY_ADDRESS! as Hex,
    stateView: process.env.STATE_VIEW_ADDRESS! as Hex,
    vtsOrchestrator: process.env.VTS_ORCHESTRATOR_ADDRESS! as Hex,
    liquidityHub: process.env.LIQUIDITY_HUB_ADDRESS! as Hex,
    mmPositionManager: process.env.MM_POSITION_MANAGER_ADDRESS! as Hex,
    positionManager: process.env.POSITION_MANAGER_ADDRESS! as Hex,
  };
}

export async function buildKernelClient(env: TestEnv) {
  const chain = arbitrumSepolia; // override id matches env.chainId
  const entryPoint = getEntryPoint(env.entryPointVersion);

  const publicClient = createPublicClient({
    chain,
    transport: http(env.rpcUrl),
  });

  const walletClient = createWalletClient({
    account: env.owner,
    chain,
    transport: http(env.rpcUrl),
  });

  // Build CallPolicy restricting targets
  const callPolicy = buildCallPolicy({
    mmPositionManager: env.mmPositionManager as Hex,
    positionManager: env.positionManager as Hex,
  });

  // Build IntentPolicy init data (version + fact sources).
  // NOTE: installing this policy requires configuring it inside the PermissionValidator
  // permission config; this harness scaffolds the init bytes, but the exact SDK wiring
  // for custom policies depends on your ZeroDev SDK version.
  const intentPolicyInitData = buildIntentPolicyInitData({
    stateView: env.stateView,
    vtsOrchestrator: env.vtsOrchestrator,
    liquidityHub: env.liquidityHub,
  });

  // Permission validator combining signer + policies
  const permissionValidator = await toPermissionValidator(publicClient, {
    entryPoint,
    signer: env.owner,
    kernelVersion: env.kernelVersion,
    // Include CallPolicy plus our custom IntentPolicy.
    //
    // If your SDK supports custom policies directly, replace this `as any` shape with
    // the proper helper for your version (e.g. `toCustomPolicy(...)`).
    policies: [
      callPolicy,
      {
        address: env.intentPolicy,
        data: intentPolicyInitData,
      } as any,
    ],
  });

  const account = await createKernelAccount(publicClient, {
    entryPoint,
    kernelVersion: env.kernelVersion,
    plugins: {
      sudo: permissionValidator, // Kernel expects sudo validator; our intent validator is at execution path
    },
    address: undefined, // allow computed
  });

  const paymaster = createZeroDevPaymasterClient({
    chain,
    transport: http(env.bundlerUrl),
  });

  const kernelClient = createKernelAccountClient({
    account,
    chain,
    bundlerTransport: http(env.bundlerUrl),
    client: publicClient,
    paymaster,
  });

  return { publicClient, walletClient, kernelClient, account, entryPoint };
}

function buildIntentPolicyInitData(params: {
  stateView: Hex;
  vtsOrchestrator: Hex;
  liquidityHub: Hex;
}): Hex {
  const data = new Uint8Array(1 + 20 + 20 + 20);
  data[0] = 1; // version
  data.set(hexToBytes(pad(params.stateView, { size: 40 })), 1);
  data.set(hexToBytes(pad(params.vtsOrchestrator, { size: 40 })), 21);
  data.set(hexToBytes(pad(params.liquidityHub, { size: 40 })), 41);
  return toHex(data);
}

// Utility to build and sign an intent envelope for tests
export async function buildSignedEnvelope(opts: {
  env: TestEnv;
  smartAccount: Address;
  checks: Check[];
  callBundleHash: Hex;
  nonce: bigint;
  deadline: bigint;
}) {
  const programBytes = encodeProgram(opts.checks);
  const envelope: IntentEnvelope = {
    version: 1,
    nonce: opts.nonce,
    deadline: opts.deadline,
    callBundleHash: opts.callBundleHash,
    programBytes,
  };

  return encodeEnvelope(envelope);
}

