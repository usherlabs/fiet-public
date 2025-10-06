// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct TokenConfiguration {
    // Grace period time
    uint256 gracePeriodTime;
    // Seizure unlock time
    uint256 seizureUnlockTime;
    // Base VTS Rate
    uint256 baseVTSRate;
}

struct MarketVTSConfiguration {
    // Token configuration for token0
    TokenConfiguration token0;
    // Token configuration for token1
    TokenConfiguration token1;
    // oracle address for this market, can be address(0) to use the default oracle
    address oracleFactory;
}
