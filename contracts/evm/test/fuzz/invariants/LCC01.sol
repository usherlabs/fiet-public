// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FuzzLiquidityHub} from "../harnesses/FuzzLiquidityHub.sol";
import {LiquidityCommitmentCertificate} from "../../../src/LCC.sol";
import {MockOracleHelper} from "../mocks/MockOracleHelper.sol";
import {MockERC20Transferable} from "../mocks/MockERC20Transferable.sol";
import {Bounds} from "../../../src/libraries/Bounds.sol";

/// @notice fuzz harness for LCC-01: transfer gating.
/// @dev "A transfer of LCC must be either mint/burn, or have at least one endpoint
///      that is a protocol-bound address."
///
/// Transfer flow matrix tested:
///   1. user → user                      MUST BLOCK
///   2. user → protocol (BOUND_ENDPOINT) MUST ALLOW
///   3. user → hub (BOUND_EXEMPT)        MUST ALLOW
///   4. protocol → user                  MUST ALLOW
///   5. protocol → protocol              MUST ALLOW
///   6. transferFrom with approval       same gating as transfer
contract LCC01 {
    uint256 internal constant MAX_ACTION_AMOUNT = 1e24;
    uint256 internal constant SEED_BALANCE = 1000e18;

    FuzzLiquidityHub internal hub;
    LiquidityCommitmentCertificate internal lcc;

    // Users: neither is protocol-bound.
    LCC01Actor internal userA;
    LCC01Actor internal userB;
    // Endpoint: BOUND_ENDPOINT (bucket-tracked protocol address).
    LCC01Actor internal endpoint;
    LCC01Actor internal endpointB;

    // ----- Action/result caches -----

    // user → user (transfer + transferFrom)
    bool internal checkedUserToUser;
    bool internal lastUserToUserOk;

    // user → protocol-endpoint
    bool internal checkedUserToEndpoint;
    bool internal lastUserToEndpointOk;

    // user → hub (BOUND_EXEMPT)
    bool internal checkedUserToExempt;
    bool internal lastUserToExemptOk;

    // protocol-endpoint → user
    bool internal checkedEndpointToUser;
    bool internal lastEndpointToUserOk;

    // protocol-endpoint → protocol-endpoint
    bool internal checkedEndpointToEndpoint;
    bool internal lastEndpointToEndpointOk;

    // transferFrom: user → user via approved spender
    bool internal checkedApprovedUserToUser;
    bool internal lastApprovedUserToUserOk;

    // transferFrom: user → endpoint via approved spender
    bool internal checkedApprovedUserToEndpoint;
    bool internal lastApprovedUserToEndpointOk;

    // ================================================================
    // Helpers
    // ================================================================

    function _boundAmount(uint256 amount) internal pure returns (uint256) {
        return (amount % MAX_ACTION_AMOUNT) + 1;
    }

    function _clampToBalance(uint256 amount, address holder) internal view returns (uint256 amt, bool valid) {
        uint256 bal = lcc.balanceOf(holder);
        if (bal == 0) return (0, false);
        amt = (amount % bal) + 1;
        valid = true;
    }

    // ================================================================
    // Constructor
    // ================================================================

    constructor() {
        MockOracleHelper oracleHelper = new MockOracleHelper(address(0));
        hub = new FuzzLiquidityHub(address(oracleHelper), "Ether", "ETH", 18, address(0), address(this));
        hub.setFactory(address(this), true);
        hub.setBoundLevel(address(hub), Bounds.BOUND_EXEMPT);

        address[] memory issuers = new address[](1);
        issuers[0] = address(this);

        MockERC20Transferable other = new MockERC20Transferable();
        bytes memory marketRef = abi.encodePacked(address(this));
        (address l0, address l1) = hub.createLCCPair(marketRef, address(0), address(other), "TEST", issuers);
        hub.initialize(l0, l1, bytes32(uint256(1)), marketRef);
        address underlying0 = hub.getUnderlying(l0);
        lcc = LiquidityCommitmentCertificate(underlying0 == address(0) ? l0 : l1);

        userA = new LCC01Actor();
        userB = new LCC01Actor();
        endpoint = new LCC01Actor();
        endpointB = new LCC01Actor();

        // Register endpoints as BOUND_ENDPOINT so protocol -> protocol can exercise endpoint -> endpoint directly.
        hub.setBoundLevel(address(endpoint), Bounds.BOUND_ENDPOINT);
        hub.setBoundLevel(address(endpointB), Bounds.BOUND_ENDPOINT);

        // Seed balances so transfer actions can execute immediately.
        hub.issue(address(lcc), address(userA), SEED_BALANCE);
        hub.issue(address(lcc), address(endpoint), SEED_BALANCE);
        hub.issue(address(lcc), address(endpointB), SEED_BALANCE);

        // Grant approvals for transferFrom paths: userA approves userB as spender.
        userA.approve(address(lcc), address(userB));

        // Seed all checks once so every property is exercised at deploy time.
        _seedAll();
    }

    function _seedAll() internal {
        // user → user: must fail
        checkedUserToUser = true;
        lastUserToUserOk = userA.tryTransfer(address(lcc), address(userB), 1);

        // user → endpoint: must succeed
        checkedUserToEndpoint = true;
        lastUserToEndpointOk = userA.tryTransfer(address(lcc), address(endpoint), 1);

        // user → hub (exempt): must succeed
        checkedUserToExempt = true;
        lastUserToExemptOk = userA.tryTransfer(address(lcc), address(hub), 1);

        // endpoint → user: must succeed
        checkedEndpointToUser = true;
        lastEndpointToUserOk = endpoint.tryTransfer(address(lcc), address(userA), 1);

        // endpoint → endpoint: must succeed
        checkedEndpointToEndpoint = true;
        lastEndpointToEndpointOk = endpoint.tryTransfer(address(lcc), address(endpointB), 1);

        // transferFrom user → user via spender: must fail
        checkedApprovedUserToUser = true;
        lastApprovedUserToUserOk = userB.tryTransferFrom(address(lcc), address(userA), address(userB), 1);

        // transferFrom user → endpoint via spender: must succeed
        checkedApprovedUserToEndpoint = true;
        lastApprovedUserToEndpointOk = userB.tryTransferFrom(address(lcc), address(userA), address(endpoint), 1);
    }

    // ================================================================
    // Actions — seed balance
    // ================================================================

    /// @dev Mint market-derived LCC into userA for transfer actions.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_01_seed_user(uint256 amount) external {
        hub.issue(address(lcc), address(userA), _boundAmount(amount));
    }

    /// @dev Mint market-derived LCC into endpoint for protocol-bound transfer actions.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_01_seed_endpoint(uint256 amount) external {
        hub.issue(address(lcc), address(endpoint), _boundAmount(amount));
    }

    // ================================================================
    // Actions — transfer (user → user, must block)
    // ================================================================

    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_01_transfer_user_to_user(uint256 amount) external {
        (uint256 amt, bool valid) = _clampToBalance(amount, address(userA));
        if (!valid) return;

        checkedUserToUser = true;
        lastUserToUserOk = userA.tryTransfer(address(lcc), address(userB), amt);
    }

    // ================================================================
    // Actions — transfer (user → protocol-endpoint, must allow)
    // ================================================================

    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_01_transfer_user_to_endpoint(uint256 amount) external {
        (uint256 amt, bool valid) = _clampToBalance(amount, address(userA));
        if (!valid) return;

        checkedUserToEndpoint = true;
        lastUserToEndpointOk = userA.tryTransfer(address(lcc), address(endpoint), amt);
    }

    // ================================================================
    // Actions — transfer (user → hub exempt, must allow)
    // ================================================================

    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_01_transfer_user_to_exempt(uint256 amount) external {
        (uint256 amt, bool valid) = _clampToBalance(amount, address(userA));
        if (!valid) return;

        checkedUserToExempt = true;
        lastUserToExemptOk = userA.tryTransfer(address(lcc), address(hub), amt);
    }

    // ================================================================
    // Actions — transfer (protocol-endpoint → user, must allow)
    // ================================================================

    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_01_transfer_endpoint_to_user(uint256 amount) external {
        (uint256 amt, bool valid) = _clampToBalance(amount, address(endpoint));
        if (!valid) return;

        checkedEndpointToUser = true;
        lastEndpointToUserOk = endpoint.tryTransfer(address(lcc), address(userA), amt);
    }

    // ================================================================
    // Actions — transfer (protocol → protocol, must allow)
    // ================================================================

    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_01_transfer_endpoint_to_endpoint(uint256 amount) external {
        (uint256 amt, bool valid) = _clampToBalance(amount, address(endpoint));
        if (!valid) return;

        checkedEndpointToEndpoint = true;
        lastEndpointToEndpointOk = endpoint.tryTransfer(address(lcc), address(endpointB), amt);
    }

    // ================================================================
    // Actions — transferFrom (user → user via approved spender, must block)
    // ================================================================

    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_01_transfer_from_user_to_user(uint256 amount) external {
        (uint256 amt, bool valid) = _clampToBalance(amount, address(userA));
        if (!valid) return;

        checkedApprovedUserToUser = true;
        lastApprovedUserToUserOk = userB.tryTransferFrom(address(lcc), address(userA), address(userB), amt);
    }

    // ================================================================
    // Actions — transferFrom (user → endpoint via approved spender, must allow)
    // ================================================================

    // forge-lint: disable-next-line(mixed-case-function)
    function action_lcc_01_transfer_from_user_to_endpoint(uint256 amount) external {
        (uint256 amt, bool valid) = _clampToBalance(amount, address(userA));
        if (!valid) return;

        checkedApprovedUserToEndpoint = true;
        lastApprovedUserToEndpointOk = userB.tryTransferFrom(address(lcc), address(userA), address(endpoint), amt);
    }

    // ================================================================
    // Properties — MUST BLOCK
    // ================================================================

    /// @dev User-to-user transfer must always revert (TransferNotAllowed).
    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_lcc_01_user_to_user_blocked() external view returns (bool) {
        return !checkedUserToUser || !lastUserToUserOk;
    }

    /// @dev transferFrom user-to-user via approved spender must also revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_lcc_01_approved_user_to_user_blocked() external view returns (bool) {
        return !checkedApprovedUserToUser || !lastApprovedUserToUserOk;
    }

    // ================================================================
    // Properties — MUST ALLOW
    // ================================================================

    /// @dev User → protocol-endpoint transfer must succeed.
    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_lcc_01_user_to_endpoint_allowed() external view returns (bool) {
        return !checkedUserToEndpoint || lastUserToEndpointOk;
    }

    /// @dev User → hub (BOUND_EXEMPT) transfer must succeed.
    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_lcc_01_user_to_exempt_allowed() external view returns (bool) {
        return !checkedUserToExempt || lastUserToExemptOk;
    }

    /// @dev Protocol-endpoint → user transfer must succeed.
    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_lcc_01_endpoint_to_user_allowed() external view returns (bool) {
        return !checkedEndpointToUser || lastEndpointToUserOk;
    }

    /// @dev Protocol → protocol transfer must succeed.
    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_lcc_01_endpoint_to_endpoint_allowed() external view returns (bool) {
        return !checkedEndpointToEndpoint || lastEndpointToEndpointOk;
    }

    /// @dev transferFrom user → endpoint via approved spender must succeed.
    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_lcc_01_approved_user_to_endpoint_allowed() external view returns (bool) {
        return !checkedApprovedUserToEndpoint || lastApprovedUserToEndpointOk;
    }
}

/// @dev Standalone actor contract: calls originate from this address, not the harness.
contract LCC01Actor {
    function tryTransfer(address lcc, address to, uint256 amount) external returns (bool ok) {
        (ok,) = lcc.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
    }

    function tryTransferFrom(address lcc, address from, address to, uint256 amount) external returns (bool ok) {
        (ok,) = lcc.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount));
    }

    function approve(address lcc, address spender) external {
        (bool ok,) = lcc.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
        ok;
    }
}
