// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MMPositionManager} from "../../src/MMPositionManager.sol";

library MMActionAdapter {
    function _concat(bytes1[] memory actions) internal pure returns (bytes memory out) {
        for (uint256 i = 0; i < actions.length; i++) {
            out = bytes.concat(out, actions[i]);
        }
    }

    function commit(MMPositionManager mmpm, PoolKey memory poolKey, bytes memory liquiditySignal) internal {
        bytes1[] memory acts = new bytes1[](1);
        acts[0] = bytes1(uint8(MMPositionManager.MMAction.COMMIT_SIGNAL));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(poolKey, liquiditySignal);
        mmpm.modifyLiquiditiesWithoutUnlock(_concat(acts), params);
    }

    function mint(MMPositionManager mmpm, PoolKey memory poolKey, uint256 tokenId, int24 tl, int24 tu, uint256 liq)
        internal
    {
        bytes1[] memory acts = new bytes1[](1);
        acts[0] = bytes1(uint8(MMPositionManager.MMAction.MINT_POSITION));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(poolKey, tokenId, tl, tu, liq);
        mmpm.modifyLiquiditiesWithoutUnlock(_concat(acts), params);
    }

    function settle(MMPositionManager mmpm, PoolKey memory poolKey, uint256 tokenId, uint256 idx, int128 a0, int128 a1)
        internal
    {
        bytes1[] memory acts = new bytes1[](1);
        acts[0] = bytes1(uint8(MMPositionManager.MMAction.SETTLE_POSITION));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(poolKey, tokenId, idx, a0, a1);
        mmpm.modifyLiquiditiesWithoutUnlock(_concat(acts), params);
    }

    function decrease(
        MMPositionManager mmpm,
        PoolKey memory poolKey,
        uint256 tokenId,
        uint256 idx,
        int24 tu,
        int24 tl,
        uint256 amt
    ) internal {
        bytes1[] memory acts = new bytes1[](1);
        acts[0] = bytes1(uint8(MMPositionManager.MMAction.DECREASE_LIQUIDITY));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(poolKey, tokenId, idx, tu, tl, amt);
        mmpm.modifyLiquiditiesWithoutUnlock(_concat(acts), params);
    }

    function burn(MMPositionManager mmpm, PoolKey memory poolKey, uint256 tokenId, uint256 idx) internal {
        bytes1[] memory acts = new bytes1[](1);
        acts[0] = bytes1(uint8(MMPositionManager.MMAction.BURN_POSITION));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(poolKey, tokenId, idx);
        mmpm.modifyLiquiditiesWithoutUnlock(_concat(acts), params);
    }

    function decommit(MMPositionManager mmpm, PoolKey memory poolKey, uint256 tokenId) internal {
        bytes1[] memory acts = new bytes1[](1);
        acts[0] = bytes1(uint8(MMPositionManager.MMAction.DECOMMIT));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(poolKey, tokenId);
        mmpm.modifyLiquiditiesWithoutUnlock(_concat(acts), params);
    }

    function renew(MMPositionManager mmpm, uint256 tokenId, bytes memory liquiditySignal) internal {
        bytes1[] memory acts = new bytes1[](1);
        acts[0] = bytes1(uint8(MMPositionManager.MMAction.RENEW_SIGNAL));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(tokenId, liquiditySignal);
        mmpm.modifyLiquiditiesWithoutUnlock(_concat(acts), params);
    }

    function seize(MMPositionManager mmpm, PoolKey memory poolKey, uint256 tokenId, uint256 idx, uint256 a0, uint256 a1)
        internal
    {
        bytes1[] memory acts = new bytes1[](1);
        acts[0] = bytes1(uint8(MMPositionManager.MMAction.SEIZE_POSITION));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(poolKey, tokenId, idx, a0, a1);
        mmpm.modifyLiquiditiesWithoutUnlock(_concat(acts), params);
    }
}
