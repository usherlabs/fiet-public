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
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // To deploy LCC based tokens
    address constant TokenA = 0x99729dD47ACdA1713171501250E57a36aDCE5D08; // token USDT
    address constant TokenB = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d; // token USDC

    // LCC tokens
    address constant LCCtokenA = 0x1EEA49ee74Fe3d3B767dc42FcF4459Ec8d5703a1; // LCC USDT
    address constant LCCtokenB = 0x9233496A2778474d2A5384e899F47b889609Af9d; // LCC USDC

    // Proxy hook
    address constant ProxyHook = 0xCBc000454233D4bD3467A0cdA18c1BE019842888;
}
