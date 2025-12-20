// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

// Helper contract
library SepoliaConstants {
    // To deploy uniswap pool
    address constant POOL_MANAGER = 0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317;
    address constant POSITION_MANAGER = 0xAc631556d3d4019C95769033B5E719dD77124BAc;
    address constant DEPLOYER_CREATE2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant UNIVERSAL_ROUTER = 0xeFd1D4bD4cf1e86Da286BB4CB1B8BcED9C10BA47;
    address constant STATE_VIEW = 0x9D467FA9062b6e9B1a46E26007aD82db116c67cB;

    // Tokens
    address constant USDC_ADDRESS = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
    // address constant USDT_ADDRESS = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
    // address constant ARB_ADDRESS = 0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9;

    // Native ETH address (zero address)
    address constant ETH_ADDRESS = address(0);
}
