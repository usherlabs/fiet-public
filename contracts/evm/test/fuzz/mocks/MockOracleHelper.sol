// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IOracleHelper} from "../../../src/interfaces/IOracleHelper.sol";

/// @notice Minimal oracle helper stub for Echidna harnesses.
/// @dev This mock is intentionally flexible:
///      - If your harness doesn't care about prices/values, you can leave everything at 0.
///      - If your harness needs pricing/signal values (e.g. COMMIT/SIG backing tests),
///        use `setPrices` and `setTotalValue`.
contract MockOracleHelper is IOracleHelper {
    address internal immutable _oracle;
    uint256 internal _price0;
    uint256 internal _price1;
    uint256 internal _totalValue;

    constructor(address oracle_) {
        _oracle = oracle_;
    }

    function setPrices(uint256 p0, uint256 p1) external {
        _price0 = p0;
        _price1 = p1;
    }

    function setTotalValue(uint256 v) external {
        _totalValue = v;
    }

    function oracle() external view returns (address) {
        return _oracle;
    }

    function tickerHashToAsset(bytes32) external pure returns (address) {
        return address(0);
    }

    function registerTicker(string calldata, address) external pure {
        revert("unused");
    }

    function getAssetByTicker(string calldata) external pure returns (address) {
        return address(0);
    }

    function getPriceByTicker(string calldata) external pure returns (uint256) {
        return 0;
    }

    function validateMarketOracles(address, address) external pure {
        // unused in these harnesses
    }

    function getTotalValue(string[] memory, uint256[] memory) external view returns (uint256) {
        return _totalValue;
    }

    function getPriceForLcc(address) external view returns (uint256) {
        return _price0;
    }

    function getPricesForLccPair(address, address) external view returns (uint256, uint256) {
        return (_price0, _price1);
    }
}

