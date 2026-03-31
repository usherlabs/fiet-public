// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LiquidityHub} from "../../../src/LiquidityHub.sol";
import {LiquidityCommitmentCertificate} from "../../../src/LCC.sol";
import {MockOracleHelper} from "../mocks/MockOracleHelper.sol";
import {MockERC20Transferable} from "../mocks/MockERC20Transferable.sol";
import {Bounds} from "../../../src/libraries/Bounds.sol";
import {EchidnaLinkedLibs} from "../base/EchidnaLinkedLibs.sol";

/// @notice Echidna harness for HUB-05: confirmTake is balance-backed (reserves cannot be fabricated).
/// @dev "confirmTake must never increase reserveOfUnderlying beyond the Hub's actual underlying balance.
///      This must hold even under nested call flows (callback-style paths)."
///
/// Properties tested:
///   1. reserve <= actual hub balance for ERC20 underlying (always-on)
///   2. reserve <= actual hub balance for native underlying (always-on)
///   3. confirmTake with amount exceeding slack (balance - reserve) must revert (action/result)
///   4. confirmTake reachable via useMarketLiquidity callback still preserves invariant (always-on)
///   5. Valid confirmTake increases reserve by exactly the confirmed amount (action/result)
contract HUB05 {
    uint256 internal constant MAX_AMOUNT = 1e24;
    uint256 internal constant MAX_CALLBACK_VACUOUS_ATTEMPTS = 16;

    LiquidityHub internal hub;

    LiquidityCommitmentCertificate internal lccErc20;
    LiquidityCommitmentCertificate internal lccNative;
    MockERC20Transferable internal erc20Underlying;

    // Fuzz-controlled callback take amount for reentrant path.
    uint256 internal callbackTakeAmount;

    // Harness-side models.
    uint256 internal modelReserveErc20;
    uint256 internal modelReserveNative;

    // Action/result: valid confirmTake increases reserve correctly.
    bool internal checkedValidTake;
    bool internal lastValidTakeOk;

    // Action/result: over-balance confirmTake must revert.
    bool internal checkedOverBalanceTake;
    bool internal lastOverBalanceTakeOk;

    // Tracks that the callback path was exercised at least once.
    bool internal callbackExercised;
    uint256 internal callbackTriggerAttempts;

    // ================================================================
    // Constructor
    // ================================================================

    constructor() {
        EchidnaLinkedLibs.deployLCCFactoryLinkedLib();
        EchidnaLinkedLibs.deployLiquidityHubLinkedLib();

        MockOracleHelper oracleHelper = new MockOracleHelper(address(0));
        hub = new LiquidityHub(address(oracleHelper), "Ether", "ETH", 18, address(this));
        hub.setFactory(address(this), true);
        hub.setBoundLevel(address(hub), Bounds.BOUND_EXEMPT);

        address[] memory issuers = new address[](1);
        issuers[0] = address(this);

        // ERC20-underlying LCC.
        erc20Underlying = new MockERC20Transferable();
        MockERC20Transferable otherErc20 = new MockERC20Transferable();
        bytes memory erc20Ref = abi.encodePacked(address(this), bytes1(0x01));
        (address e0, address e1) =
            hub.createLCCPair(erc20Ref, address(erc20Underlying), address(otherErc20), "ERC", issuers);
        hub.initialize(e0, e1, bytes32(uint256(1)), erc20Ref);
        lccErc20 = LiquidityCommitmentCertificate(hub.getUnderlying(e0) == address(erc20Underlying) ? e0 : e1);

        // Native-underlying LCC.
        MockERC20Transferable otherNative = new MockERC20Transferable();
        bytes memory nativeRef = abi.encodePacked(address(this), bytes1(0x02));
        (address n0, address n1) = hub.createLCCPair(nativeRef, address(0), address(otherNative), "NAT", issuers);
        hub.initialize(n0, n1, bytes32(uint256(2)), nativeRef);
        lccNative = LiquidityCommitmentCertificate(hub.getUnderlying(n0) == address(0) ? n0 : n1);

        // Approve hub for ERC20 wrapping.
        erc20Underlying.approve(address(hub), type(uint256).max);

        _seedAll();
    }

    function _seedAll() internal {
        // Seed ERC20: fund hub with underlying, then confirmTake.
        uint256 fundAmt = 100;
        erc20Underlying.mint(address(hub), fundAmt);

        uint256 reserveBefore = hub.reserveOfUnderlying(address(lccErc20));
        hub.confirmTake(address(lccErc20), fundAmt, false);
        uint256 reserveAfter = hub.reserveOfUnderlying(address(lccErc20));

        checkedValidTake = true;
        lastValidTakeOk = (reserveAfter - reserveBefore == fundAmt);
        modelReserveErc20 = reserveAfter;

        // Seed over-balance guard: try to confirmTake more than the slack.
        (bool ok,) = address(hub)
            .call(abi.encodeWithSignature("confirmTake(address,uint256,bool)", address(lccErc20), uint256(1), false));
        checkedOverBalanceTake = true;
        lastOverBalanceTakeOk = !ok;
    }

    /// @dev Factory callback: exercises confirmTake from within the unwrap call chain.
    ///      This is the reentrant path HUB-05 is specifically designed to protect against.
    function useMarketLiquidity(address, bytes32, uint256) external returns (uint256 used) {
        if (msg.sender != address(hub)) revert();

        if (callbackTakeAmount > 0) {
            callbackExercised = true;
            // Low-level call so reverts don't abort the unwrap flow.
            (bool ok,) = address(hub)
                .call(
                    abi.encodeWithSignature(
                        "confirmTake(address,uint256,bool)", address(lccErc20), callbackTakeAmount, false
                    )
                );
            ok;
        }
        return 0;
    }

    // ================================================================
    // Actions — build state
    // ================================================================

    /// @dev Fund hub with ERC20 underlying (increases actual balance without touching reserves).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_05_fund_erc20(uint256 amount) external {
        uint256 amt = (amount % MAX_AMOUNT) + 1;
        erc20Underlying.mint(address(hub), amt);
    }

    /// @dev Fund hub with native underlying so native confirmTake paths become reachable.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_05_fund_native() external payable {
        if (msg.value == 0) return;
        (bool ok,) = address(hub).call{value: msg.value}("");
        require(ok, "native fund failed");
    }

    /// @dev Wrap ERC20 to build both reserve and actual balance together.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_05_wrap_erc20(uint256 amount) external {
        uint256 amt = (amount % MAX_AMOUNT) + 1;
        erc20Underlying.mint(address(this), amt);
        hub.wrap(address(lccErc20), amt);
        modelReserveErc20 += amt;
    }

    /// @dev Set the callback take amount for the reentrant path.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_05_set_callback_take(uint256 amount) external {
        callbackTakeAmount = amount % MAX_AMOUNT;
    }

    /// @dev Issue market-derived LCC and unwrap to trigger the callback path.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_05_trigger_callback_via_unwrap(uint256 amount) external {
        unchecked {
            callbackTriggerAttempts++;
        }
        uint256 amt = (amount % MAX_AMOUNT) + 1;
        hub.issue(address(lccErc20), address(this), amt);
        // Low-level to handle reverts gracefully.
        (bool ok,) = address(hub)
            .call(
                abi.encodeWithSignature(
                    "unwrapTo(address,address,address,uint256)", address(lccErc20), address(this), address(this), amt
                )
            );
        ok;
        modelReserveErc20 = hub.reserveOfUnderlying(address(lccErc20));
    }

    // ================================================================
    // Actions — confirmTake
    // ================================================================

    /// @dev Valid confirmTake: fund then confirm within slack.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_05_valid_confirmTake(uint256 amount) external {
        uint256 reserve = hub.reserveOfUnderlying(address(lccErc20));
        uint256 bal = erc20Underlying.balanceOf(address(hub));
        uint256 slack = bal > reserve ? bal - reserve : 0;
        if (slack == 0) return;

        uint256 amt = (amount % slack) + 1;
        uint256 reserveBefore = hub.reserveOfUnderlying(address(lccErc20));

        hub.confirmTake(address(lccErc20), amt, false);

        uint256 reserveAfter = hub.reserveOfUnderlying(address(lccErc20));
        modelReserveErc20 += amt;

        checkedValidTake = true;
        lastValidTakeOk = (reserveAfter - reserveBefore == amt);
    }

    /// @dev Valid native confirmTake: send native value, then confirm within the deposited amount.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_05_valid_confirmTake_native() external payable {
        if (msg.value == 0) return;

        uint256 reserveBefore = hub.reserveOfUnderlying(address(lccNative));
        (bool ok,) = address(hub).call{value: msg.value}("");
        require(ok, "native deposit failed");

        hub.confirmTake(address(lccNative), msg.value, false);

        uint256 reserveAfter = hub.reserveOfUnderlying(address(lccNative));
        modelReserveNative += msg.value;
        checkedValidTake = true;
        lastValidTakeOk = (reserveAfter - reserveBefore == msg.value);
    }

    /// @dev Over-balance confirmTake: amount exceeding slack must revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_05_over_balance_confirmTake(uint256 delta) external {
        uint256 reserve = hub.reserveOfUnderlying(address(lccErc20));
        uint256 bal = erc20Underlying.balanceOf(address(hub));
        uint256 slack = bal > reserve ? bal - reserve : 0;
        uint256 excess = (delta % MAX_AMOUNT) + 1;

        (bool ok,) = address(hub)
            .call(
                abi.encodeWithSignature("confirmTake(address,uint256,bool)", address(lccErc20), slack + excess, false)
            );
        checkedOverBalanceTake = true;
        lastOverBalanceTakeOk = !ok;
    }

    // ================================================================
    // Properties — always-on (balance-backed invariant)
    // ================================================================

    /// @dev ERC20 reserve must never exceed actual hub ERC20 balance.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_05_erc20_reserve_never_exceeds_balance() external view returns (bool) {
        uint256 reserve = hub.reserveOfUnderlying(address(lccErc20));
        return reserve <= erc20Underlying.balanceOf(address(hub));
    }

    /// @dev Native reserve must never exceed actual hub ETH balance.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_05_native_reserve_never_exceeds_balance() external view returns (bool) {
        uint256 reserve = hub.reserveOfUnderlying(address(lccNative));
        return reserve <= address(hub).balance;
    }

    // ================================================================
    // Properties — action/result
    // ================================================================

    /// @dev Valid confirmTake must increase reserve by exactly the confirmed amount.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_05_valid_take_increments_correctly() external view returns (bool) {
        return !checkedValidTake || lastValidTakeOk;
    }

    /// @dev confirmTake exceeding slack must always revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_05_over_balance_take_reverts() external view returns (bool) {
        return !checkedOverBalanceTake || lastOverBalanceTakeOk;
    }

    /// @dev The nested callback path must be exercised after enough explicit trigger attempts.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_05_callback_path_exercised() external view returns (bool) {
        return callbackExercised || callbackTriggerAttempts < MAX_CALLBACK_VACUOUS_ATTEMPTS;
    }

    receive() external payable {}
}
