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
    // Time t in seconds.
    // - Governs how long market demand is tracked for. Predicated on the question: What does demand mean for this token?
    // - Higher tracked market demand, means requiring more liquidity settled.
    // - Can be 5 minutes (high volume + rapid settlements) -> 48 hours (low volume + slow settlements) depending on the market.
    uint256 timeWindow;
    // oracle address for this market, can be address(0) to use the default oracle
    address oracleFactory;
}
