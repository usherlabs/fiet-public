import { CallPolicyVersion, toCallPolicy } from "@zerodev/permissions/policies";
import { Address } from "viem";
import { MMPositionManagerABI } from "./abi/mmpm.js";
import { PositionManagerABI } from "./abi/position-manager.js";

export function buildCallPolicy(params: {
  mmPositionManager: Address;
  positionManager: Address;
}): ReturnType<typeof toCallPolicy> {
  const { mmPositionManager, positionManager } = params;

  return toCallPolicy({
    policyVersion: CallPolicyVersion.V0_0_4,
    permissions: [
      {
        target: mmPositionManager,
        valueLimit: BigInt(0),
        abi: MMPositionManagerABI,
        functionName: "modifyLiquidities",
      },
      {
        target: mmPositionManager,
        valueLimit: BigInt(0),
        abi: MMPositionManagerABI,
        functionName: "modifyLiquiditiesWithoutUnlock",
      },
      {
        target: positionManager,
        valueLimit: BigInt(0),
        abi: PositionManagerABI,
        functionName: "modifyLiquidities",
      },
      {
        target: positionManager,
        valueLimit: BigInt(0),
        abi: PositionManagerABI,
        functionName: "modifyLiquiditiesWithoutUnlock",
      },
    ],
  });
}

