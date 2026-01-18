// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {LiquidityHub} from "../../src/LiquidityHub.sol";
import {OracleHelper} from "../../src/OracleHelper.sol";
import {IResilientOracle} from "../../src/interfaces/IResilientOracle.sol";
import {IMarketFactory} from "../../src/interfaces/IMarketFactory.sol";
import {ILCC} from "../../src/interfaces/ILCC.sol";
import {MockERC20} from "../_mocks/MockERC20.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {Bounds} from "../../src/libraries/Bounds.sol";

/**
 * @title LiquidityHubTestBase
 * @notice Base contract for LiquidityHub unit tests
 * @dev Provides common setup, state variables, and helper functions for all LiquidityHub tests
 */
abstract contract LiquidityHubTestBase is Test {
    LiquidityHub public liquidityHub;
    OracleHelper public oracleHelper;
    IResilientOracle public resilientOracle;
    IMarketFactory public mockMarketFactory;

    MockERC20 public underlyingAsset1;
    MockERC20 public underlyingAsset2;

    address public lccToken1;
    address public lccToken2;

    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public user3 = address(0x3);
    address public factory;
    address public vtsOrchestrator;
    address public proxyHook;

    bytes32 public marketId1 = bytes32("market1");
    bytes32 public marketId2 = bytes32("market2");

    function setUp() public virtual {
        // Set factory address
        factory = makeAddr("FACTORY");
        vtsOrchestrator = makeAddr("VTS_ORCHESTRATOR");
        proxyHook = makeAddr("PROXY_HOOK");

        // Deploy mock oracle
        resilientOracle = IResilientOracle(makeAddr("ResilientOracle"));
        oracleHelper = new OracleHelper(address(resilientOracle), address(this));

        // Deploy LiquidityHub
        liquidityHub = new LiquidityHub(address(oracleHelper), "Ethereum", "ETH", 18, address(this));

        // Deploy mock underlying assets
        underlyingAsset1 = new MockERC20("Token1", "TK1", 18);
        underlyingAsset2 = new MockERC20("Token2", "TK2", 18);

        // Deploy mock market factory
        address mockMarketFactoryAddress = makeAddr("MarketFactory");
        mockMarketFactory = IMarketFactory(mockMarketFactoryAddress);

        // Mock oracleHelper() call needed for LCC creation
        vm.mockCall(
            factory, abi.encodeWithSelector(IMarketFactory.oracleHelper.selector), abi.encode(address(oracleHelper))
        );

        // Set factory
        liquidityHub.setFactory(factory, true);

        // Create LCC tokens via factory
        vm.startPrank(factory);
        address[] memory issuers = new address[](2);
        issuers[0] = vtsOrchestrator;
        issuers[1] = proxyHook;
        (lccToken1, lccToken2) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0x1234)), // marketRef
            address(underlyingAsset1),
            address(underlyingAsset2),
            "Test Market",
            issuers
        );

        // Initialize market
        liquidityHub.initialize(lccToken1, lccToken2, marketId1, abi.encodePacked(address(0x1234)));

        vm.stopPrank();

        // Register protocol-bound endpoints for tests.
        vm.startPrank(factory);
        // Match production-like defaults (see MarketFactory):
        // - hub is protocol-bound + bucket-exempt (bucketless holder)
        // - factory is a bucket-tracked endpoint
        // - proxyHook is protocol-bound + bucket-exempt
        liquidityHub.setBoundLevel(address(liquidityHub), Bounds.BOUND_EXEMPT);
        liquidityHub.setBoundLevel(factory, Bounds.BOUND_ENDPOINT);
        liquidityHub.setBoundLevel(proxyHook, Bounds.BOUND_EXEMPT);
        vm.stopPrank();
    }

    // ============ HELPER FUNCTIONS ============

    /// @notice Helper function to wrap LCC for a user (creates direct/wrapped balance)
    function _wrapDirectLCC(address user, address lccToken, uint256 amount) public {
        MockERC20 underlyingAsset = MockERC20(ILCC(lccToken).underlying());
        // mint the underlying asset to the user
        underlyingAsset.mint(user, amount);
        // approve the liquidity hub to spend(move) the underlying asset
        // hub then spends(moves) underlying assets to itself
        // and then gives LCC tokens to the user
        vm.startPrank(user);
        underlyingAsset.approve(address(liquidityHub), amount);
        liquidityHub.wrap(lccToken, amount);
        vm.stopPrank();
    }

    /// @notice Helper function to wrap market-derived LCC for a user
    function _wrapMarketDerivedLCC(address user, address lccToken, uint256 amount) public {
        // mint lcc to a bucket-exempt protocol address to create market-derived balance on transfer
        _wrapDirectLCC(proxyHook, lccToken, amount);

        // mock the factory and send to user so that the user has a market balance
        vm.prank(proxyHook);
        ILCC(lccToken).transfer(user, amount);

        (uint256 wrappedBal, uint256 marketBal) = ILCC(lccToken).balancesOf(user);

        assertEq(wrappedBal, 0);
        assertEq(marketBal, amount);
    }

    /// @notice Helper function to create a settlement queue entry
    function _createSettlementQueueEntry(address lccTokenAddress, address recipient, uint256 amount) public {
        // This helper is used to manufacture a queued settlement deterministically by:
        // - ensuring the holder has MARKET-DERIVED balance (wrapped=0)
        // - forcing market liquidity usage to return 0 so the entire amount is queued
        //
        // For normal recipients, we can mint market-derived LCC directly via `issue(...)` (does not depend on transfers).
        // For the Hub itself (bucket-exempt in production), `issue(...)` intentionally skips bucket maps, so we instead
        // create a Hub-owned queue via `wrapWith(...)` (which queues to `address(this)`).
        ILCC lcc = ILCC(lccTokenAddress);

        // Pick an issuer that is actually configured for this LCC (tests create ad-hoc LCCs with custom issuers).
        address issuer = vtsOrchestrator;
        if (!liquidityHub.issuers(lccTokenAddress, issuer)) {
            issuer = proxyHook;
        }
        if (!liquidityHub.issuers(lccTokenAddress, issuer)) {
            issuer = factory;
        }

        if (recipient == address(liquidityHub)) {
            // Create a target LCC with the same underlying so wrapWith is valid.
            (address lccToken3, address lccToken4) = _createSecondLCCPair();
            address target = lcc.underlying() == ILCC(lccToken3).underlying() ? lccToken3 : lccToken4;

            // Mint market-derived balance to a user, then wrapWith into the target while forcing market liquidity to 0.
            vm.prank(issuer);
            liquidityHub.issue(lccTokenAddress, user1, amount);

            // Seed some reserve for this LCC before the Hub queue is created (confirmTake is greedy).
            MockERC20(lcc.underlying()).mint(address(liquidityHub), amount);
            vm.prank(issuer);
            liquidityHub.confirmTake(lccTokenAddress, amount, false);

            vm.mockCall(
                factory,
                abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector),
                abi.encode(uint256(0)) // used = 0 (no liquidity available)
            );

            vm.startPrank(user1);
            lcc.approve(address(liquidityHub), amount);
            liquidityHub.wrapWith(target, lccTokenAddress, amount);
            vm.stopPrank();

            assertEq(liquidityHub.settleQueue(lccTokenAddress, address(liquidityHub)), amount);
            return;
        }

        // Mint market-derived LCC directly to the recipient (issuer path) so wrapped=0, market=amount.
        vm.prank(issuer);
        liquidityHub.issue(lccTokenAddress, recipient, amount);

        (uint256 wrappedBal, uint256 marketBal) = lcc.balancesOf(recipient);
        assertEq(lcc.balanceOf(recipient), amount);
        assertEq(wrappedBal, 0);
        assertEq(marketBal, amount);

        // Mock zero market liquidity to ensure that an unwrap from market balance will queue a settlement
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector),
            abi.encode(uint256(0)) // used = 0 (no liquidity available)
        );

        // User tries to unwrap their full balance
        // Since there's no market liquidity, it should queue a settlement
        vm.prank(recipient);
        liquidityHub.unwrap(lccTokenAddress, amount);

        // validate that the unwrapped amount has been queued
        assertEq(liquidityHub.settleQueue(lccTokenAddress, recipient), amount);
    }

    /// @notice Helper function to create a second LCC pair
    function _createSecondLCCPair() public returns (address, address) {
        // Create a second LCC pair
        vm.startPrank(factory);
        address[] memory issuers = new address[](2);
        issuers[0] = vtsOrchestrator;
        issuers[1] = proxyHook;
        (address lccToken3, address lccToken4) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0x5678)),
            address(underlyingAsset1),
            address(underlyingAsset2),
            "Test Market 2",
            issuers
        );

        // Initialize second market
        liquidityHub.initialize(lccToken3, lccToken4, marketId2, abi.encodePacked(address(0x5678)));
        vm.stopPrank();

        return (lccToken3, lccToken4);
    }

    /// @notice Mock an address as protocol-bound
    function _mockAddressAsProtocolBound(address contractAddress, bool isProtocolBound) public {
        uint8 level = isProtocolBound ? Bounds.BOUND_ENDPOINT : Bounds.BOUND_NONE;
        _setBoundLevel(contractAddress, level);
    }

    function _setBoundLevel(address contractAddress, uint8 level) public {
        vm.startPrank(factory);
        liquidityHub.setBoundLevel(contractAddress, level);
        vm.stopPrank();
    }
}

