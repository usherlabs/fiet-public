export const IntentPolicyABI = [
  {
    type: "function",
    name: "onInstall",
    stateMutability: "payable",
    inputs: [{ name: "data", type: "bytes" }],
    outputs: [],
  },
  {
    type: "function",
    name: "onUninstall",
    stateMutability: "payable",
    inputs: [{ name: "data", type: "bytes" }],
    outputs: [],
  },
  {
    type: "function",
    name: "isModuleType",
    stateMutability: "view",
    inputs: [{ name: "moduleTypeId", type: "uint256" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "isInitialized",
    stateMutability: "view",
    inputs: [{ name: "smartAccount", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "checkUserOpPolicy",
    stateMutability: "payable",
    inputs: [
      { name: "id", type: "bytes32" },
      {
        name: "userOp",
        type: "tuple",
        components: [
          { name: "sender", type: "address" },
          { name: "nonce", type: "uint256" },
          { name: "initCode", type: "bytes" },
          { name: "callData", type: "bytes" },
          { name: "accountGasLimits", type: "bytes32" },
          { name: "preVerificationGas", type: "uint256" },
          { name: "gasFees", type: "bytes32" },
          { name: "paymasterAndData", type: "bytes" },
          { name: "signature", type: "bytes" },
        ],
      },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "checkSignaturePolicy",
    stateMutability: "view",
    inputs: [
      { name: "id", type: "bytes32" },
      { name: "sender", type: "address" },
      { name: "hash", type: "bytes32" },
      { name: "sig", type: "bytes" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;


