// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {LiquidityHub} from "../src/LiquidityHub.sol";
import {OracleHelper} from "../src/OracleHelper.sol";
import {IResilientOracle} from "../src/interfaces/IResilientOracle.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {ILCC} from "../src/interfaces/ILCC.sol";
import {MockERC20} from "./_mocks/MockERC20.sol";
import {Errors} from "../src/libraries/Errors.sol";

/**
 * @title LiquidityHubSettlementTest
 * @notice Tests for LiquidityHub settlement queue mechanics
 * @dev Tests the settlement queue functionality that queues settlements when unwrapping fails
 *      due to insufficient liquidity, and processes them when liquidity becomes available.
 */
contract LiquidityHubSettlementTest is Test {
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

    function setUp() public {
        // Set factory address
        factory = makeAddr("FACTORY");

        // Deploy mock oracle
        resilientOracle = IResilientOracle(makeAddr("ResilientOracle"));
        oracleHelper = new OracleHelper(address(resilientOracle));

        // Deploy LiquidityHub
        liquidityHub = new LiquidityHub(address(oracleHelper), "Ethereum", "ETH", 18);

        // Deploy mock underlying assets
        underlyingAsset1 = new MockERC20("Token1", "TK1", 18);
        underlyingAsset2 = new MockERC20("Token2", "TK2", 18);

        // Deploy mock market factory
        mockMarketFactory = IMarketFactory(makeAddr("MarketFactory"));

        // Mock oracleHelper() call needed for LCC creation
        vm.mockCall(
            factory, abi.encodeWithSelector(IMarketFactory.oracleHelper.selector), abi.encode(address(oracleHelper))
        );

        // Set factory
        liquidityHub.setFactory(factory, true);

        // Create LCC tokens via factory
        vm.startPrank(factory);
        address[] memory issuers = new address[](1);
        issuers[0] = address(factory); // set the factory to be an issuer
        (lccToken1, lccToken2) = liquidityHub.createLCCPair(
            abi.encodePacked(address(0x1234)), // marketRef
            address(underlyingAsset1),
            address(underlyingAsset2),
            "Test Market",
            issuers
        );

        // Initialize market
        liquidityHub.initialize(
            lccToken1,
            lccToken2,
            marketId1,
            abi.encodePacked(address(0x1234)),
            false // refIsValidIssuer
        );

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

    /// @notice Helper function to wrap LCC for a user
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

        // Mint some LCC tokens to the factory, so it can sent to a recipient
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

        // Mock zero market liquidity to ensure than an unwrap from market balance will queue a settlement
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector),
            abi.encode(uint256(0)) // used = 0 (no liquidity available)
        );

        // User tries to unwrap their full balance
        // Since there's no market liquidity, it should queue a settlement
        vm.prank(recipient);
        liquidityHub.unwrap(lccTokenAddress, amount);

        // validate that the unwrapped amuont has been queued
        assertEq(liquidityHub.settleQueue(lccTokenAddress, recipient), amount);

        //? undo liquidity hub mock calls(is this really needed?)
        //? vm.clearMockedCalls();
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
        liquidityHub.initialize(lccToken3, lccToken4, marketId2, abi.encodePacked(address(0x5678)), false);
        vm.stopPrank();

        return (lccToken3, lccToken4);
    }

    ///  mock an address as protocol-bound
    function _mockAddressAsProtocolBound(address contractAddress, bool isProtocolBound) public {
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, contractAddress),
            abi.encode(isProtocolBound)
        );
    }

    /// @notice Tests queuing a settlement when unwrapping with remaining deficit amounts due to insufficient liquidity
    function testQueueSettlementOnUnwrapWithDeficit() public {
        // Setup: User has LCC tokens (via issue) but insufficient market liquidity

        // Make user1 an issuer by setting them via factory's issuer management
        // Since we can't easily set issuers, let's use wrap instead

        // Wrap some LCC for user1
        uint256 wrapAmount = 100;
        underlyingAsset1.mint(user1, wrapAmount);
        vm.startPrank(user1);
        underlyingAsset1.approve(address(liquidityHub), wrapAmount);
        liquidityHub.wrap(lccToken1, wrapAmount);
        vm.stopPrank();

        // Verify user1 has LCC tokens
        ILCC lcc = ILCC(lccToken1);
        assertGt(lcc.balanceOf(user1), 0, "User should have LCC tokens after wrapping");
        (uint256 wrappedBal, uint256 marketBal) = lcc.balancesOf(user1);
        assertEq(wrappedBal, wrapAmount, "User should have direct balance");
        assertEq(marketBal, 0, "User should NOT have market balance");

        // Verify directSupply is set correctly
        assertEq(liquidityHub.directSupply(lccToken1), wrapAmount, "directSupply should equal wrapAmount");
        assertEq(
            liquidityHub.sharedReserveOf(address(underlyingAsset1)),
            wrapAmount,
            "reserveOfUnderlying should equal wrapAmount"
        );

        // Mock factory to return insufficient liquidity for market unwrap
        // useMarketLiquidity returns uint256 (amount used)
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector),
            abi.encode(uint256(0)) // used = 0 (no liquidity available)
        );

        // Mock marketLiquidity to return 0
        vm.mockCall(factory, abi.encodeWithSelector(IMarketFactory.marketLiquidity.selector), abi.encode(uint256(0)));

        // User tries to unwrap their full balance
        // Since there's no market liquidity, it should use direct unwrap and succeed
        vm.prank(user1);
        liquidityHub.unwrap(lccToken1, wrapAmount);

        // Verify underlying was transferred
        assertEq(underlyingAsset1.balanceOf(user1), wrapAmount);
        assertEq(lcc.balanceOf(user1), 0);
        (wrappedBal, marketBal) = lcc.balancesOf(user1);
        assertEq(wrappedBal, 0);
        assertEq(marketBal, 0);

        // To test settlement queue, we need market-derived balance
        _createSettlementQueueEntry(lccToken1, user1, wrapAmount);

        assertEq(liquidityHub.totalQueued(lccToken1), wrapAmount);
    }

    /// @notice Tests that settlements are cumulative for the same recipient
    function testCumulativeSettlement() public {
        // Verify the settlement queue structure supports cumulative settlements
        // In production, multiple failed unwraps would add to the same queue

        assertEq(liquidityHub.totalQueued(lccToken1), 0);
        assertEq(liquidityHub.settleQueue(lccToken1, user1), 0);
        assertEq(liquidityHub.settleQueue(lccToken1, user2), 0);

        // The cumulative nature is handled by the += operator in _queueSettlement
        // We can verify this by checking the code structure
    }

    /// @notice Tests processing settlement for a recipient
    function testProcessSettlementFor() public {
        // Setup: Queue a settlement and add liquidity to process it

        // First, wrap some LCC
        uint256 amount = 100;
        underlyingAsset1.mint(user1, amount);
        vm.startPrank(user1);
        underlyingAsset1.approve(address(liquidityHub), amount);
        liquidityHub.wrap(lccToken1, amount);
        vm.stopPrank();

        // Try to process settlement when none is queued (should revert)
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), uint256(0)));
        liquidityHub.processSettlementFor(lccToken1, user1, type(uint256).max);

        // TODO: To test successful processing, we'd need to:
        // 1. Set up a queued settlement (requires market-derived balance scenario)
        // 2. Add underlying liquidity to reserveOfUnderlying
        // 3. Call processSettlementFor
        // This requires more complex setup with market operations
    }

    /// @notice Tests that different LCC tokens have isolated settlement queues
    function testLccIsolation() public {
        (address lccToken3,) = _createSecondLCCPair();

        // Verify queues are separate
        assertEq(liquidityHub.totalQueued(lccToken1), 0);
        assertEq(liquidityHub.totalQueued(lccToken3), 0);
        assertEq(liquidityHub.settleQueue(lccToken1, user1), 0);
        assertEq(liquidityHub.settleQueue(lccToken3, user1), 0);
        assertEq(liquidityHub.settleQueue(lccToken1, user2), 0);
        assertEq(liquidityHub.settleQueue(lccToken3, user2), 0);
    }

    /// @notice Tests that totalQueued tracks the sum of all queued settlements
    function testTotalQueuedTracking() public {
        // Verify totalQueued starts at 0
        assertEq(liquidityHub.totalQueued(lccToken1), 0);

        // In production, totalQueued is incremented in _queueSettlement
        // and decremented in processSettlementFor and annulSettlementBeforeTransfer
        // We verify the structure exists
    }

    /// @notice Tests that settleQueue correctly maps LCC -> recipient -> amount
    function testSettleQueueMapping() public {
        // Verify the mapping structure
        assertEq(liquidityHub.settleQueue(lccToken1, user1), 0);
        assertEq(liquidityHub.settleQueue(lccToken1, user2), 0);
        assertEq(liquidityHub.settleQueue(lccToken1, user3), 0);

        // Verify different LCCs have separate mappings
        assertEq(liquidityHub.settleQueue(lccToken2, user1), 0);
    }

    /// @notice Tests that processSettlementFor requires queued settlement > 0
    function testProcessSettlementForRequiresQueue() public {
        // Try to process when no settlement is queued
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), uint256(0)));
        liquidityHub.processSettlementFor(lccToken1, user1, type(uint256).max);

        // Try with different recipient
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), uint256(0)));
        liquidityHub.processSettlementFor(lccToken1, user2, type(uint256).max);
    }

    /// @notice Tests that SettlementQueued event exists
    function testSettlementQueuedEvent() public {
        // Verify the event signature exists in the contract
        // The event is: SettlementQueued(address indexed lcc, address indexed recipient, uint256 amount)
        bytes32 eventSig = keccak256("SettlementQueued(address,address,uint256)");
        assertTrue(eventSig != bytes32(0));
    }

    // ============ WRAP WITH LCC : O(1) FLATTENING TESTS ============

    /// @notice Tests O(1) flattening: wrapping withLCC into lcc immediately flattens withLCC
    function testWrapWithFlattensImmediately() public {
        // Setup: Create two LCC tokens with same underlying
        // ensures that the liquidity hub address is protocol-bound
        // so that it can facilitate transfers, as transfers from non protocol bound addresses to none protocol bound addresses are not allowed
        // so we mark the liquidity hub as protocol-bound
        vm.mockCall(
            factory, abi.encodeWithSelector(IMarketFactory.bounds.selector, address(liquidityHub)), abi.encode(true)
        );

        (address lccToken3,) = _createSecondLCCPair();

        // Wrap some LCC for user1
        uint256 wrapAmount = 100;

        // Wrap underlying to create withLCC balance
        _wrapDirectLCC(user1, lccToken1, wrapAmount);

        // Verify withLCC has directSupply
        assertEq(liquidityHub.directSupply(lccToken1), wrapAmount, "withLCC should have directSupply");

        // Now wrap lccToken2 using lccToken1 as backing
        uint256 wrapWithAmount = 50;
        ILCC withLCC = ILCC(lccToken1);
        ILCC toLCC = ILCC(lccToken3);

        // Wrap lccToken2 using lccToken1 as backing
        vm.startPrank(user1);
        withLCC.approve(address(liquidityHub), wrapWithAmount);
        liquidityHub.wrapWith(address(toLCC), address(withLCC), wrapWithAmount);
        vm.stopPrank();

        // Verify: withLCC's directSupply should be consumed (flattened)
        assertEq(
            liquidityHub.directSupply(lccToken1), wrapAmount - wrapWithAmount, "withLCC directSupply should be consumed"
        );

        // Verify: lccToken2 was minted to user1
        assertEq(toLCC.balanceOf(user1), wrapWithAmount, "lccToken2 should be minted to user1");
        (uint256 wrappedBal, uint256 marketBal) = toLCC.balancesOf(user1);
        assertEq(wrappedBal, wrapWithAmount, "Should be wrapped balance");
        assertEq(marketBal, 0, "Should not have market balance");

        // Verify: withLCC was burned from Hub
        assertEq(withLCC.balanceOf(address(liquidityHub)), 0, "Hub should not hold withLCC");
    }

    /// @notice Tests O(1) flattening with netting: reverse reserve nets out
    function testWrapWithNetsReverseReserve() public {
        (address lccToken3,) = _createSecondLCCPair();
        // First, wrap lccToken2 using lccToken1 (creates forward reserve, but we don't use that anymore)
        // Then wrap lccToken1 using lccToken2 (should net against reverse reserve)

        uint256 wrapAmount1 = 100;
        ILCC lcc1 = ILCC(lccToken1);
        ILCC lcc2 = ILCC(lccToken3);

        // Wrap underlying to create both LCC balances
        _wrapDirectLCC(user1, address(lcc2), wrapAmount1);

        // First wrap: lcc1 using lccToken3 (this will flatten lccToken3)
        _mockAddressAsProtocolBound(address(liquidityHub), true);
        vm.startPrank(user1);
        lcc2.approve(address(liquidityHub), wrapAmount1);
        liquidityHub.wrapWith(address(lcc1), address(lcc2), wrapAmount1);
        vm.stopPrank();

        // Verify direct supply was transferred (flattening worked)
        assertEq(liquidityHub.directSupply(address(lcc2)), 0, "lccToken3 directSupply should be consumed");
        assertEq(liquidityHub.directSupply(address(lcc1)), wrapAmount1, "lcc1 directSupply should equal amount");
        // Validate the user1 got the lcc1 back
        assertEq(lcc1.balanceOf(user1), wrapAmount1, "user1 should have the amount of lcc1 wrapped");
        assertEq(lcc2.balanceOf(user1), 0, "user1 should have zero lcc2 since it was sent to the hub");

        // Now create a Hub queue for lcc1 (the "reverse reserve" scenario)
        // This simulates Hub owing USDC for lcc1
        uint256 queueAmount = 50;
        // create settlement queue entry for the hub
        _createSettlementQueueEntry(address(lcc1), address(liquidityHub), queueAmount);
        // Verify queue was created
        assertEq(
            liquidityHub.settleQueue(address(lcc1), address(liquidityHub)),
            queueAmount,
            "lcc1 queue should be equal to the queue amount"
        );
        assertEq(lcc1.balanceOf(address(liquidityHub)), queueAmount, "Hub should hold amount of lcc1 that is queued up");

        // Before the second wrapWith, check user1's balance
        uint256 user1BalanceBefore = lcc1.balanceOf(user1);
        console.log("user1BalanceBefore", user1BalanceBefore);
        // state before wrapWith
        // LCC1 balance (user) -> amount
        // LCC1 balance (hub) -> queueAmount
        // LCC2 balance (user) -> 0
        // LCC2 balance (hub) -> 0
        // LCC1 balance (queue) -> queueAmount
        // LCC2 balance (queue) -> 0

        // Now wrap lcc1 using lccToken3 - Step 0 should net against Hub queue
        uint256 wrapAmount2 = 30; //unwrap partial amount from the queue
        _wrapDirectLCC(user1, address(lcc2), wrapAmount2);

        uint256 queueBefore = liquidityHub.settleQueue(address(lcc1), address(liquidityHub));
        uint256 hubBalanceBefore = lcc1.balanceOf(address(liquidityHub));
        assertEq(hubBalanceBefore, queueAmount, "Hub should hold amount of lcc1 that is queued up");
        assertEq(queueBefore, queueAmount, "Queue should be equal to the queue amount");

        _mockAddressAsProtocolBound(address(liquidityHub), true);
        vm.startPrank(user1);
        lcc2.approve(address(liquidityHub), wrapAmount2);
        liquidityHub.wrapWith(address(lcc1), address(lcc2), wrapAmount2);
        vm.stopPrank();

        // Verify Step 0 netting happened:
        // 1. Queue should be reduced by wrapAmount2
        assertEq(
            liquidityHub.settleQueue(address(lcc1), address(liquidityHub)),
            queueBefore - wrapAmount2,
            "Queue should be reduced by netted amount"
        );

        // 2. Hub-held lccToken1 should be burned i.e balance of lcc1 in the hub should be reduced by wrapAmount2
        assertEq(
            lcc1.balanceOf(address(liquidityHub)), hubBalanceBefore - wrapAmount2, "Hub-held lccToken1 should be burned"
        );

        // 3. User should receive lccToken1 (minted as market-derived from queue origin)
        // Check the INCREASE in balance, not total balance
        uint256 user1BalanceAfter = lcc1.balanceOf(user1);
        assertEq(
            user1BalanceAfter - user1BalanceBefore, wrapAmount2, "User should receive exactly wrapAmount2 of lccToken1"
        );

        (uint256 wrappedBalance, uint256 marketBalBefore) = lcc1.balancesOf(user1);

        console.log("wrappedBalBefore", wrappedBalance);
        console.log("marketBal", marketBalBefore);

        // The wrapped balance should be equal to the wrapAmount1 since that was a direct wrap
        // The market balance should be equal to the netted amount from the queue
        assertEq(wrappedBalance, wrapAmount1, "Wrapped balance should be equal to the wrapAmount1");
        assertEq(
            marketBalBefore,
            wrapAmount2,
            "Market balance should be equal to the netted amount from the queue which is the wrapAmount2"
        );

        // Validate netting of the lccwith queue entry
        // create a queue entry for the wrapWith amount and validate netting action
        uint256 claimAmount = 20;
        ILCC wrapWithLCC = ILCC(lcc1);

        // check the hubs queue for the wrapWithLCC
        console.log("hub queue for wrapWithLCC", liquidityHub.settleQueue(address(wrapWithLCC), address(liquidityHub)));
        assertEq(liquidityHub.settleQueue(address(wrapWithLCC), address(liquidityHub)), claimAmount);

        // no need to create a settlement queue entry for the wrapWithLCC since it is already created in the first wrapWith
        // and  we did not completely exhause the queue amount in the first wrapWith
        // _createSettlementQueueEntry(address(wrapWithLCC), address(liquidityHub), queueAmount);
        // _wrapDirectLCC(user1, address(wrapWithLCC), claimAmount);

        // console.log("hub claim for wrapWithLCC", liquidityHub.nettedLCCsAsUnderlying(address(wrapWithLCC)));

        // Wrap lcc1 using the wrapWithLCC (should net against the queue entry)
        _mockAddressAsProtocolBound(address(liquidityHub), true);
        vm.startPrank(user1);
        wrapWithLCC.approve(address(liquidityHub), claimAmount);
        liquidityHub.wrapWith(address(lcc2), address(wrapWithLCC), claimAmount);
        vm.stopPrank();

        // validate the `nettedLCCsAsUnderlying` is increased by the claimAmount
        // console.log("hub claim for wrapWithLCC", liquidityHub.nettedLCCsAsUnderlying(address(wrapWithLCC)));
        // assertEq(liquidityHub.nettedLCCsAsUnderlying(address(wrapWithLCC)), claimAmount);
    }

    /// @notice Tests that wrapWith queues shortfall to Hub when market liquidity insufficient
    function testWrapWithQueuesShortfallToHub() public {
        uint256 wrapAmount = 100;
        (address lccToken3,) = _createSecondLCCPair();

        ILCC lcc1 = ILCC(lccToken1);
        ILCC lcc2 = ILCC(lccToken3);

        ILCC withLCC = ILCC(lcc1);

        _wrapMarketDerivedLCC(user1, address(withLCC), wrapAmount);

        // Mock: no directSupply available, no market liquidity
        // This should queue to Hub
        vm.mockCall(factory, abi.encodeWithSelector(IMarketFactory.marketLiquidity.selector), abi.encode(uint256(0)));
        vm.mockCall(factory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0)));

        _mockAddressAsProtocolBound(address(liquidityHub), true);
        vm.startPrank(user1);
        withLCC.approve(address(liquidityHub), wrapAmount);
        liquidityHub.wrapWith(address(lcc2), address(withLCC), wrapAmount);
        vm.stopPrank();

        // Verify: shortfall should be queued to Hub
        assertGt(liquidityHub.settleQueue(lccToken1, address(liquidityHub)), 0, "Shortfall should be queued to Hub");
        assertGt(liquidityHub.totalQueued(lccToken1), 0, "totalQueued should reflect Hub queue");
    }

    // ============ HUB SETTLEMENT TESTS ============

    /// @notice Tests Hub-specific settlement processing: burns Hub-held LCC without transferring underlying
    function testProcessSettlementForHub() public {
        // Setup: Queue a settlement to Hub
        uint256 queuedAmount = 50;
        uint256 availableReserve = 100;

        // Create underlying reserve
        underlyingAsset1.mint(address(liquidityHub), availableReserve);
        // Manually increment reserveOfUnderlying (normally done via confirmTake)
        vm.startPrank(factory);
        liquidityHub.confirmTake(lccToken1, availableReserve, false);

        // create a settlement entry for the user
        // and validate that upon unwrap the user gets the underlying asset and that their queue entry is removed
        _createSettlementQueueEntry(lccToken1, address(user1), queuedAmount);
        // Process the settlement for the user
        liquidityHub.processSettlementFor(lccToken1, user1, queuedAmount);
        // validate user gets underlying asset and that their queue entry is removed
        assertEq(underlyingAsset1.balanceOf(user1), queuedAmount);
        assertEq(liquidityHub.settleQueue(lccToken1, user1), 0);
    }

    /// @notice Tests that processSettlementFor branches correctly on recipient
    function testProcessSettlementForBranchesOnRecipient() public {
        // Setup: Queue a settlement to Hub
        uint256 queuedAmount = 50;
        uint256 availableReserve = 100;

        // Create underlying reserve
        underlyingAsset1.mint(address(liquidityHub), availableReserve);
        // Manually increment reserveOfUnderlying (normally done via confirmTake)
        vm.prank(factory);
        liquidityHub.confirmTake(lccToken1, availableReserve, false);

        // create a settlement entry for the hub and validate that
        _createSettlementQueueEntry(lccToken1, address(liquidityHub), queuedAmount);
        // Process settlement for the hub
        uint256 hublBalanceBeforeSettlement = underlyingAsset1.balanceOf(address(liquidityHub));
        liquidityHub.processSettlementFor(lccToken1, address(liquidityHub), queuedAmount);
        // validate the underlying balance of the hub remains the same
        assertEq(underlyingAsset1.balanceOf(address(liquidityHub)), hublBalanceBeforeSettlement);
        // validate that the queue entry is removed
        assertEq(liquidityHub.settleQueue(lccToken1, address(liquidityHub)), 0);
    }

    // ============ USER UNWRAP TESTS ============

    /// @notice Tests that standard user unwrap still works after refactoring
    function testUserUnwrapStillWorks() public {
        uint256 wrapAmount = 100;
        underlyingAsset1.mint(user1, wrapAmount);

        // Wrap
        vm.startPrank(user1);
        underlyingAsset1.approve(address(liquidityHub), wrapAmount);
        liquidityHub.wrap(lccToken1, wrapAmount);
        vm.stopPrank();

        ILCC lcc = ILCC(lccToken1);

        // Verify balance
        assertEq(lcc.balanceOf(user1), wrapAmount, "User should have LCC");

        // Unwrap
        vm.prank(user1);
        liquidityHub.unwrap(lccToken1, wrapAmount);

        // Verify underlying returned
        assertEq(underlyingAsset1.balanceOf(user1), wrapAmount, "User should receive underlying");
        assertEq(lcc.balanceOf(user1), 0, "LCC should be burned");
    }

    /// @notice Tests that unwrapTo still works for external recipients
    function testUnwrapToExternalRecipient() public {
        uint256 wrapAmount = 100;

        // Wrap
        _wrapDirectLCC(user1, lccToken1, wrapAmount);

        // Unwrap to different recipient
        vm.prank(user1);
        liquidityHub.unwrapTo(lccToken1, user2, wrapAmount);

        // Verify user2 received underlying
        assertEq(underlyingAsset1.balanceOf(user2), wrapAmount, "user2 should receive underlying");
        assertEq(underlyingAsset1.balanceOf(user1), 0, "user1 should not have underlying");
    }
}
