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

const ALREADY_INITIALIZED_SELECTOR = "0x93360fbf";
const NOT_INITIALIZED_SELECTOR = "0xf91bd6f1";

function hexToU8Array(hex: Hex): number[] {
  // Stylus ABI represents `Vec<u8>` as `uint8[]`.
  return Array.from(toBytes(hex));
}

function hasRevertSelector(err: unknown, selector: string): boolean {
  const e = err as any;
  const sig: string | undefined =
    e?.signature ??
    e?.cause?.signature ??
    (typeof e?.data === "string" ? e.data.slice(0, 10) : undefined) ??
    (typeof e?.cause?.data === "string" ? e.cause.data.slice(0, 10) : undefined) ??
    (typeof e?.raw === "string" ? e.raw.slice(0, 10) : undefined) ??
    (typeof e?.cause?.raw === "string" ? e.cause.raw.slice(0, 10) : undefined);
  return typeof sig === "string" && sig.toLowerCase() === selector.toLowerCase();
}

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

export function makeBytes32Id(label: string): Hex {
  // Deterministic bytes32 for reproducible tests.
  return keccak256(toBytes(`fiet-e2e:${label}`));
}

export function makePermissionId(label: string): Hex {
  // Kernel v3.3 PermissionId is bytes4; we encode it as bytes32 (bytes4 left-aligned, rest zero).
  // This matches the expectation enforced by `loadEnv()` (and by on-chain policy logic).
  const full = makeBytes32Id(`permission:${label}`);
  const bytes4 = full.slice(0, 10); // "0x" + 8 hex chars
  return (`${bytes4}${"00".repeat(28)}`) as Hex;
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
  return {
    sender: params.sender,
    nonce: 0n,
    initCode: [] as const,
    callData: hexToU8Array(params.callData),
    accountGasLimits: ZERO_BYTES32,
    preVerificationGas: 0n,
    gasFees: ZERO_BYTES32,
    paymasterAndData: [] as const,
    signature: hexToU8Array(params.signature),
  } as const;
}

export async function makeClients(env: TestEnv) {
  const transport = http(env.rpcUrl);

  // Always resolve chain id from RPC to avoid stale/mismatched `.env` values.
  // (EIP-712 signatures must match `chainid()` on-chain.)
  const probeClient = createPublicClient({
    transport,
  });
  const chainId = await probeClient.getChainId();

  const chain = {
    id: Number(chainId),
    name: "fiet-e2e",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [env.rpcUrl] } },
  } as const;

  const publicClient = createPublicClient({
    chain,
    transport,
  });
  const walletClient = createWalletClient({
    account: env.owner,
    chain,
    transport,
  });
  return { publicClient, walletClient, chainId: BigInt(chainId) };
}

export async function installIntentPolicy(params: {
  env: TestEnv;
  permissionId: Hex;
}) {
  const { env, permissionId } = params;
  const { walletClient } = await makeClients(env);

  // Make installs idempotent across repeated local test runs on the same devnet.
  // If the `(wallet, permissionId)` instance already exists, remove it first.
  const uninstallData = buildIntentPolicyInstallData({
    permissionId,
    signer: env.owner.address,
    stateView: env.stateView,
    vtsOrchestrator: env.vtsOrchestrator,
    liquidityHub: env.liquidityHub,
  });
  try {
    await walletClient.writeContract({
      address: env.intentPolicy,
      abi: IntentPolicyABI,
      functionName: "onUninstall",
      args: [hexToU8Array(uninstallData)],
    });
  } catch (err) {
    if (!hasRevertSelector(err, NOT_INITIALIZED_SELECTOR)) throw err;
  }

  const data = buildIntentPolicyInstallData({
    permissionId,
    signer: env.owner.address,
    stateView: env.stateView,
    vtsOrchestrator: env.vtsOrchestrator,
    liquidityHub: env.liquidityHub,
  });

  try {
    return await walletClient.writeContract({
      address: env.intentPolicy,
      abi: IntentPolicyABI,
      functionName: "onInstall",
      args: [hexToU8Array(data)],
    });
  } catch (err) {
    if (hasRevertSelector(err, ALREADY_INITIALIZED_SELECTOR)) return "0x" as Hex;
    throw err;
  }
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
    args: [hexToU8Array(data)],
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

  const { publicClient, chainId } = await makeClients(env);

  const signingEnvBase =
    envelopeSignerPrivateKey != null
      ? { ...env, owner: privateKeyToAccount(envelopeSignerPrivateKey) }
      : env;
  const signingEnv = { ...signingEnvBase, chainId };

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
    account: wallet, // msg.sender should match the userOp sender in this simulation context
    address: env.intentPolicy,
    abi: IntentPolicyABI,
    functionName: "checkUserOpPolicy",
    args: [permissionId, userOp],
  });

  return sim.result;
}

