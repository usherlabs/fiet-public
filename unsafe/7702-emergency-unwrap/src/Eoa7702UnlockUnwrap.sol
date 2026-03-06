// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

interface IPoolManagerLike {
    function unlock(bytes calldata data) external returns (bytes memory);
}

interface ILiquidityHubLike {
    function unwrap(address lcc, uint256 amount) external;
}

/// @notice Emergency EIP-7702 delegated implementation to perform
///         PoolManager.unlock -> unlockCallback -> LiquidityHub.unwrap atomically.
/// @dev This contract is meant to be delegated to an EOA for a single operation.
contract Eoa7702UnlockUnwrap is IUnlockCallback {
    struct UnwrapParams {
        address poolManager;
        address liquidityHub;
        address lcc;
        uint256 amount;
        uint256 expectedChainId;
    }

    error SelfCallOnly();
    error InvalidAddress();
    error WrongChain(uint256 expected, uint256 actual);
    error InvalidCallbackSender(address sender, address expected);
    error EtherNotAccepted();

    function unlockAndUnwrap(
        address poolManager,
        address liquidityHub,
        address lcc,
        uint256 amount,
        uint256 expectedChainId
    ) external returns (bytes memory ret) {
        if (msg.sender != address(this)) revert SelfCallOnly();
        if (poolManager == address(0) || liquidityHub == address(0) || lcc == address(0)) revert InvalidAddress();
        if (expectedChainId != block.chainid) revert WrongChain(expectedChainId, block.chainid);

        bytes memory data = abi.encode(UnwrapParams(poolManager, liquidityHub, lcc, amount, expectedChainId));
        ret = IPoolManagerLike(poolManager).unlock(data);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        UnwrapParams memory p = abi.decode(data, (UnwrapParams));
        if (msg.sender != p.poolManager) revert InvalidCallbackSender(msg.sender, p.poolManager);
        if (p.expectedChainId != block.chainid) revert WrongChain(p.expectedChainId, block.chainid);

        ILiquidityHubLike(p.liquidityHub).unwrap(p.lcc, p.amount);
        return bytes("");
    }

    receive() external payable {
        revert EtherNotAccepted();
    }
}
