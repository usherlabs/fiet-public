// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IResilientOracle} from "src/interfaces/IResilientOracle.sol";

/// @dev Minimal Venus-style oracle interface for MAIN/PIVOT/FALLBACK oracles.
interface IOracleInterface {
    function getPrice(address asset) external view returns (uint256);
}

/// @dev Minimal, test-only ResilientOracle mock for E2E scripts.
contract MockResilientOracle is IResilientOracle {
    mapping(address => TokenConfig) internal _cfg;
    mapping(address => uint256) internal _price; // USD price, 18 decimals
    bool internal _paused;

    function setPaused(bool paused_) external {
        _paused = paused_;
    }

    function setPrice(address asset, uint256 price) external {
        _price[asset] = price;
    }

    function setTokenConfig(TokenConfig calldata tokenConfig) external {
        _cfg[tokenConfig.asset] = tokenConfig;
    }

    function getPrice(address asset) external view returns (uint256) {
        TokenConfig memory cfg = _cfg[asset];
        // Middle-ground: mirror real ResilientOracle flow by reading MAIN oracle from token config.
        if (cfg.enableFlagsForOracles[uint256(OracleRole.MAIN)] && cfg.oracles[uint256(OracleRole.MAIN)] != address(0))
        {
            return IOracleInterface(cfg.oracles[uint256(OracleRole.MAIN)]).getPrice(asset);
        }
        return _price[asset];
    }

    function getUnderlyingPrice(address vToken) external view returns (uint256) {
        // In this repo, "vToken" is used as LCC address in some contexts; E2E doesn't rely on this.
        // Keep behavior consistent with getPrice for convenience.
        TokenConfig memory cfg = _cfg[vToken];
        if (cfg.enableFlagsForOracles[uint256(OracleRole.MAIN)] && cfg.oracles[uint256(OracleRole.MAIN)] != address(0))
        {
            return IOracleInterface(cfg.oracles[uint256(OracleRole.MAIN)]).getPrice(vToken);
        }
        return _price[vToken];
    }

    function getTokenConfig(address asset) external view returns (TokenConfig memory) {
        return _cfg[asset];
    }

    function getOracle(address asset, OracleRole role) external view returns (address oracle, bool enabled) {
        TokenConfig memory cfg = _cfg[asset];
        oracle = cfg.oracles[uint256(role)];
        enabled = cfg.enableFlagsForOracles[uint256(role)];
    }

    function updateAssetPrice(address) external {}

    function paused() external view returns (bool) {
        return _paused;
    }
}

