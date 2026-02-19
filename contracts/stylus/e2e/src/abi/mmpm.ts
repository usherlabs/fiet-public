export const MMPositionManagerABI = [
  {
    type: "function",
    name: "modifyLiquidities",
    stateMutability: "payable",
    inputs: [
      { name: "unlockData", type: "bytes" },
      { name: "deadline", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "modifyLiquiditiesWithoutUnlock",
    stateMutability: "payable",
    inputs: [
      { name: "actions", type: "bytes" },
      { name: "params", type: "bytes[]" },
    ],
    outputs: [],
  },
] as const;

