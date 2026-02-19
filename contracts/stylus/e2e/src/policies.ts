import { Address, Hex, encodeAbiParameters, getAbiItem, getFunctionSelector } from "viem";
import { MMPositionManagerABI } from "./abi/mmpm.js";
import { PositionManagerABI } from "./abi/position-manager.js";

/**
 * Build init data for Kernel's audited `CallPolicy.onInstall`.
 *
 * `CallPolicy` expects `_data = abi.encode(Permission[])` where:
 * `Permission = (bytes1 callType, address target, bytes4 selector, uint256 valueLimit, ParamRule[] rules)`.
 */
export function buildCallPolicyInitData(params: {
  mmPositionManager: Address;
  positionManager: Address;
}): Hex {
  const { mmPositionManager, positionManager } = params;

  const CALLTYPE_SINGLE = "0x00" as Hex; // bytes1
  const valueLimit = 0n;
  const rules: any[] = [];

  const permissions: Array<{
    callType: Hex;
    target: Address;
    selector: Hex;
    valueLimit: bigint;
    rules: any[];
  }> = [];

  // MMPositionManager
  permissions.push({
    callType: CALLTYPE_SINGLE,
    target: mmPositionManager,
    selector: getFunctionSelector(
      getAbiItem({ abi: MMPositionManagerABI, name: "modifyLiquidities" }) as any,
    ) as Hex,
    valueLimit,
    rules,
  });
  permissions.push({
    callType: CALLTYPE_SINGLE,
    target: mmPositionManager,
    selector: getFunctionSelector(
      getAbiItem({
        abi: MMPositionManagerABI,
        name: "modifyLiquiditiesWithoutUnlock",
      }) as any,
    ) as Hex,
    valueLimit,
    rules,
  });

  // PositionManager
  permissions.push({
    callType: CALLTYPE_SINGLE,
    target: positionManager,
    selector: getFunctionSelector(
      getAbiItem({ abi: PositionManagerABI, name: "modifyLiquidities" }) as any,
    ) as Hex,
    valueLimit,
    rules,
  });
  permissions.push({
    callType: CALLTYPE_SINGLE,
    target: positionManager,
    selector: getFunctionSelector(
      getAbiItem({
        abi: PositionManagerABI,
        name: "modifyLiquiditiesWithoutUnlock",
      }) as any,
    ) as Hex,
    valueLimit,
    rules,
  });

  return encodeAbiParameters(
    [
      {
        type: "tuple[]",
        components: [
          { name: "callType", type: "bytes1" },
          { name: "target", type: "address" },
          { name: "selector", type: "bytes4" },
          { name: "valueLimit", type: "uint256" },
          {
            name: "rules",
            type: "tuple[]",
            components: [
              { name: "condition", type: "uint8" },
              { name: "offset", type: "uint64" },
              { name: "params", type: "bytes32[]" },
            ],
          },
        ],
      },
    ],
    [permissions as any],
  ) as Hex;
}

