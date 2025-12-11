// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Helper contract for Arbitrum One (Mainnet) constants
library ArbitrumConstants {
    // To deploy uniswap pool - placeholders for v4
    address constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32; // Actual v4 PoolManager on Arbitrum One
    address constant POSITION_MANAGER = 0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869;
    address constant DEPLOYER_CREATE2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C; // Assuming same CREATE2 deployer
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3; // From v3 docs
    address constant UNIVERSAL_ROUTER = 0xA51afAFe0263b40EdaEf0Df8781eA9aa03E381a3; // From v3 docs
    address constant STATE_VIEW = 0x76Fd297e2D437cd7f76d50F01AfE6160f86e9990; // Replace if needed

    // Gas token (WETH) addresses
    address constant USDC_ADDRESS = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant ARB_ADDRESS = 0x912CE59144191C1204E64559FE8253a0e49E6548;

    // Native ETH address (zero address)
    address constant ETH_ADDRESS = address(0);
}
