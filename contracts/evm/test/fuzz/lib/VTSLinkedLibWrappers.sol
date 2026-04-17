// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @title VTSLinkedLibWrappers
/// @notice Placeholder contracts for future Medusa harnesses that need deploy-time library instances without Foundry
///         `[profile.echidna].libraries` linking. Production VTS libraries use `delegatecall` and `VTSStorage`; real
///         wrappers will forward through harness-local storage or duplicated minimal surfaces — see `README.md`.
/// @dev Not used by `FuzzEntry` / `FuzzMMQ01` today (MMQ path uses `PositionManagerImplQueueCustodyHarness` + mocks).

contract VTSPositionLibStub {
    uint256 public constant STUB_ID = 1;
}

contract VTSPositionMMOpsLibStub {
    uint256 public constant STUB_ID = 2;
}

contract VTSLifecycleLinkedLibStub {
    uint256 public constant STUB_ID = 3;
}

contract VTSCommitLibStub {
    uint256 public constant STUB_ID = 4;
}
