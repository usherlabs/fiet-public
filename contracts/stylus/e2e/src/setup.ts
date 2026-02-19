import "dotenv/config";
import {
  Address,
  Hex,
  PrivateKeyAccount,
  hexToBytes,
  isAddress,
  isHex,
  pad,
  toHex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { encodeEnvelope, encodeProgram, signEnvelope } from "./encoder.js";
import { Check, IntentEnvelope } from "./types.js";

export interface TestEnv {
  rpcUrl: string;
  chainId: bigint;
  owner: PrivateKeyAccount;
  intentPolicy: Hex;
  permissionId: Hex;
  stateView: Hex;
  vtsOrchestrator: Hex;
  liquidityHub: Hex;
  mmPositionManager: Hex;
  positionManager: Hex;
  entryPoint: Hex;
  kernelImplementation: Hex;
  multichainSigner: Hex;
  callPolicy: Hex;
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
    "ENTRYPOINT_ADDRESS",
    "KERNEL_IMPLEMENTATION_ADDRESS",
    "MULTICHAIN_SIGNER_ADDRESS",
    "CALL_POLICY_ADDRESS",
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
  const rpcUrl = process.env.RPC_URL!;

  const permissionId = process.env.PERMISSION_ID! as Hex;
  if (!isHex(permissionId, { strict: true }) || permissionId.length !== 66) {
    throw new Error("Invalid env PERMISSION_ID (expected 0x-prefixed 32-byte hex)");
  }
  // Kernel v3.3 PermissionId is bytes4; we encode it as bytes32 (bytes4 left-aligned, rest zero).
  const permissionTail = (`0x${permissionId.slice(10)}`) as Hex;
  if (permissionTail !== (`0x${"00".repeat(28)}` as Hex)) {
    throw new Error(
      "Invalid env PERMISSION_ID (expected bytes4 left-aligned and 28 bytes zero-padded, e.g. 0xdeadbeef0000..00)",
    );
  }

  const intentPolicy = process.env.INTENT_POLICY_ADDRESS! as Hex;
  const stateView = process.env.STATE_VIEW_ADDRESS! as Hex;
  const vtsOrchestrator = process.env.VTS_ORCHESTRATOR_ADDRESS! as Hex;
  const liquidityHub = process.env.LIQUIDITY_HUB_ADDRESS! as Hex;
  const mmPositionManager = process.env.MM_POSITION_MANAGER_ADDRESS! as Hex;
  const positionManager = process.env.POSITION_MANAGER_ADDRESS! as Hex;
  const entryPoint = process.env.ENTRYPOINT_ADDRESS! as Hex;
  const kernelImplementation = process.env.KERNEL_IMPLEMENTATION_ADDRESS! as Hex;
  const multichainSigner = process.env.MULTICHAIN_SIGNER_ADDRESS! as Hex;
  const callPolicy = process.env.CALL_POLICY_ADDRESS! as Hex;

  const addrVars: Array<[string, Hex]> = [
    ["INTENT_POLICY_ADDRESS", intentPolicy],
    ["STATE_VIEW_ADDRESS", stateView],
    ["VTS_ORCHESTRATOR_ADDRESS", vtsOrchestrator],
    ["LIQUIDITY_HUB_ADDRESS", liquidityHub],
    ["MM_POSITION_MANAGER_ADDRESS", mmPositionManager],
    ["POSITION_MANAGER_ADDRESS", positionManager],
    ["ENTRYPOINT_ADDRESS", entryPoint],
    ["KERNEL_IMPLEMENTATION_ADDRESS", kernelImplementation],
    ["MULTICHAIN_SIGNER_ADDRESS", multichainSigner],
    ["CALL_POLICY_ADDRESS", callPolicy],
  ];
  for (const [name, value] of addrVars) {
    if (!isAddress(value)) {
      throw new Error(`Invalid env ${name} (expected 0x-prefixed 20-byte address)`);
    }
  }

  return {
    rpcUrl,
    chainId,
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
    entryPoint,
    kernelImplementation,
    multichainSigner,
    callPolicy,
  };
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
  // Note: viem `pad(..., { size })` uses **bytes** (not hex chars).
  // Addresses are 20 bytes, so each field must be padded to size=20.
  data.set(hexToBytes(pad(params.signer, { size: 20 })), 1);
  data.set(hexToBytes(pad(params.stateView, { size: 20 })), 21);
  data.set(hexToBytes(pad(params.vtsOrchestrator, { size: 20 })), 41);
  data.set(hexToBytes(pad(params.liquidityHub, { size: 20 })), 61);
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

  // bytes32 permissionId prefix
  const permissionBytes = hexToBytes(pad(params.permissionId, { size: 32 }));
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
