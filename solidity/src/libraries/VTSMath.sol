// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

library VTSMath {
    uint256 internal constant ONE_BPS = 10000; // basis points
    uint256 internal constant ONE_1E18 = 1e18;

    /// @notice Compute VTS_current as settled/committed in basis points
    function vtsCurrentBps(uint256 settled, uint256 committed) internal pure returns (uint256) {
        if (committed == 0) return 0;
        return FullMath.mulDiv(settled, ONE_BPS, committed);
    }

    /// @notice Compute VTS_required bps from deficit and commitment
    function vtsRequired(uint256 deficit, uint256 committed) internal pure returns (uint256) {
        if (committed == 0 || deficit == 0) return 0;
        uint256 r = FullMath.mulDiv(deficit, ONE_BPS, committed);
        if (r > ONE_BPS) return ONE_BPS;
        return r;
    }
}
