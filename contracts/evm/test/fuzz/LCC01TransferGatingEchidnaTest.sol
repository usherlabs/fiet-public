// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LiquidityHub} from "../../src/LiquidityHub.sol";
import {LiquidityCommitmentCertificate} from "../../src/LCC.sol";
import {MockOracleHelper} from "./mocks/MockOracleHelper.sol";
import {MockERC20Metadata} from "./mocks/MockERC20Metadata.sol";
import {Bounds} from "../../src/libraries/Bounds.sol";
import {LCCFactoryLinkedLib} from "../../src/libraries/LCCFactoryLib.sol";

/// @notice Echidna harness for LCC-01 transfer gating:
///         non-protocol ↔ non-protocol transfers must revert unless one endpoint is protocol-bound.
contract LCC01TransferGatingEchidnaTest {
    // Must match `foundry.toml` profile `echidna` hard-link for `LCCFactoryLinkedLib`.
    address internal constant LCC_FACTORY_LINKED_LIB = 0xE2B5401952dC4c9059b7eDE3a1742bF2BC17EBAd;

    LiquidityHub internal hub;
    LiquidityCommitmentCertificate internal lccNative;

    LCC01TransferGating_User internal userA;
    LCC01TransferGating_User internal userB;

    bool internal checkedUserToUser;
    bool internal lastUserToUserOk;

    bool internal checkedUserToProtocol;
    bool internal lastUserToProtocolOk;

    function _primeChecks() internal {
        // Prime both invariants once so the run cannot pass vacuously due to never
        // exercising the relevant call surfaces.
        //
        // - user->user should be blocked (expect revert => ok=false)
        // - user->protocol-bound should be allowed (expect success => ok=true)
        bool okUserToUser = userA.tryTransfer(address(lccNative), address(userB), 1);
        checkedUserToUser = true;
        lastUserToUserOk = okUserToUser;

        bool okUserToProtocol = userA.tryTransfer(address(lccNative), address(hub), 1);
        checkedUserToProtocol = true;
        lastUserToProtocolOk = okUserToProtocol;
    }

    function _deployLinkedLib() internal {
        bytes32 salt = keccak256("echidna.LCCFactoryLinkedLib");
        bytes memory libInitCode = type(LCCFactoryLinkedLib).creationCode;
        address lib;
        assembly {
            lib := create2(0, add(libInitCode, 0x20), mload(libInitCode), salt)
        }
        require(lib != address(0), "LCCFactoryLinkedLib deploy failed");
        require(lib == LCC_FACTORY_LINKED_LIB, "LCCFactoryLinkedLib addr mismatch");
    }

    constructor() {
        _deployLinkedLib();

        // Deploy Hub with harness as owner so we can register this harness as a factory and issuer.
        MockOracleHelper oracleHelper = new MockOracleHelper(address(0));
        hub = new LiquidityHub(address(oracleHelper), "Ether", "ETH", 18, address(this));

        hub.setFactory(address(this), true);
        // Mark the Hub as protocol-bound (endpoint/exempt), so transfers with `to == hub` are allowed.
        hub.setBoundLevel(address(hub), Bounds.BOUND_EXEMPT);

        // Register this harness as issuer to mint LCC into helper users.
        address[] memory issuers = new address[](1);
        issuers[0] = address(this);

        // Create + initialize a market so the LCC is valid.
        MockERC20Metadata other = new MockERC20Metadata();
        bytes memory marketRef = abi.encodePacked(address(this));
        (address l0, address l1) = hub.createLCCPair(marketRef, address(0), address(other), "TEST", issuers);
        hub.initialize(l0, l1, bytes32(uint256(1)), marketRef);

        address underlying0 = hub.getUnderlying(l0);
        lccNative = LiquidityCommitmentCertificate(underlying0 == address(0) ? l0 : l1);

        userA = new LCC01TransferGating_User();
        userB = new LCC01TransferGating_User();

        // Seed some balance so actions can run immediately.
        hub.issue(address(lccNative), address(userA), 1000);

        _primeChecks();
    }

    // -------------------------------------------------------------------------
    // Actions
    // -------------------------------------------------------------------------

    /// @notice Mint market-derived LCC into userA so it can attempt transfers.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_seed_userA(uint256 amount) external {
        uint256 amt = amount % 1e24;
        if (amt == 0) return;
        hub.issue(address(lccNative), address(userA), amt);
    }

    /// @notice Attempt a non-protocol -> non-protocol transfer (must revert).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_try_user_to_user_transfer(uint256 amount) external {
        uint256 bal = lccNative.balanceOf(address(userA));
        if (bal == 0) return;
        uint256 amt = (amount % bal) + 1;

        bool ok = userA.tryTransfer(address(lccNative), address(userB), amt);
        checkedUserToUser = true;
        lastUserToUserOk = ok;
    }

    /// @notice Attempt a non-protocol -> protocol-bound transfer (must succeed if balance is sufficient).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_try_user_to_protocol_transfer(uint256 amount) external {
        uint256 bal = lccNative.balanceOf(address(userA));
        if (bal == 0) return;
        uint256 amt = (amount % bal) + 1;

        bool ok = userA.tryTransfer(address(lccNative), address(hub), amt);
        checkedUserToProtocol = true;
        lastUserToProtocolOk = ok;
    }

    // -------------------------------------------------------------------------
    // Properties
    // -------------------------------------------------------------------------

    /// @dev LCC-01: non-protocol ↔ non-protocol transfers must be blocked.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_lcc01_user_to_user_blocked() external view returns (bool) {
        return !checkedUserToUser || !lastUserToUserOk;
    }

    /// @dev LCC-01: transfers are allowed when at least one endpoint is protocol-bound.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_lcc01_user_to_protocol_allowed() external view returns (bool) {
        return !checkedUserToProtocol || lastUserToProtocolOk;
    }
}

/// @dev Separate contract so we can make calls with a non-protocol `msg.sender`.
contract LCC01TransferGating_User {
    /// @notice Attempt an ERC20 transfer as this contract.
    /// @return ok True if the call succeeds.
    function tryTransfer(address lcc, address to, uint256 amount) external returns (bool ok) {
        (ok,) = lcc.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
    }
}

