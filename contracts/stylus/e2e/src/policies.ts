import { Address, Hex, encodeAbiParameters, getAbiItem, getFunctionSelector } from "viem";
import { MMPositionManagerABI } from "./abi/mmpm.js";
import { PositionManagerABI } from "./abi/position-manager.js";

/**
 * Build init data for `FietCallPolicy.onInstall`.
 *
 * Kernel will call: `policy.onInstall(bytes32(permissionId) || initData)`.
 *
 * Our `FietCallPolicy` expects `initData = abi.encode(address[] targets, bytes4[] selectors)`.
 */
export function buildFietCallPolicyInitData(params: {
  mmPositionManager: Address;
  positionManager: Address;
}): Hex {
  const { mmPositionManager, positionManager } = params;

  const targets: Address[] = [];
  const selectors: Hex[] = [];

  // MMPositionManager
  targets.push(mmPositionManager);
  selectors.push(
    getFunctionSelector(
      getAbiItem({ abi: MMPositionManagerABI, name: "modifyLiquidities" }) as any,
    ) as Hex,
  );
  targets.push(mmPositionManager);
  selectors.push(
    getFunctionSelector(
      getAbiItem({
        abi: MMPositionManagerABI,
        name: "modifyLiquiditiesWithoutUnlock",
      }) as any,
    ) as Hex,
  );

  // PositionManager
  targets.push(positionManager);
  selectors.push(
    getFunctionSelector(
      getAbiItem({ abi: PositionManagerABI, name: "modifyLiquidities" }) as any,
    ) as Hex,
  );
  targets.push(positionManager);
  selectors.push(
    getFunctionSelector(
      getAbiItem({
        abi: PositionManagerABI,
        name: "modifyLiquiditiesWithoutUnlock",
      }) as any,
    ) as Hex,
  );

  // Encode as (address[], bytes4[]) — bytes4 are encoded as bytes4, but viem models selectors as Hex.
  return encodeAbiParameters(
    [{ type: "address[]" }, { type: "bytes4[]" }],
    [targets, selectors as any],
  ) as Hex;
}

