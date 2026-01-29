// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSCommitLib} from "../../src/libraries/VTSCommitLib.sol";
import {VTSCommitLibHarness} from "../libraries/harnesses/VTSCommitLibHarness.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FullMath} from "v4-periphery/lib/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";

/// @notice Echidna harness for COV-03:
///         exercises VTSCommitLib.incrementCoverage and asserts the conditional routing:
///         - DICE: if totalDeficitPrincipal > 0, bump coveragePerDeficitIndexX128; else add to coverageResidualDICE.
///         - CISE: if totalSettled > 0, bump coveragePerSettledIndexX128; else add to coverageResidualCISE.
contract VTSCoverageBurnCOV03EchidnaTest {
    VTSCommitLibHarness internal commitHarness;

    // Must match `foundry.toml` profile `echidna` hard-link for `VTSCommitLib`.
    address internal constant VTS_COMMIT_LIB = 0x08f6e330612797F445209Bfee166c949cfd0BF4F;

    PoolId internal constant POOL_ID = PoolId.wrap(bytes32(uint256(0xC0C03)));
    uint256 internal constant MAX_UNITS = 1e36;

    bool internal checked;
    bool internal lastOk;

    uint8 internal sTokenIndex;
    uint256 internal sTotalPrincipal;
    uint256 internal sTotalSettled;
    uint256 internal sCovered;

    struct Snap {
        uint256 dIndex;
        uint256 dResidual;
        uint256 sIndex;
        uint256 sResidual;
    }

    Snap internal beforeSnap;
    Snap internal afterSnap;

    constructor() {
        _deployVTSCommitLib();
        commitHarness = new VTSCommitLibHarness();
    }

    /// @notice Fuzz incrementCoverage and assert conditional index vs residual updates.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_increment_coverage(
        uint8 tokenIndexRaw,
        uint256 totalPrincipalRaw,
        uint256 totalSettledRaw,
        uint256 coveredRaw
    ) external {
        checked = false;
        lastOk = true;
        _cacheInputs(tokenIndexRaw, totalPrincipalRaw, totalSettledRaw, coveredRaw);

        bool ok = _applyAndCheck();
        checked = true;
        lastOk = ok;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_cov_03_conditional_index_increment() external view returns (bool) {
        return !checked || lastOk;
    }

    // Keep a second trivial property to avoid rare Echidna instability with single-property targets.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_cov_03_smoke() external pure returns (bool) {
        return true;
    }

    function _expectDICE(uint256 indexBefore, uint256 residualBefore, uint256 totalPrincipal, uint256 coveredAmount)
        internal
        pure
        returns (uint256 expIndex, uint256 expResidual)
    {
        if (coveredAmount == 0) {
            return (indexBefore, residualBefore);
        }
        if (totalPrincipal > 0) {
            uint256 deltaIndex = FullMath.mulDiv(coveredAmount, FixedPoint128.Q128, totalPrincipal);
            return (indexBefore + deltaIndex, residualBefore);
        }
        return (indexBefore, residualBefore + coveredAmount);
    }

    function _expectCISE(uint256 indexBefore, uint256 residualBefore, uint256 totalSettled, uint256 coveredAmount)
        internal
        pure
        returns (uint256 expIndex, uint256 expResidual)
    {
        if (coveredAmount == 0) {
            return (indexBefore, residualBefore);
        }
        if (totalSettled > 0) {
            uint256 deltaIndex = FullMath.mulDiv(coveredAmount, FixedPoint128.Q128, totalSettled);
            return (indexBefore + deltaIndex, residualBefore);
        }
        return (indexBefore, residualBefore + coveredAmount);
    }

    function _clamp(uint256 value) internal pure returns (uint256) {
        return value > MAX_UNITS ? MAX_UNITS : value;
    }

    function _cacheInputs(uint8 tokenIndexRaw, uint256 totalPrincipalRaw, uint256 totalSettledRaw, uint256 coveredRaw)
        internal
    {
        sTokenIndex = tokenIndexRaw % 2;
        sTotalPrincipal = _clamp(totalPrincipalRaw);
        sTotalSettled = _clamp(totalSettledRaw);
        sCovered = _clamp(coveredRaw);

        commitHarness.setPoolTotalDeficitPrincipal(POOL_ID, sTokenIndex, sTotalPrincipal);
        commitHarness.setPoolTotalSettled(POOL_ID, sTokenIndex, sTotalSettled);
    }

    function _applyAndCheck() internal returns (bool) {
        _snapshot(beforeSnap);
        commitHarness.incrementCoverage(POOL_ID, sTokenIndex, sCovered);
        _snapshot(afterSnap);

        (uint256 expDIndex, uint256 expDResidual) =
            _expectDICE(beforeSnap.dIndex, beforeSnap.dResidual, sTotalPrincipal, sCovered);
        (uint256 expSIndex, uint256 expSResidual) =
            _expectCISE(beforeSnap.sIndex, beforeSnap.sResidual, sTotalSettled, sCovered);

        return afterSnap.dIndex == expDIndex && afterSnap.dResidual == expDResidual && afterSnap.sIndex == expSIndex
            && afterSnap.sResidual == expSResidual;
    }

    function _snapshot(Snap storage snap) internal {
        snap.dIndex = commitHarness.getCoveragePerDeficitIndexX128(POOL_ID, sTokenIndex);
        snap.dResidual = commitHarness.getCoverageResidualDICE(POOL_ID, sTokenIndex);
        snap.sIndex = commitHarness.getCoveragePerSettledIndexX128(POOL_ID, sTokenIndex);
        snap.sResidual = commitHarness.getCoverageResidualCISE(POOL_ID, sTokenIndex);
    }

    function _deployVTSCommitLib() internal {
        bytes32 salt = keccak256("echidna.VTSCommitLib");
        bytes memory initCode = type(VTSCommitLib).creationCode;
        address deployed;
        assembly {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(deployed != address(0), "VTSCommitLib deploy failed");
        require(deployed == VTS_COMMIT_LIB, "VTSCommitLib addr mismatch");
    }
}
