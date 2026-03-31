// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LiquidityHub} from "../../../src/LiquidityHub.sol";
import {LiquidityCommitmentCertificate} from "../../../src/LCC.sol";
import {MockOracleHelper} from "../mocks/MockOracleHelper.sol";
import {MockERC20Transferable} from "../mocks/MockERC20Transferable.sol";
import {Bounds} from "../../../src/libraries/Bounds.sol";
import {EchidnaLinkedLibs} from "../base/EchidnaLinkedLibs.sol";

/// @notice Echidna harness for HUB-01: Wrapping mints 1:1 and increases Hub reserves.
/// @dev "wrap/wrapTo must transfer `amount` underlying into the hub, increment
///      directSupply[lcc] and reserveOfUnderlying[underlying] by `amount`,
///      and mint `amount` LCC to the recipient."
///
/// Properties tested:
///   1. directSupply increases by exactly the wrapped amount (always-on, native + ERC20)
///   2. reserveOfUnderlying increases by exactly the wrapped amount (always-on, native + ERC20)
///   3. LCC totalSupply increases by exactly the wrapped amount (always-on, native + ERC20)
///   4. Per-wrap: recipient balanceOf increases by exactly the amount (action/result, native + ERC20)
///   5. Native wrap rejects msg.value != amount (action/result guard)
///   6. ERC20 wrap rejects nonzero msg.value (action/result guard)
contract HUB01 {
    uint256 internal constant MAX_AMOUNT = 1e24;

    LiquidityHub internal hub;

    LiquidityCommitmentCertificate internal lccNative;
    LiquidityCommitmentCertificate internal lccErc20;
    MockERC20Transferable internal erc20Underlying;

    bytes32 internal constant NATIVE_MARKET_ID = bytes32(uint256(1));
    bytes32 internal constant ERC20_MARKET_ID = bytes32(uint256(2));

    // Harness-side models tracking cumulative wraps.
    uint256 internal modelDirectSupplyNative;
    uint256 internal modelDirectSupplyErc20;
    uint256 internal modelReserveNative;
    uint256 internal modelReserveErc20;
    uint256 internal modelTotalSupplyNative;
    uint256 internal modelTotalSupplyErc20;

    // Action/result: native wrap 1:1.
    bool internal checkedNativeWrap;
    bool internal lastNativeWrapOk;

    // Action/result: ERC20 wrap 1:1.
    bool internal checkedErc20Wrap;
    bool internal lastErc20WrapOk;

    // Action/result: guard — native wrap must reject mismatched msg.value.
    bool internal checkedNativeGuard;
    bool internal lastNativeGuardOk;

    // Action/result: guard — ERC20 wrap must reject nonzero msg.value.
    bool internal checkedErc20Guard;
    bool internal lastErc20GuardOk;

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

        // Native-underlying LCC pair.
        erc20Underlying = new MockERC20Transferable();
        bytes memory nativeRef = abi.encodePacked(address(this), bytes1(0x01));
        (address n0, address n1) = hub.createLCCPair(nativeRef, address(0), address(erc20Underlying), "NAT", issuers);
        hub.initialize(n0, n1, bytes32(uint256(1)), nativeRef);
        lccNative = LiquidityCommitmentCertificate(hub.getUnderlying(n0) == address(0) ? n0 : n1);

        // ERC20-underlying LCC pair.
        MockERC20Transferable erc20Other = new MockERC20Transferable();
        bytes memory erc20Ref = abi.encodePacked(address(this), bytes1(0x02));
        (address e0, address e1) =
            hub.createLCCPair(erc20Ref, address(erc20Underlying), address(erc20Other), "ERC", issuers);
        hub.initialize(e0, e1, bytes32(uint256(2)), erc20Ref);
        lccErc20 = LiquidityCommitmentCertificate(hub.getUnderlying(e0) == address(erc20Underlying) ? e0 : e1);

        // Approve hub to pull ERC20 underlying.
        erc20Underlying.approve(address(hub), type(uint256).max);

        // Seed properties that don't require ETH (deployer has no balance).
        _seedErc20Wrap();
        _seedNativeGuard();
    }

    /// @dev Seed the ERC20 wrap check: wrap 1 unit and verify 1:1 accounting.
    function _seedErc20Wrap() internal {
        uint256 amt = 1;
        erc20Underlying.mint(address(this), amt);
        uint256 supplyBefore = lccErc20.totalSupply();
        uint256 balBefore = lccErc20.balanceOf(address(this));

        hub.wrap(address(lccErc20), amt);

        modelDirectSupplyErc20 += amt;
        modelReserveErc20 += amt;
        modelTotalSupplyErc20 += amt;

        checkedErc20Wrap = true;
        lastErc20WrapOk =
            (lccErc20.totalSupply() == supplyBefore + amt) && (lccErc20.balanceOf(address(this)) == balBefore + amt);
    }

    /// @dev Seed the native guard: wrap(lccNative, 1) with value=0 must revert.
    function _seedNativeGuard() internal {
        (bool ok,) = address(hub)
        .call{value: 0}(abi.encodeWithSignature("wrap(address,uint256)", address(lccNative), uint256(1)));
        checkedNativeGuard = true;
        lastNativeGuardOk = !ok;
    }

    // ================================================================
    // Actions — wrapping
    // ================================================================

    /// @dev Wrap native ETH into lccNative via wrap().
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_01_wrap_native(uint256 amount) external payable {
        uint256 amt = (amount % MAX_AMOUNT) + 1;
        if (address(this).balance < amt) return;

        uint256 supplyBefore = lccNative.totalSupply();
        uint256 balBefore = lccNative.balanceOf(address(this));

        hub.wrap{value: amt}(address(lccNative), amt);

        modelDirectSupplyNative += amt;
        modelReserveNative += amt;
        modelTotalSupplyNative += amt;

        checkedNativeWrap = true;
        lastNativeWrapOk =
            (lccNative.totalSupply() == supplyBefore + amt) && (lccNative.balanceOf(address(this)) == balBefore + amt);
    }

    /// @dev Wrap native ETH to a separate recipient via wrapTo().
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_01_wrapTo_native(uint256 amount) external payable {
        uint256 amt = (amount % MAX_AMOUNT) + 1;
        if (address(this).balance < amt) return;

        address recipient = address(0xBEEF);
        uint256 supplyBefore = lccNative.totalSupply();
        uint256 recipientBalBefore = lccNative.balanceOf(recipient);

        hub.wrapTo{value: amt}(address(lccNative), recipient, amt);

        modelDirectSupplyNative += amt;
        modelReserveNative += amt;
        modelTotalSupplyNative += amt;

        checkedNativeWrap = true;
        lastNativeWrapOk = (lccNative.totalSupply() == supplyBefore + amt)
            && (lccNative.balanceOf(recipient) == recipientBalBefore + amt);
    }

    /// @dev Wrap ERC20 underlying into lccErc20 via wrap().
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_01_wrap_erc20(uint256 amount) external {
        uint256 amt = (amount % MAX_AMOUNT) + 1;
        erc20Underlying.mint(address(this), amt);

        uint256 supplyBefore = lccErc20.totalSupply();
        uint256 balBefore = lccErc20.balanceOf(address(this));

        hub.wrap(address(lccErc20), amt);

        modelDirectSupplyErc20 += amt;
        modelReserveErc20 += amt;
        modelTotalSupplyErc20 += amt;

        checkedErc20Wrap = true;
        lastErc20WrapOk =
            (lccErc20.totalSupply() == supplyBefore + amt) && (lccErc20.balanceOf(address(this)) == balBefore + amt);
    }

    /// @dev Wrap ERC20 underlying to a separate recipient via wrapTo().
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_01_wrapTo_erc20(uint256 amount) external {
        uint256 amt = (amount % MAX_AMOUNT) + 1;
        erc20Underlying.mint(address(this), amt);

        address recipient = address(0xBEEF);
        uint256 supplyBefore = lccErc20.totalSupply();
        uint256 recipientBalBefore = lccErc20.balanceOf(recipient);

        hub.wrapTo(address(lccErc20), recipient, amt);

        modelDirectSupplyErc20 += amt;
        modelReserveErc20 += amt;
        modelTotalSupplyErc20 += amt;

        checkedErc20Wrap = true;
        lastErc20WrapOk = (lccErc20.totalSupply() == supplyBefore + amt)
            && (lccErc20.balanceOf(recipient) == recipientBalBefore + amt);
    }

    /// @dev Wrap ERC20 via marketId routing overload: wrap(underlying, marketId, amount).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_01_wrap_erc20_by_marketId(uint256 amount) external {
        uint256 amt = (amount % MAX_AMOUNT) + 1;
        erc20Underlying.mint(address(this), amt);

        uint256 supplyBefore = lccErc20.totalSupply();
        uint256 balBefore = lccErc20.balanceOf(address(this));

        hub.wrap(address(erc20Underlying), ERC20_MARKET_ID, amt);

        modelDirectSupplyErc20 += amt;
        modelReserveErc20 += amt;
        modelTotalSupplyErc20 += amt;

        checkedErc20Wrap = true;
        lastErc20WrapOk =
            (lccErc20.totalSupply() == supplyBefore + amt) && (lccErc20.balanceOf(address(this)) == balBefore + amt);
    }

    // ================================================================
    // Actions — guards
    // ================================================================

    /// @dev Native wrap guard: msg.value != amount must revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_01_native_guard_mismatch(uint256 amount, uint256 valueDelta) external payable {
        uint256 amt = (amount % MAX_AMOUNT) + 1;
        uint256 delta = (valueDelta % MAX_AMOUNT) + 1;
        uint256 wrongValue = amt + delta;
        if (address(this).balance < wrongValue) return;

        (bool ok,) = address(hub)
        .call{value: wrongValue}(abi.encodeWithSignature("wrap(address,uint256)", address(lccNative), amt));
        checkedNativeGuard = true;
        lastNativeGuardOk = !ok;
    }

    /// @dev ERC20 wrap guard: nonzero msg.value must revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_hub_01_erc20_guard_nonzero_value(uint256 amount) external payable {
        uint256 amt = (amount % MAX_AMOUNT) + 1;
        if (address(this).balance < 1) return;
        erc20Underlying.mint(address(this), amt);

        (bool ok,) =
            address(hub).call{value: 1}(abi.encodeWithSignature("wrap(address,uint256)", address(lccErc20), amt));
        checkedErc20Guard = true;
        lastErc20GuardOk = !ok;
    }

    // ================================================================
    // Properties — always-on (model consistency)
    // ================================================================

    /// @dev directSupply[lccNative] must equal our cumulative wrap model.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_01_direct_supply_native_matches_model() external view returns (bool) {
        return hub.directSupply(address(lccNative)) == modelDirectSupplyNative;
    }

    /// @dev directSupply[lccErc20] must equal our cumulative wrap model.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_01_direct_supply_erc20_matches_model() external view returns (bool) {
        return hub.directSupply(address(lccErc20)) == modelDirectSupplyErc20;
    }

    /// @dev reserveOfUnderlying for native LCC must equal our cumulative wrap model.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_01_reserve_native_matches_model() external view returns (bool) {
        return hub.reserveOfUnderlying(address(lccNative)) == modelReserveNative;
    }

    /// @dev reserveOfUnderlying for ERC20 LCC must equal our cumulative wrap model.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_01_reserve_erc20_matches_model() external view returns (bool) {
        return hub.reserveOfUnderlying(address(lccErc20)) == modelReserveErc20;
    }

    /// @dev totalSupply of native LCC must equal our cumulative wrap model.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_01_total_supply_native_matches_model() external view returns (bool) {
        return lccNative.totalSupply() == modelTotalSupplyNative;
    }

    /// @dev totalSupply of ERC20 LCC must equal our cumulative wrap model.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_01_total_supply_erc20_matches_model() external view returns (bool) {
        return lccErc20.totalSupply() == modelTotalSupplyErc20;
    }

    /// @dev Hub's actual ETH balance must be at least the modeled native reserve.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_01_hub_eth_balance_covers_native_reserve() external view returns (bool) {
        return address(hub).balance >= modelReserveNative;
    }

    /// @dev Hub's actual ERC20 balance must be at least the modeled ERC20 reserve.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_01_hub_erc20_balance_covers_erc20_reserve() external view returns (bool) {
        return erc20Underlying.balanceOf(address(hub)) >= modelReserveErc20;
    }

    // ================================================================
    // Properties — action/result (per-wrap 1:1)
    // ================================================================

    /// @dev Each native wrap must increase supply and recipient balance by exactly the amount.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_01_native_wrap_is_one_to_one() external view returns (bool) {
        return !checkedNativeWrap || lastNativeWrapOk;
    }

    /// @dev Each ERC20 wrap must increase supply and recipient balance by exactly the amount.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_01_erc20_wrap_is_one_to_one() external view returns (bool) {
        return !checkedErc20Wrap || lastErc20WrapOk;
    }

    // ================================================================
    // Properties — action/result (guards)
    // ================================================================

    /// @dev Native wrap with msg.value != amount must always revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_01_native_guard_rejects_mismatch() external view returns (bool) {
        return !checkedNativeGuard || lastNativeGuardOk;
    }

    /// @dev ERC20 wrap with nonzero msg.value must always revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_hub_01_erc20_guard_rejects_value() external view returns (bool) {
        return !checkedErc20Guard || lastErc20GuardOk;
    }

    receive() external payable {}
}
