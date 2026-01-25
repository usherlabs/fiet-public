import { describe } from "vitest";
import {
  Address,
  Hex,
  createPublicClient,
  createWalletClient,
  http,
  keccak256,
  toBytes,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { IntentPolicyABI } from "../abi/intent-policy.js";
import {
  TestEnv,
  buildIntentPolicyInstallData,
  buildSignedEnvelope,
  loadEnv,
} from "../setup.js";
import { Check } from "../types.js";

export const POLICY_SUCCESS = 0n;
export const POLICY_FAILED = 1n;

const ZERO_BYTES32 = (`0x${"00".repeat(32)}`) as Hex;

/**
 * Run an E2E suite only when the `.env` required by `loadEnv()` is present.
 *
 * Why:
 * - Locally, developers may run `bun test` before `just bootstrap` has written `e2e/.env`.
 * - In CI, we want a crisp "skipped because missing env X" reason rather than a confusing crash.
 */
export function describeE2E(name: string, fn: () => void) {
  try {
    loadEnv();
    return describe(name, fn);
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    return describe.skip(`${name} (skipped: ${reason})`, fn);
  }
}

export function makePermissionId(label: string): Hex {
  // Deterministic bytes32 for reproducible tests.
  return keccak256(toBytes(`fiet-e2e:${label}`));
}

export function makeCallData(label: string): Hex {
  // Any bytes are fine; the policy binds to keccak256(callData).
  return keccak256(toBytes(`fiet-e2e:callData:${label}`));
}

export function makePackedUserOp(params: {
  sender: Address;
  callData: Hex;
  signature: Hex;
}) {
  // Only `callData` and `signature` are read by the policy; everything else is ignored.
  // Keep the rest well-formed so the ABI encoding matches Kernel's PackedUserOperation tuple.
  return [
    params.sender, // sender
    0n, // nonce
    "0x", // initCode
    params.callData, // callData
    ZERO_BYTES32, // accountGasLimits
    0n, // preVerificationGas
    ZERO_BYTES32, // gasFees
    "0x", // paymasterAndData
    params.signature, // signature (policy-local envelope slice)
  ] as const;
}

export async function makeClients(env: TestEnv) {
  const publicClient = createPublicClient({
    transport: http(env.rpcUrl),
  });
  const walletClient = createWalletClient({
    account: env.owner,
    transport: http(env.rpcUrl),
  });
  return { publicClient, walletClient };
}

export async function installIntentPolicy(params: {
  env: TestEnv;
  permissionId: Hex;
}) {
  const { env, permissionId } = params;
  const { walletClient } = await makeClients(env);

  const data = buildIntentPolicyInstallData({
    permissionId,
    signer: env.owner.address,
    stateView: env.stateView,
    vtsOrchestrator: env.vtsOrchestrator,
    liquidityHub: env.liquidityHub,
  });

  return walletClient.writeContract({
    address: env.intentPolicy,
    abi: IntentPolicyABI,
    functionName: "onInstall",
    args: [data],
  });
}

export async function uninstallIntentPolicy(params: {
  env: TestEnv;
  permissionId: Hex;
}) {
  const { env, permissionId } = params;
  const { walletClient } = await makeClients(env);

  // The policy only requires the leading bytes32 permissionId for uninstall.
  // Passing the full install payload keeps the layout consistent and debuggable.
  const data = buildIntentPolicyInstallData({
    permissionId,
    signer: env.owner.address,
    stateView: env.stateView,
    vtsOrchestrator: env.vtsOrchestrator,
    liquidityHub: env.liquidityHub,
  });

  return walletClient.writeContract({
    address: env.intentPolicy,
    abi: IntentPolicyABI,
    functionName: "onUninstall",
    args: [data],
  });
}

export async function simulateCheckUserOpPolicy(params: {
  env: TestEnv;
  permissionId: Hex;
  wallet: Address;
  callData: Hex;
  checks: Check[];
  nonce: bigint;
  deadline: bigint;
  // Override to intentionally test tampering / wrong signing keys.
  envelopeSignerPrivateKey?: Hex;
  // Override to intentionally test bundle mismatches.
  callBundleHashOverride?: Hex;
}) {
  const {
    env,
    permissionId,
    wallet,
    callData,
    checks,
    nonce,
    deadline,
    envelopeSignerPrivateKey,
    callBundleHashOverride,
  } = params;

  const { publicClient } = await makeClients(env);

  const signingEnv =
    envelopeSignerPrivateKey != null
      ? { ...env, owner: privateKeyToAccount(envelopeSignerPrivateKey) }
      : env;

  const callBundleHash = (callBundleHashOverride ?? keccak256(callData)) as Hex;

  const envelope = await buildSignedEnvelope({
    env: signingEnv,
    smartAccount: wallet,
    permissionId,
    checks,
    callBundleHash,
    nonce,
    deadline,
  });

  const userOp = makePackedUserOp({
    sender: wallet,
    callData,
    signature: envelope,
  });

  const sim = await publicClient.simulateContract({
    account: env.owner, // msg.sender (the "wallet" in policy storage) for this eth_call context
    address: env.intentPolicy,
    abi: IntentPolicyABI,
    functionName: "checkUserOpPolicy",
    args: [permissionId, userOp],
  });

  return sim.result;
}

