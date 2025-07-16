// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Helper contract for Arbitrum One (Mainnet) constants
library ArbitrumConstants {
    // To deploy uniswap pool - placeholders for v4
    address constant POOL_MANAGER = 0x360e68faccca8ca495c1b759fd9eee466db9fb32; // Actual v4 PoolManager on Arbitrum One
    address constant POSITION_MANAGER =
        0xd88f38f930b7952f2db2432cb002e7abbf3dd869;
    address constant DEPLOYER_CREATE2 =
        0x4e59b44847b379578588920cA78FbF26c0B4956C; // Assuming same CREATE2 deployer
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3; // From v3 docs
    address constant UNIVERSAL_ROUTER =
        0xa51afafe0263b40edaef0df8781ea9aa03e381a3; // From v3 docs
    address constant STATE_VIEW =
        address(0x0000000000000000000000000000000000000000); // Replace if needed

    // Gas token (WETH) addresses
    address constant WETH_ADDRESS = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant USDC_ADDRESS = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant ARB_ADDRESS = 0x912CE59144191C1204E64559FE8253a0e49E6548;

    // Native ETH address (zero address)
    address constant ETH_ADDRESS = address(0);
}
