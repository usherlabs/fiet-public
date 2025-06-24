// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Helper contract
library SepoliaConstants {
    // To deploy uniswap pool
    address constant POOL_MANAGER = 0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317;
    address constant POSITION_MANAGER =
        0xAc631556d3d4019C95769033B5E719dD77124BAc;
    address constant DEPLOYER_CREATE2 =
        0x4e59b44847b379578588920cA78FbF26c0B4956C;
    // To deploy LCC based tokens
    address constant TokenA = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d; // token USDC
    address constant TokenB = 0x99729dD47ACdA1713171501250E57a36aDCE5D08; // token USDT
    // LCC tokens
    address constant LCCtokenA = 0xd94c3C1BC47e0Bb528d912089C9cA6A457cfc320; // LCC USDC
    address constant LCCtokenB = 0x6c8537d89dd1C612AD0D7a9E48eEFFDBe9cB6A8e; // LCC USDT
    // Proxy hook
    address constant ProxyHook = 0xcf75b350696C9FfdE9D7A69FF10Fb65C57776888;
}
