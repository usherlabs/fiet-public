import { toPermissionValidator } from "@zerodev/permissions";
import { createKernelAccount } from "@zerodev/sdk";
import "dotenv/config";
import {
  Address,
  Hex,
  PrivateKeyAccount,
  createPublicClient,
  createWalletClient,
  hexToBytes,
  http,
  isAddress,
  isHex,
  pad,
  toHex,
} from "viem";
import {
  entryPoint06Address,
  entryPoint07Address,
} from "viem/account-abstraction";
import { privateKeyToAccount } from "viem/accounts";
import { encodeEnvelope, encodeProgram, signEnvelope } from "./encoder.js";
import { buildCallPolicy } from "./policies.js";
import { Check, IntentEnvelope } from "./types.js";

export interface TestEnv {
  rpcUrl: string;
  chainId: bigint;
  entryPointVersion: "0.7" | "0.6";
  kernelVersion: string;
  owner: PrivateKeyAccount;
  intentPolicy: Hex;
  permissionId: Hex;
  stateView: Hex;
  vtsOrchestrator: Hex;
  liquidityHub: Hex;
  mmPositionManager: Hex;
  positionManager: Hex;
}

export function loadEnv(): TestEnv {
  const required = [
    "RPC_URL",
    "OWNER_PRIVATE_KEY",
    "INTENT_POLICY_ADDRESS",
    "PERMISSION_ID",
    "STATE_VIEW_ADDRESS",
    "VTS_ORCHESTRATOR_ADDRESS",
    "LIQUIDITY_HUB_ADDRESS",
    "MM_POSITION_MANAGER_ADDRESS",
    "POSITION_MANAGER_ADDRESS",
  ] as const;
  for (const key of required) {
    const v = process.env[key];
    // `just e2e_write_env` writes literal `null` when infra hasn't been deployed yet.
    // Treat that the same as "missing" so we fail fast with a crisp error.
    if (!v || v === "null" || v === "undefined") {
      throw new Error(`Missing env ${key}`);
    }
  }

  const chainId = BigInt(process.env.CHAIN_ID ?? "421614"); // default Arbitrum Sepolia
  const entryPointVersion = (process.env.ENTRYPOINT_VERSION ?? "0.7") as
    | "0.7"
    | "0.6";
  const rpcUrl = process.env.RPC_URL ?? process.env.ZERODEV_RPC;
  if (!rpcUrl) {
    throw new Error("Missing env RPC_URL (or legacy ZERODEV_RPC)");
  }

  const permissionId = process.env.PERMISSION_ID! as Hex;
  if (!isHex(permissionId, { strict: true }) || permissionId.length !== 66) {
    throw new Error("Invalid env PERMISSION_ID (expected 0x-prefixed 32-byte hex)");
  }

  const intentPolicy = process.env.INTENT_POLICY_ADDRESS! as Hex;
  const stateView = process.env.STATE_VIEW_ADDRESS! as Hex;
  const vtsOrchestrator = process.env.VTS_ORCHESTRATOR_ADDRESS! as Hex;
  const liquidityHub = process.env.LIQUIDITY_HUB_ADDRESS! as Hex;
  const mmPositionManager = process.env.MM_POSITION_MANAGER_ADDRESS! as Hex;
  const positionManager = process.env.POSITION_MANAGER_ADDRESS! as Hex;

  const addrVars: Array<[string, Hex]> = [
    ["INTENT_POLICY_ADDRESS", intentPolicy],
    ["STATE_VIEW_ADDRESS", stateView],
    ["VTS_ORCHESTRATOR_ADDRESS", vtsOrchestrator],
    ["LIQUIDITY_HUB_ADDRESS", liquidityHub],
    ["MM_POSITION_MANAGER_ADDRESS", mmPositionManager],
    ["POSITION_MANAGER_ADDRESS", positionManager],
  ];
  for (const [name, value] of addrVars) {
    if (!isAddress(value)) {
      throw new Error(`Invalid env ${name} (expected 0x-prefixed 20-byte address)`);
    }
  }

  return {
    rpcUrl,
    chainId,
    entryPointVersion,
    kernelVersion: process.env.KERNEL_VERSION ?? "3.3",
    owner: privateKeyToAccount(
      (process.env.OWNER_PRIVATE_KEY as Hex) ||
        (process.env.PRIVATE_KEY! as Hex),
    ),
    intentPolicy,
    permissionId,
    stateView,
    vtsOrchestrator,
    liquidityHub,
    mmPositionManager,
    positionManager,
  };
}

export async function buildKernelClient(env: TestEnv) {
  const entryPoint =
    env.entryPointVersion === "0.6"
      ? { address: entryPoint06Address, version: "0.6" as const }
      : { address: entryPoint07Address, version: "0.7" as const };

  const publicClient = createPublicClient({
    transport: http(env.rpcUrl),
  });

  const walletClient = createWalletClient({
    account: env.owner,
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
    signer: env.owner.address,
    stateView: env.stateView,
    vtsOrchestrator: env.vtsOrchestrator,
    liquidityHub: env.liquidityHub,
  });

  // Permission validator combining signer + policies
  const permissionValidator = await toPermissionValidator(publicClient, {
    entryPoint,
    signer: env.owner as any,
    kernelVersion: env.kernelVersion as any,
    // CRITICAL: must match the permission id used by envelope signing and policy storage scoping.
    permissionId: env.permissionId as any,
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
    kernelVersion: env.kernelVersion as any,
    plugins: {
      sudo: permissionValidator, // Kernel expects sudo validator; our intent validator is at execution path
    },
    address: undefined, // allow computed
  });

  // NOTE: For a pure 7702/no-bundler flow, we deliberately do not construct a bundler/paymaster client.
  // Use `publicClient` + `walletClient` directly for transactions/calls, and use `account` for Kernel
  // address derivation and plugin configuration.
  return { publicClient, walletClient, account, entryPoint };
}

export function buildIntentPolicyInitData(params: {
  signer: Address;
  stateView: Hex;
  vtsOrchestrator: Hex;
  liquidityHub: Hex;
}): Hex {
  // Layout matches the on-chain policy:
  // - uint8 version
  // - bytes20 signer (authorised envelope signer)
  // - bytes20 stateView
  // - bytes20 vtsOrchestrator
  // - bytes20 liquidityHub
  const data = new Uint8Array(1 + 20 + 20 + 20 + 20);
  data[0] = 1; // version
  data.set(hexToBytes(pad(params.signer, { size: 40 })), 1);
  data.set(hexToBytes(pad(params.stateView, { size: 40 })), 21);
  data.set(hexToBytes(pad(params.vtsOrchestrator, { size: 40 })), 41);
  data.set(hexToBytes(pad(params.liquidityHub, { size: 40 })), 61);
  return toHex(data);
}

/**
 * Build the exact `bytes` payload expected by `IntentPolicy.onInstall`.
 *
 * The Stylus policy mirrors the Kernel packing:
 * `bytes data = bytes32 permissionId || initData`.
 *
 * We keep this helper in TS so E2E tests can deterministically install/uninstall
 * policy instances without duplicating byte-layout logic in multiple files.
 */
export function buildIntentPolicyInstallData(params: {
  permissionId: Hex; // bytes32
  signer: Address;
  stateView: Hex;
  vtsOrchestrator: Hex;
  liquidityHub: Hex;
}): Hex {
  const initData = buildIntentPolicyInitData({
    signer: params.signer,
    stateView: params.stateView,
    vtsOrchestrator: params.vtsOrchestrator,
    liquidityHub: params.liquidityHub,
  });

  const permissionBytes = hexToBytes(pad(params.permissionId, { size: 64 }));
  const initBytes = hexToBytes(initData);

  const out = new Uint8Array(permissionBytes.length + initBytes.length);
  out.set(permissionBytes, 0);
  out.set(initBytes, permissionBytes.length);
  return toHex(out);
}

// Utility to build and sign an intent envelope for tests
export async function buildSignedEnvelope(opts: {
  env: TestEnv;
  smartAccount: Address;
  checks: Check[];
  callBundleHash: Hex;
  nonce: bigint;
  deadline: bigint;
  permissionId?: Hex;
}) {
  const programBytes = encodeProgram(opts.checks);
  const envelope: IntentEnvelope = {
    version: 1,
    nonce: opts.nonce,
    deadline: opts.deadline,
    callBundleHash: opts.callBundleHash,
    programBytes,
  };

  const signature = await signEnvelope({
    chainId: opts.env.chainId,
    verifyingContract: opts.env.intentPolicy as Address,
    wallet: opts.smartAccount,
    permissionId: (opts.permissionId ?? opts.env.permissionId) as Hex,
    envelope,
    signTypedData: (args) => opts.env.owner.signTypedData(args),
  });

  return encodeEnvelope(envelope, signature);
}
