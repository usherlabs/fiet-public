export const IntentPolicyABI = [
  {
    type: "function",
    name: "onInstall",
    stateMutability: "payable",
    // Stylus ABI maps `Vec<u8>` to `uint8[]` (not Solidity `bytes`).
    inputs: [{ name: "data", type: "uint8[]" }],
    outputs: [],
  },
  {
    type: "function",
    name: "onUninstall",
    stateMutability: "payable",
    // Stylus ABI maps `Vec<u8>` to `uint8[]` (not Solidity `bytes`).
    inputs: [{ name: "data", type: "uint8[]" }],
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
          // Stylus ABI maps `Vec<u8>` to `uint8[]` (not Solidity `bytes`).
          { name: "initCode", type: "uint8[]" },
          { name: "callData", type: "uint8[]" },
          { name: "accountGasLimits", type: "bytes32" },
          { name: "preVerificationGas", type: "uint256" },
          { name: "gasFees", type: "bytes32" },
          // Stylus ABI maps `Vec<u8>` to `uint8[]` (not Solidity `bytes`).
          { name: "paymasterAndData", type: "uint8[]" },
          { name: "signature", type: "uint8[]" },
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
      // Stylus ABI maps `Vec<u8>` to `uint8[]` (not Solidity `bytes`).
      { name: "sig", type: "uint8[]" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;


