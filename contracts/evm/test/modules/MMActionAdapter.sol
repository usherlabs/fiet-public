// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MMPositionManager} from "../../src/MMPositionManager.sol";
import {MMActions} from "../../src/libraries/MMActions.sol";
import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";

library MMActionAdapter {
    struct PreparedAction {
        bytes1 action;
        bytes params;
    }

    /**
     * @notice Concatenates action bytes into a single bytes array
     */
    function _concat(bytes1[] memory actions) internal pure returns (bytes memory out) {
        for (uint256 i = 0; i < actions.length; i++) {
            out = bytes.concat(out, actions[i]);
        }
    }

    /**
     * @notice Concatenates prepared actions into arrays for execution
     */
    function _concatPrepared(PreparedAction[] memory prepared)
        internal
        pure
        returns (bytes memory actions, bytes[] memory params)
    {
        params = new bytes[](prepared.length);

        for (uint256 i = 0; i < prepared.length; i++) {
            actions = bytes.concat(actions, prepared[i].action);
            params[i] = prepared[i].params;
        }
    }

    /**
     * @notice Public wrapper for _concatPrepared to use with modifyLiquidities
     */
    function concatPrepared(PreparedAction[] memory prepared)
        public
        pure
        returns (bytes memory actions, bytes[] memory params)
    {
        return _concatPrepared(prepared);
    }

    /**
     * @notice Executes prepared actions in a single modifyLiquiditiesWithoutUnlock call
     */
    function execute(MMPositionManager mmpm, PreparedAction[] memory prepared) internal {
        // Use modifyLiquidities which handles unlocking automatically
        (bytes memory actionsBytes, bytes[] memory params) = _concatPrepared(prepared);
        // bytes memory unlockData = abi.encode(actionsBytes, params);
        mmpm.modifyLiquiditiesWithoutUnlock(actionsBytes, params);
    }

    /**
     * @notice Executes prepared actions in a single modifyLiquidities call
     */
    function executeWithUnlock(MMPositionManager mmpm, PreparedAction[] memory prepared, uint256 deadline) internal {
        (bytes memory actionsBytes, bytes[] memory params) = _concatPrepared(prepared);
        bytes memory unlockData = abi.encode(actionsBytes, params);
        mmpm.modifyLiquidities(unlockData, deadline);
    }

    /**
     * @notice Executes prepared actions with ETH value in a single modifyLiquiditiesWithoutUnlock call
     */
    function execute(MMPositionManager mmpm, PreparedAction[] memory prepared, uint256 value) internal {
        (bytes memory actions, bytes[] memory params) = _concatPrepared(prepared);
        mmpm.modifyLiquiditiesWithoutUnlock{value: value}(actions, params);
    }

    // ============ PREPARE METHODS ============

    /**
     * @notice Prepares a COMMIT_SIGNAL action
     */
    function prepareCommit(PoolKey memory poolKey, bytes memory liquiditySignal)
        internal
        pure
        returns (PreparedAction memory)
    {
        return PreparedAction({
            action: bytes1(uint8(MMActions.COMMIT_SIGNAL)),
            params: abi.encode(poolKey, liquiditySignal, ActionConstants.MSG_SENDER)
        });
    }

    /**
     * @notice Prepares a COMMIT_SIGNAL action with a specific owner
     */
    function prepareCommitWithOwner(PoolKey memory poolKey, bytes memory liquiditySignal, address owner)
        internal
        pure
        returns (PreparedAction memory)
    {
        return PreparedAction({
            action: bytes1(uint8(MMActions.COMMIT_SIGNAL)), params: abi.encode(poolKey, liquiditySignal, owner)
        });
    }

    /**
     * @notice Prepares a MINT_POSITION action
     */
    function prepareMint(PoolKey memory poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper, uint256 liquidity)
        internal
        pure
        returns (PreparedAction memory)
    {
        return PreparedAction({
            action: bytes1(uint8(MMActions.MINT_POSITION)),
            params: abi.encode(poolKey, tokenId, tickLower, tickUpper, liquidity)
        });
    }

    function prepareMintFromDeltas(PoolKey memory poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper)
        internal
        pure
        returns (PreparedAction memory)
    {
        return PreparedAction({
            action: bytes1(uint8(MMActions.MINT_POSITION_FROM_DELTAS)),
            params: abi.encode(poolKey, tokenId, tickLower, tickUpper)
        });
    }

    /**
     * @notice Prepares a SETTLE_POSITION action
     */
    function prepareSettle(
        PoolKey memory poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        int128 amount0,
        int128 amount1
    ) internal pure returns (PreparedAction memory) {
        return PreparedAction({
            action: bytes1(uint8(MMActions.SETTLE_POSITION)),
            params: abi.encode(poolKey, tokenId, positionIndex, amount0, amount1)
        });
    }

    /**
     * @notice Prepares a DECREASE_LIQUIDITY action
     */
    function prepareDecrease(PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, uint256 amount)
        internal
        pure
        returns (PreparedAction memory)
    {
        return PreparedAction({
            action: bytes1(uint8(MMActions.DECREASE_LIQUIDITY)),
            params: abi.encode(poolKey, tokenId, positionIndex, amount)
        });
    }

    /**
     * @notice Prepares a SETTLE_POSITION_FROM_DELTAS action
     */
    function prepareSettleFromDeltas(
        PoolKey memory poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        bool settleIn0,
        bool settleIn1
    ) internal pure returns (PreparedAction memory) {
        return PreparedAction({
            action: bytes1(uint8(MMActions.SETTLE_POSITION_FROM_DELTAS)),
            params: abi.encode(poolKey, tokenId, positionIndex, settleIn0, settleIn1)
        });
    }

    /**
     * @notice Prepares a BURN_POSITION action
     */
    function prepareBurn(PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex)
        internal
        pure
        returns (PreparedAction memory)
    {
        return PreparedAction({
            action: bytes1(uint8(MMActions.BURN_POSITION)), params: abi.encode(poolKey, tokenId, positionIndex)
        });
    }

    /**
     * @notice Prepares a DECOMMIT_SIGNAL action
     */
    function prepareDecommit(uint256 tokenId) internal pure returns (PreparedAction memory) {
        return PreparedAction({action: bytes1(uint8(MMActions.DECOMMIT_SIGNAL)), params: abi.encode(tokenId)});
    }

    /**
     * @notice Prepares a RENEW_SIGNAL action
     */
    function prepareRenew(uint256 tokenId, bytes memory liquiditySignal) internal pure returns (PreparedAction memory) {
        return
            PreparedAction({
                action: bytes1(uint8(MMActions.RENEW_SIGNAL)), params: abi.encode(tokenId, liquiditySignal)
            });
    }

    /**
     * @notice Prepares a SEIZE_POSITION action
     */
    function prepareSeize(
        PoolKey memory poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (PreparedAction memory) {
        return PreparedAction({
            action: bytes1(uint8(MMActions.SEIZE_POSITION)),
            params: abi.encode(poolKey, tokenId, positionIndex, amount0, amount1)
        });
    }

    /**
     * @notice Prepares an INCREASE_LIQUIDITY action
     */
    function prepareIncrease(
        PoolKey memory poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity
    ) internal pure returns (PreparedAction memory) {
        return PreparedAction({
            action: bytes1(uint8(MMActions.INCREASE_LIQUIDITY)),
            params: abi.encode(poolKey, tokenId, positionIndex, tickLower, tickUpper, liquidity)
        });
    }

    /**
     * @notice Prepares an INCREASE_LIQUIDITY_FROM_DELTAS action
     */
    function prepareIncreaseFromDeltas(
        PoolKey memory poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        int24 tickLower,
        int24 tickUpper
    ) internal pure returns (PreparedAction memory) {
        return PreparedAction({
            action: bytes1(uint8(MMActions.INCREASE_LIQUIDITY_FROM_DELTAS)),
            params: abi.encode(poolKey, tokenId, positionIndex, tickLower, tickUpper)
        });
    }

    function prepareExtendGracePeriod(
        PoolKey memory poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        uint8 settlementTokenIndex,
        uint32 verifierIndex,
        bytes memory settlementProof
    ) internal pure returns (PreparedAction memory) {
        return PreparedAction({
            action: bytes1(uint8(MMActions.EXTEND_GRACE_PERIOD)),
            params: abi.encode(poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof)
        });
    }

    /**
     * @notice Prepares a CHECKPOINT action
     */
    function prepareCheckpoint(uint256 tokenId, uint256 positionIndex, bytes memory liquiditySignal)
        internal
        pure
        returns (PreparedAction memory)
    {
        return PreparedAction({
            action: bytes1(uint8(MMActions.CHECKPOINT)),
            params: abi.encode(tokenId, positionIndex, liquiditySignal, liquiditySignal.length > 0)
        });
    }

    /**
     * @notice Prepares a WRAP_NATIVE action
     */
    function prepareWrapNative(uint256 amount) internal pure returns (PreparedAction memory) {
        return PreparedAction({action: bytes1(uint8(MMActions.WRAP_NATIVE)), params: abi.encode(amount)});
    }

    /**
     * @notice Prepares an UNWRAP_NATIVE action
     */
    function prepareUnwrapNative(uint256 amount) internal pure returns (PreparedAction memory) {
        return PreparedAction({action: bytes1(uint8(MMActions.UNWRAP_NATIVE)), params: abi.encode(amount)});
    }

    /**
     * @notice Prepares an UNWRAP_LCC action
     */
    function prepareUnwrapLcc(address lcc, uint256 amount, address recipient, bool payerIsUser)
        internal
        pure
        returns (PreparedAction memory)
    {
        return PreparedAction({
            action: bytes1(uint8(MMActions.UNWRAP_LCC)), params: abi.encode(lcc, amount, recipient, payerIsUser)
        });
    }

    // ============ CONVENIENCE METHODS (for backward compatibility) ============

    /**
     * @notice Commits a signal (single action execution)
     * @dev For backward compatibility - use prepareCommit + execute for batching
     */
    function commit(MMPositionManager mmpm, PoolKey memory poolKey, bytes memory liquiditySignal) internal {
        PreparedAction[] memory prepared = new PreparedAction[](1);
        prepared[0] = prepareCommit(poolKey, liquiditySignal);
        execute(mmpm, prepared);
    }

    /**
     * @notice Commits a signal with owner (single action execution)
     * @dev For backward compatibility - use prepareCommitWithOwner + execute for batching
     */
    function commitWithOwner(
        MMPositionManager mmpm,
        PoolKey memory poolKey,
        bytes memory liquiditySignal,
        address owner
    ) internal {
        PreparedAction[] memory prepared = new PreparedAction[](1);
        prepared[0] = prepareCommitWithOwner(poolKey, liquiditySignal, owner);
        execute(mmpm, prepared);
    }

    /**
     * @notice Mints a position (single action execution)
     * @dev For backward compatibility - use prepareMint + execute for batching
     */
    function mint(MMPositionManager mmpm, PoolKey memory poolKey, uint256 tokenId, int24 tl, int24 tu, uint256 liq)
        internal
    {
        PreparedAction[] memory prepared = new PreparedAction[](1);
        prepared[0] = prepareMint(poolKey, tokenId, tl, tu, liq);
        execute(mmpm, prepared);
    }

    /**
     * @notice Settles a position (single action execution)
     * @dev For backward compatibility - use prepareSettle + execute for batching
     */
    function settle(MMPositionManager mmpm, PoolKey memory poolKey, uint256 tokenId, uint256 idx, int128 a0, int128 a1)
        internal
    {
        PreparedAction[] memory prepared = new PreparedAction[](1);
        prepared[0] = prepareSettle(poolKey, tokenId, idx, a0, a1);
        executeWithUnlock(mmpm, prepared, block.timestamp + 3600);
    }

    /**
     * @notice Decreases liquidity (single action execution)
     * @dev For backward compatibility - use prepareDecrease + execute for batching
     */
    function decrease(MMPositionManager mmpm, PoolKey memory poolKey, uint256 tokenId, uint256 idx, uint256 amt)
        internal
    {
        PreparedAction[] memory prepared = new PreparedAction[](1);
        prepared[0] = prepareDecrease(poolKey, tokenId, idx, amt);
        executeWithUnlock(mmpm, prepared, block.timestamp + 3600);
    }

    /**
     * @notice Increases liquidity (single action execution)
     * @dev For backward compatibility - use prepareIncrease + execute for batching
     */
    function increase(
        MMPositionManager mmpm,
        PoolKey memory poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity
    ) internal {
        PreparedAction[] memory prepared = new PreparedAction[](1);
        prepared[0] = prepareIncrease(poolKey, tokenId, positionIndex, tickLower, tickUpper, liquidity);
        executeWithUnlock(mmpm, prepared, block.timestamp + 3600);
    }

    /**
     * @notice Burns a position (single action execution)
     * @dev For backward compatibility - use prepareBurn + execute for batching
     */
    function burn(MMPositionManager mmpm, PoolKey memory poolKey, uint256 tokenId, uint256 idx) internal {
        PreparedAction[] memory prepared = new PreparedAction[](1);
        prepared[0] = prepareBurn(poolKey, tokenId, idx);

        // unlock pm and execute the actions
        executeWithUnlock(mmpm, prepared, block.timestamp + 3600);
    }

    function extendGracePeriod(
        MMPositionManager mmpm,
        PoolKey memory poolKey,
        uint256 tokenId,
        uint256 idx,
        uint8 settlementTokenIndex,
        uint32 verifierIndex,
        bytes memory settlementProof
    ) internal {
        PreparedAction[] memory prepared = new PreparedAction[](1);
        prepared[0] =
            prepareExtendGracePeriod(poolKey, tokenId, idx, settlementTokenIndex, verifierIndex, settlementProof);
        execute(mmpm, prepared);
    }

    /**
     * @notice Wraps native ETH to WETH (single action execution)
     */
    /**
     * @notice Wraps native ETH to WETH (single action execution)
     * @dev Sends ETH as msg.value to create native delta, then wraps it to WETH delta
     * @param mmpm The MMPositionManager instance
     * @param amount The amount of ETH to wrap (also sent as msg.value to create native delta)
     */
    function wrapNative(MMPositionManager mmpm, uint256 amount) internal {
        PreparedAction[] memory prepared = new PreparedAction[](1);
        prepared[0] = prepareWrapNative(amount);
        // Use execute overload with value to send ETH as msg.value
        // This creates a native delta via _handleNativeValue, which can then be wrapped
        execute(mmpm, prepared, amount);
    }

    /**
     * @notice Unwraps WETH to native ETH (single action execution)
     */
    function unwrapNative(MMPositionManager mmpm, uint256 amount) internal {
        PreparedAction[] memory prepared = new PreparedAction[](1);
        prepared[0] = prepareUnwrapNative(amount);
        execute(mmpm, prepared);
    }

    /**
     * @notice Unwraps LCC tokens (single action execution)
     * @dev For backward compatibility - use prepareUnwrapLCC + execute for batching
     */
    function unwrapLcc(MMPositionManager mmpm, address lcc, uint256 amount, address recipient, bool payerIsUser)
        internal
    {
        PreparedAction[] memory prepared = new PreparedAction[](1);
        prepared[0] = prepareUnwrapLcc(lcc, amount, recipient, payerIsUser);
        execute(mmpm, prepared);
    }

    /**
     * @notice Decommits a position (single action execution)
     * @dev For backward compatibility - use prepareDecommit + execute for batching
     */
    function decommit(MMPositionManager mmpm, uint256 tokenId) internal {
        PreparedAction[] memory prepared = new PreparedAction[](1);
        prepared[0] = prepareDecommit(tokenId);

        // unlock the poolmanager and execute the action
        executeWithUnlock(mmpm, prepared, block.timestamp + 3600);
    }

    /**
     * @notice Renews a signal (single action execution)
     * @dev For backward compatibility - use prepareRenew + execute for batching
     */
    function renew(MMPositionManager mmpm, uint256 tokenId, bytes memory liquiditySignal) internal {
        PreparedAction[] memory prepared = new PreparedAction[](1);
        prepared[0] = prepareRenew(tokenId, liquiditySignal);
        execute(mmpm, prepared);
    }

    /**
     * @notice Seizes a position (single action execution)
     * @dev For backward compatibility - use prepareSeize + execute for batching
     */
    function seize(
        MMPositionManager mmpm,
        PoolKey memory poolKey,
        uint256 tokenId,
        uint256 idx,
        uint256 a0,
        uint256 a1
    ) internal {
        PreparedAction[] memory prepared = new PreparedAction[](1);
        prepared[0] = prepareSeize(poolKey, tokenId, idx, a0, a1);
        execute(mmpm, prepared);
    }

    /**
     * @notice Checkpoints a position (single action execution)
     * @dev For backward compatibility - use prepareCheckpoint + execute for batching
     */
    function checkpoint(MMPositionManager mmpm, uint256 tokenId, uint256 positionIndex, bytes memory liquiditySignal)
        internal
    {
        PreparedAction[] memory prepared = new PreparedAction[](1);
        prepared[0] = prepareCheckpoint(tokenId, positionIndex, liquiditySignal);
        execute(mmpm, prepared);
    }
}
