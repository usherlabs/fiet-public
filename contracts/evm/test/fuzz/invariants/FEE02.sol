// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSFeeLibHarness} from "../../libraries/harnesses/VTSFeeLibHarness.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionId} from "../../../src/types/Position.sol";
import {MarketVTSConfiguration, TokenConfiguration} from "../../../src/types/VTS.sol";

/// @notice fuzz harness for FEE-02: New positions must not receive fee-sharing bonuses on creation.
///         New positions (zero CISE exposure) must not receive bonuses on creation.
///         This checks that touching a fresh position cannot allocate bonuses or
///         mutate pot/protocolFee/pending state without prior exposure.
///
/// @dev Each action resets CSI epoch / remaining-factor baseline so prior fuzz steps cannot desynchronise
///      harness expectations from `VTSFeeLib` (Medusa reuses one contract instance).
contract FEE02 {
    VTSFeeLibHarness internal feeHarness;

    PoolId internal constant POOL_ID = PoolId.wrap(bytes32(uint256(0xFEE02)));
    PositionId internal constant POSITION_ID = PositionId.wrap(bytes32(uint256(0xFEE02)));
    uint256 internal constant MAX_UNITS = 1e36;

    bool internal checked;
    bool internal lastOk;

    constructor() {
        feeHarness = new VTSFeeLibHarness();
        feeHarness.setupPool(POOL_ID, _config(1000));
        feeHarness.setupPosition(POSITION_ID, POOL_ID);
    }

    /// @notice Call afterTouchPosition and assert no bonus is allocated for zero exposure.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_no_bonus_on_creation(uint256 protocolFeeAccruedRaw, uint256 totalExposureRaw) external {
        checked = false;
        lastOk = true;

        uint256 protocolFee = _clamp(protocolFeeAccruedRaw);
        uint256 totalExposure = _clamp(totalExposureRaw);

        _resetFeeShareIsolationBaseline();

        // Seed a pot and pool exposure so the only gating factor is the position's zero exposure.
        feeHarness.setProtocolFeeAccrued(POOL_ID, protocolFee, protocolFee);
        feeHarness.setPoolTotalCISEExposure(POOL_ID, totalExposure, totalExposure);
        // New position: no realised CISE exposure and no pending fee adjustments.
        feeHarness.setCISEExposure(POSITION_ID, 0, 0);
        feeHarness.setPendingFeeAdj(POSITION_ID, 0, 0);

        // Snapshot accounting before fee processing.
        (uint256 fee0Before, uint256 fee1Before) = feeHarness.getProtocolFeeAccrued(POOL_ID);
        (uint256 pot0Before, uint256 pot1Before) = feeHarness.getSlashedPot(POOL_ID);
        (int256 pend0Before, int256 pend1Before) = feeHarness.getPendingFeeAdj(POSITION_ID);

        // Touch position fees (this would allocate bonuses if exposure were non-zero).
        feeHarness.afterTouchPosition(POSITION_ID);

        // Nothing should move: no bonus allocation and no materialisation.
        (uint256 fee0After, uint256 fee1After) = feeHarness.getProtocolFeeAccrued(POOL_ID);
        (uint256 pot0After, uint256 pot1After) = feeHarness.getSlashedPot(POOL_ID);
        (int256 pend0After, int256 pend1After) = feeHarness.getPendingFeeAdj(POSITION_ID);

        checked = true;
        lastOk = fee0After == fee0Before && fee1After == fee1Before && pot0After == pot0Before
            && pot1After == pot1Before && pend0After == pend0Before && pend1After == pend1Before;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_fee_02_no_bonus_on_creation() external view returns (bool) {
        return !checked || lastOk;
    }

    // Keep a second trivial property to avoid rare property-runner instability with single-property targets.
    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_fee_02_smoke() external pure returns (bool) {
        return true;
    }

    function _resetFeeShareIsolationBaseline() internal {
        feeHarness.setProtocolFeeAccrued(POOL_ID, 0, 0);
        feeHarness.setSlashedPot(POOL_ID, 0, 0);
        feeHarness.setPendingFeeAdj(POSITION_ID, 0, 0);
        feeHarness.setFeesShared(POSITION_ID, 0, 0);
        feeHarness.setPoolTotalCISEExposure(POOL_ID, 0, 0);
        feeHarness.setPoolFeesSharedEpoch(POOL_ID, 0, 0);
        feeHarness.setPositionFeesSharedEpoch(POSITION_ID, 0, 0);
        feeHarness.setPoolFeesSharedRemainingFactorX128(POOL_ID, 0, 0);
        feeHarness.setPositionFeesSharedRemainingFactorLastX128(POSITION_ID, 0, 0);
    }

    function _clamp(uint256 value) internal pure returns (uint256) {
        return value > MAX_UNITS ? MAX_UNITS : value;
    }

    function _config(uint16 coverageFeeShare) internal pure returns (MarketVTSConfiguration memory) {
        TokenConfiguration memory tc = TokenConfiguration({
            gracePeriodTime: 0,
            baseVTSRate: 0,
            maxGracePeriodTime: 0,
            unbackedCommitmentGraceBypassTime: 0,
            unbackedCommitmentGraceBypassThreshold: 0
        });
        return MarketVTSConfiguration({
            token0: tc,
            token1: tc,
            coverageFeeShare: coverageFeeShare,
            minResidualUnits: 0,
            unbackedCommitmentGraceBypassBps: 0
        });
    }
}
