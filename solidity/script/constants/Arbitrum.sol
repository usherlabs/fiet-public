// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Helper contract for Arbitrum One (Mainnet) constants
library ArbitrumConstants {
    // To deploy uniswap pool - placeholders for v4
    address constant POOL_MANAGER = 0xFF34e285f8ed393Fa4495b6F5D926C2e5Ed1bd66; // Actual v4 PoolManager on Arbitrum One
    address constant POSITION_MANAGER =
        address(0x0000000000000000000000000000000000000000); // Replace with actual
    address constant DEPLOYER_CREATE2 =
        0x4e59b44847b379578588920cA78FbF26c0B4956C; // Assuming same CREATE2 deployer
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3; // From v3 docs
    address constant UNIVERSAL_ROUTER =
        0xA51afAFe0263b40EdaEf0Df8781eA9aa03E381a3; // From v3 docs
    address constant STATE_VIEW =
        address(0x0000000000000000000000000000000000000000); // Replace if needed

    // Gas token (WETH) addresses
    address constant WETH_ARBITRUM = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant WETH_MAINNET = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Native ETH address (zero address)
    address constant ETH_ADDRESS = address(0);
}
