// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Helper contract
library EthConstants {
    // To deploy uniswap pool
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address constant DEPLOYER_CREATE2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant UNIVERSAL_ROUTER = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b;
    address constant STATE_VIEW = 0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C;

    // Tokens
    address constant WETH_ADDRESS = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
    address constant USDC_ADDRESS = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    // address constant USDT_ADDRESS = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
    // address constant ARB_ADDRESS = 0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9;

    // Native ETH address (zero address)
    address constant ETH_ADDRESS = address(0);
}
