// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LiquidityHub} from "../../../src/LiquidityHub.sol";
import {LiquidityCommitmentCertificate} from "../../../src/LCC.sol";
import {MockOracleHelper} from "../mocks/MockOracleHelper.sol";
import {MockERC20Transferable} from "../mocks/MockERC20Transferable.sol";
import {Bounds} from "../../../src/libraries/Bounds.sol";
import {FuzzLinkedLibs} from "../base/FuzzLinkedLibs.sol";

/// @notice fuzz harness for HUB-03: Issuer-gated paths must never operate on invalid LCCs.
/// @dev "Any issuer-only path must first validate that the target lcc is a valid, initialised LCC."
///
/// Properties tested:
///   1. issue/cancel with an invalid (uninitialised) LCC address always reverts
///   2. issue/cancel with a valid LCC from a non-issuer always reverts
///   3. issue/cancel with a valid LCC from a valid issuer succeeds
contract HUB03 {
    uint256 internal constant MAX_AMOUNT = 1e24;

    LiquidityHub internal hub;
    LiquidityCommitmentCertificate internal lcc;
    MockERC20Transferable internal underlying;

    // Non-issuer actor whose calls must be rejected.
    HUB03Actor internal nonIssuer;

    // A random address that is not a valid LCC.
    address internal constant INVALID_LCC = address(0xDEAD);

    // Action/result: invalid LCC must revert.
    bool internal checkedInvalidLcc;
    bool internal lastInvalidLccOk;

    // Action/result: non-issuer must revert.
    bool internal checkedNonIssuer;
    bool internal lastNonIssuerOk;

    // Action/result: valid issuer + valid LCC must succeed.
    bool internal checkedValidIssuer;
    bool internal lastValidIssuerOk;

    // ================================================================
    // Constructor
    // ================================================================

    constructor() {
        FuzzLinkedLibs.deployLCCFactoryLinkedLib();
        FuzzLinkedLibs.deployLiquidityHubLinkedLib();

        MockOracleHelper oracleHelper = new MockOracleHelper(address(0));
        hub = new LiquidityHub(address(oracleHelper), "Ether", "ETH", 18, address(0), address(this));
        hub.setFactory(address(this), true);
        hub.setBoundLevel(address(hub), Bounds.BOUND_EXEMPT);

        address[] memory issuers = new address[](1);
        issuers[0] = address(this);

        underlying = new MockERC20Transferable();
        MockERC20Transferable other = new MockERC20Transferable();
        bytes memory marketRef = abi.encodePacked(address(this));
        (address l0, address l1) = hub.createLCCPair(marketRef, address(underlying), address(other), "TEST", issuers);
        hub.initialize(l0, l1, bytes32(uint256(1)), marketRef);
        lcc = LiquidityCommitmentCertificate(hub.getUnderlying(l0) == address(underlying) ? l0 : l1);

        nonIssuer = new HUB03Actor();

        _seedAll();
    }

    function _seedAll() internal {
        // Seed invalid-LCC guard: issue to INVALID_LCC must revert.
        (bool ok,) = address(hub)
            .call(abi.encodeWithSignature("issue(address,address,uint256)", INVALID_LCC, address(this), uint256(1)));
        checkedInvalidLcc = true;
        lastInvalidLccOk = !ok;

        // Seed non-issuer guard: non-issuer calling issue on valid LCC must revert.
        ok = nonIssuer.tryIssue(address(hub), address(lcc), address(nonIssuer), 1);
        checkedNonIssuer = true;
        lastNonIssuerOk = !ok;

        // Seed valid-issuer success: this contract is a valid issuer.
        uint256 supplyBefore = lcc.totalSupply();
        hub.issue(address(lcc), address(this), 1);
        checkedValidIssuer = true;
        lastValidIssuerOk = (lcc.totalSupply() == supplyBefore + 1);
    }

    /// @dev No-liquidity factory callback.
    function useMarketLiquidity(address, bytes32, uint256) external view returns (uint256) {
        if (msg.sender != address(hub)) revert();
        return 0;
    }

    // ================================================================
    // Actions — invalid LCC
    // ================================================================

    /// @dev issue() with an invalid LCC must revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_03_issue_invalid_lcc(uint256 amount) external {
        uint256 amt = (amount % MAX_AMOUNT) + 1;
        (bool ok,) = address(hub)
            .call(abi.encodeWithSignature("issue(address,address,uint256)", INVALID_LCC, address(this), amt));
        checkedInvalidLcc = true;
        lastInvalidLccOk = !ok;
    }

    /// @dev cancel() with an invalid LCC must revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_03_cancel_invalid_lcc(uint256 amount) external {
        uint256 amt = (amount % MAX_AMOUNT) + 1;
        (bool ok,) = address(hub)
            .call(abi.encodeWithSignature("cancel(address,address,uint256)", INVALID_LCC, address(this), amt));
        checkedInvalidLcc = true;
        lastInvalidLccOk = lastInvalidLccOk && !ok;
    }

    // ================================================================
    // Actions — non-issuer
    // ================================================================

    /// @dev Non-issuer calling issue() on a valid LCC must revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_03_non_issuer_issue(uint256 amount) external {
        uint256 amt = (amount % MAX_AMOUNT) + 1;
        bool ok = nonIssuer.tryIssue(address(hub), address(lcc), address(nonIssuer), amt);
        checkedNonIssuer = true;
        lastNonIssuerOk = !ok;
    }

    /// @dev Non-issuer calling cancel() on a valid LCC must revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_03_non_issuer_cancel(uint256 amount) external {
        uint256 amt = (amount % MAX_AMOUNT) + 1;
        hub.issue(address(lcc), address(nonIssuer), amt);
        bool ok = nonIssuer.tryCancel(address(hub), address(lcc), address(nonIssuer), amt);
        checkedNonIssuer = true;
        lastNonIssuerOk = lastNonIssuerOk && !ok;
    }

    /// @dev Non-issuer calling confirmTake() on a valid LCC must revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_03_non_issuer_confirmTake(uint256 amount) external {
        uint256 amt = (amount % MAX_AMOUNT) + 1;
        underlying.mint(address(hub), amt);
        bool ok = nonIssuer.tryConfirmTake(address(hub), address(lcc), amt);
        checkedNonIssuer = true;
        lastNonIssuerOk = lastNonIssuerOk && !ok;
    }

    // ================================================================
    // Actions — valid issuer (positive path)
    // ================================================================

    /// @dev Valid issuer calling issue() must succeed.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_03_valid_issuer_issue(uint256 amount) external {
        uint256 amt = (amount % MAX_AMOUNT) + 1;
        uint256 supplyBefore = lcc.totalSupply();
        hub.issue(address(lcc), address(this), amt);
        checkedValidIssuer = true;
        lastValidIssuerOk = (lcc.totalSupply() == supplyBefore + amt);
    }

    /// @dev Valid issuer calling cancel() must succeed (when holder has balance).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_03_valid_issuer_cancel(uint256 amount) external {
        uint256 bal = lcc.balanceOf(address(this));
        if (bal == 0) return;
        uint256 amt = (amount % bal) + 1;
        uint256 supplyBefore = lcc.totalSupply();
        hub.cancel(address(lcc), address(this), amt);
        checkedValidIssuer = true;
        lastValidIssuerOk = (lcc.totalSupply() == supplyBefore - amt);
    }

    // ================================================================
    // Properties
    // ================================================================

    /// @dev Issuer-gated paths with invalid LCC must always revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_hub_03_invalid_lcc_always_reverts() external view returns (bool) {
        return !checkedInvalidLcc || lastInvalidLccOk;
    }

    /// @dev Non-issuer calling issuer-gated paths must always revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_hub_03_non_issuer_always_reverts() external view returns (bool) {
        return !checkedNonIssuer || lastNonIssuerOk;
    }

    /// @dev Valid issuer with valid LCC must always succeed.
    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_hub_03_valid_issuer_succeeds() external view returns (bool) {
        return !checkedValidIssuer || lastValidIssuerOk;
    }
}

/// @dev Actor contract for non-issuer calls (msg.sender is this contract, not the harness).
contract HUB03Actor {
    function tryIssue(address hub, address lcc, address to, uint256 amount) external returns (bool ok) {
        (ok,) = hub.call(abi.encodeWithSignature("issue(address,address,uint256)", lcc, to, amount));
    }

    function tryCancel(address hub, address lcc, address from, uint256 amount) external returns (bool ok) {
        (ok,) = hub.call(abi.encodeWithSignature("cancel(address,address,uint256)", lcc, from, amount));
    }

    function tryConfirmTake(address hub, address lcc, uint256 amount) external returns (bool ok) {
        (ok,) = hub.call(abi.encodeWithSignature("confirmTake(address,uint256,bool)", lcc, amount, false));
    }
}
