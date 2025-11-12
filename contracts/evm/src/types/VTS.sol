// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct TokenConfiguration {
    // Grace period time
    uint256 gracePeriodTime;
    // Seizure unlock time
    uint256 seizureUnlockTime;
    // Base VTS Rate in bps (basis points)
    uint256 baseVTSRate;
    // Max grace period time
    uint256 maxGracePeriodTime;
}

struct MarketVTSConfiguration {
    // Token configuration for token0
    TokenConfiguration token0;
    // Token configuration for token1
    TokenConfiguration token1;
    // Fee share applied to LP fees when protocol covers deficits (in basis points)
    uint16 coverageFeeShare;
    // Minimum residual liquidity units threshold for full position closure during seizure
    uint256 minResidualUnits;
}
