// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {LiquidityHub} from "../src/LiquidityHub.sol";
import {OracleHelper} from "../src/OracleHelper.sol";
import {IResilientOracle} from "../src/interfaces/IResilientOracle.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {ILCC} from "../src/interfaces/ILCC.sol";
import {MockERC20} from "./_mocks/MockERC20.sol";
import {Errors} from "../src/libraries/Errors.sol";

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

    bytes32 public marketId1 = bytes32("market1");
    bytes32 public marketId2 = bytes32("market2");

    function setUp() public virtual {
        // Set factory address
        factory = makeAddr("FACTORY");

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
        address[] memory issuers = new address[](1);
        issuers[0] = address(factory); // arbitrary issuer address. in production it's the VTSOrchestrator.
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

        // Mock the bounds method to ensure that the factory and liquidity hub are protocol-bound
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector),
            abi.encode(false) // ensures that by default all addresses are not protocol-bound
        );
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, address(factory)),
            abi.encode(true) // ensures that the factory address is protocol-bound (override the above mock for the factory address)
        );
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
        // mint lcc to the factory
        _wrapDirectLCC(factory, lccToken, amount);

        // mock the factory and send to user so that the user has a market balance
        vm.prank(factory);
        ILCC(lccToken).transfer(user, amount);

        (uint256 wrappedBal, uint256 marketBal) = ILCC(lccToken).balancesOf(user);

        assertEq(wrappedBal, 0);
        assertEq(marketBal, amount);
    }

    /// @notice Helper function to create a settlement queue entry
    function _createSettlementQueueEntry(address lccTokenAddress, address recipient, uint256 amount) public {
        _mockAddressAsProtocolBound(recipient, false);

        // Mint some LCC tokens to the factory, so it can send to a recipient
        // and since the factory is a protocol-bound address, it will be able to send the LCC tokens to the recipient
        // which will then constitute a market balance for the recipient
        _wrapDirectLCC(factory, lccTokenAddress, amount);

        // transfer to a user and then validate that the user has the corresponding market balance
        vm.startPrank(factory);
        ILCC lcc = ILCC(lccTokenAddress);
        lcc.transfer(recipient, amount);
        vm.stopPrank();

        (uint256 wrappedBal, uint256 marketBal) = lcc.balancesOf(recipient);

        // validate lcc balance and market balance of the recipient
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
        (address lccToken3, address lccToken4) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0x5678)),
            address(underlyingAsset1),
            address(underlyingAsset2),
            "Test Market 2",
            new address[](0)
        );

        // Initialize second market
        liquidityHub.initialize(lccToken3, lccToken4, marketId2, abi.encodePacked(address(0x5678)));
        vm.stopPrank();

        return (lccToken3, lccToken4);
    }

    /// @notice Mock an address as protocol-bound
    function _mockAddressAsProtocolBound(address contractAddress, bool isProtocolBound) public {
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, contractAddress),
            abi.encode(isProtocolBound)
        );
    }
}

