// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title IMMQueueCustodian
/// @notice MM queue custodian: one immutable beneficiary; Hub queue ownership for `MMPositionManager`.
/// @dev Hub queue ownership for MM synthetic principal is keyed to this custodian (`settleQueue(lcc, address(custodian))`).
///      Receivable state is **on-chain balances** on this contract (LCC + underlying) plus `LiquidityHub.settleQueue`;
///      there is no separate entitlement ledger. Underlying is released to `MMPositionManager` for pull withdrawal via
///      locker `TAKE`, not pushed to EOAs from this contract.
interface IMMQueueCustodian {
    /// @notice Returns the MMPositionManager bound to this custodian
    function positionManager() external view returns (address);

    /// @notice Immutable beneficiary whose custodian this is (same key as `custodianFor[beneficiary]` on the manager).
    function beneficiary() external view returns (address);

    /// @notice Current **ERC20 LCC** balance held by this custodian for `lcc` (same as `IERC20(lcc).balanceOf(address(this))`).
    /// @dev This is the on-chain custody balance, not a shadow queue book. Used with Hub queue and reserves for collect caps.
    function totalQueuedLcc(address lcc) external view returns (uint256);

    /// @notice Hub `unwrap` as this contract: shortfall queues to this custodian; immediate underlying is forwarded.
    /// @dev Uses canonical Hub from `ILCC(lcc).hub()`. `MMPM` must transfer `amount` LCC to this contract before calling.
    function unwrapLcc(address lcc, address forwardUnderlyingTo, uint256 amount) external;

    /// @notice After Hub settlement, moves underlying from this custodian to the position manager (pull collect path).
    /// @dev Transfers up to `min(amount, actual underlying balance)`; caller must be the bound position manager.
    function release(address lcc, uint256 amount) external;
}
