// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {VTSLifecycleLinkedLibHarness} from "./harnesses/VTSLifecycleLinkedLibHarness.sol";
import {VTSLifecycleContext, VTSCoreHookContext, VTSCommitRouterContext} from "../../src/types/VTS.sol";
import {ILiquidityHub} from "../../src/interfaces/ILiquidityHub.sol";
import {IMarketFactory} from "../../src/interfaces/IMarketFactory.sol";
import {IVRLSignalManager} from "../../src/interfaces/IVRLSignalManager.sol";
import {IVRLSettlementObserver} from "../../src/interfaces/IVRLSettlementObserver.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {IOracleHelper} from "../../src/interfaces/IOracleHelper.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionId, PositionModificationHookDataLib, PositionLibrary} from "../../src/types/Position.sol";
import {LiquiditySignal} from "../../src/types/Commit.sol";
import {MarketMaker} from "../../src/libraries/MarketMaker.sol";
import {Errors} from "../../src/libraries/Errors.sol";

/// @notice Minimal hub: only `isFactory` / `getFactory` are exercised by VTSLifecycleLinkedLib tests
contract LifecycleTestHub {
    mapping(address => bool) internal _factoryRegistered;
    mapping(bytes32 => address) internal _pairFactory;

    function setFactoryRegistered(address f, bool yes) external {
        _factoryRegistered[f] = yes;
    }

    function setPairFactory(address c0, address c1, address f) external {
        (address a, address b) = c0 < c1 ? (c0, c1) : (c1, c0);
        _pairFactory[keccak256(abi.encode(a, b))] = f;
    }

    function isFactory(address f) external view returns (bool) {
        return _factoryRegistered[f];
    }

    function getFactory(address c0, address c1) external view returns (IMarketFactory) {
        (address a, address b) = c0 < c1 ? (c0, c1) : (c1, c0);
        return IMarketFactory(_pairFactory[keccak256(abi.encode(a, b))]);
    }

    fallback() external {
        revert("LifecycleTestHub: unimplemented");
    }
}

/// @notice Minimal factory: `bounds` + `corePoolToProxyHook` for MarketHandlerLib / lifecycle paths
contract LifecycleTestFactory {
    mapping(address => bool) internal _bound;
    address internal _proxyHook;

    function setBound(address a, bool yes) external {
        _bound[a] = yes;
    }

    function setProxyHook(address h) external {
        _proxyHook = h;
    }

    function bounds(address a) external view returns (bool) {
        return _bound[a];
    }

    function corePoolToProxyHook(PoolId) external view returns (address) {
        return _proxyHook;
    }

    fallback() external {
        revert("LifecycleTestFactory: unimplemented");
    }
}

contract LifecycleTestSignalManager is IVRLSignalManager {
    uint256 internal _expirySeconds = 3600;
    address public lastSender;
    uint256 public lastCommitId;
    uint256 public lastDeadline;
    uint256 public lastAuthNonce;
    bytes public lastAuthSig;

    function setExpirySeconds(uint256 s) external {
        _expirySeconds = s;
    }

    function getVerifier() external pure returns (address) {
        return address(0);
    }

    function signalExpiryInSeconds() external view returns (uint256) {
        return _expirySeconds;
    }

    function mmNonce(address) external pure returns (uint256) {
        return 0;
    }

    function submitAuthNonce(address) external pure returns (uint256) {
        return 0;
    }

    function submitter() external pure returns (address) {
        return address(0xBEEF);
    }

    function setVerifier(address) external pure {
        revert("not implemented");
    }

    function setSignalExpiryInSeconds(uint256) external pure {
        revert("not implemented");
    }

    function verifyLiquiditySignal(address sender, bytes memory, bool) external returns (bool, uint256) {
        lastSender = sender;
        lastCommitId = 0;
        lastDeadline = 0;
        lastAuthNonce = 0;
        delete lastAuthSig;
        return (true, _expirySeconds);
    }

    function verifyLiquiditySignalRelayed(
        address sender,
        uint256 commitId,
        bytes memory,
        uint256 deadline,
        uint256 authNonce,
        bytes memory authSig,
        bool
    ) external returns (bool, uint256) {
        lastSender = sender;
        lastCommitId = commitId;
        lastDeadline = deadline;
        lastAuthNonce = authNonce;
        lastAuthSig = authSig;
        return (true, _expirySeconds);
    }
}

contract LifecycleTestSettlementObserver is IVRLSettlementObserver {
    PositionId public expectedPositionId;
    PositionId public lastPositionId;

    function setExpectedPositionId(PositionId positionId) external {
        expectedPositionId = positionId;
    }

    function submitter() external pure returns (address) {
        return address(0);
    }

    function addVerifier(address) external pure returns (uint32) {
        return 0;
    }

    function nullifyVerifier(uint32) external pure {}

    function allowVerifierForTokens(uint32, address[] memory) external pure {}

    function disallowVerifierForTokens(uint32, address[] memory) external pure {}

    function verifySettlementProof(
        PoolKey memory,
        uint8,
        uint32,
        PositionId positionId,
        bytes memory,
        bool revertOnInvalid
    ) external returns (bool) {
        lastPositionId = positionId;
        if (
            PositionId.unwrap(expectedPositionId) != bytes32(0)
                && PositionId.unwrap(positionId) != PositionId.unwrap(expectedPositionId)
        ) {
            if (revertOnInvalid) revert("LifecycleTestSettlementObserver: unexpected position");
            return false;
        }
        return true;
    }
}

contract LifecycleTestPoolManagerStub {
    function extsload(bytes32) external pure returns (bytes32 value) {
        return bytes32(0);
    }

    function extsload(bytes32, uint256 nSlots) external pure returns (bytes32[] memory values) {
        values = new bytes32[](nSlots);
    }

    function extsload(bytes32[] calldata slots) external pure returns (bytes32[] memory values) {
        values = new bytes32[](slots.length);
    }
}

contract VTSLifecycleLinkedLibTest is Test {
    using PoolIdLibrary for PoolKey;

    VTSLifecycleLinkedLibHarness internal harness;
    LifecycleTestHub internal hub;
    LifecycleTestFactory internal factory;
    LifecycleTestFactory internal factoryOther;
    LifecycleTestSignalManager internal signalManager;
    LifecycleTestSettlementObserver internal settlementObserver;

    address internal constant VAULT = address(uint160(uint256(keccak256("lifecycle.vault"))));
    address internal mmOwner = makeAddr("mmOwner");
    address internal advancer = makeAddr("advancer");
    address internal boundCaller = makeAddr("boundCaller");
    address internal unboundCaller = makeAddr("unboundCaller");

    Currency internal c0 = Currency.wrap(address(0xC0));
    Currency internal c1 = Currency.wrap(address(0xC1));

    PoolKey internal poolKey;
    LifecycleTestPoolManagerStub internal poolManagerStub;

    function setUp() public {
        harness = new VTSLifecycleLinkedLibHarness();
        hub = new LifecycleTestHub();
        factory = new LifecycleTestFactory();
        factoryOther = new LifecycleTestFactory();
        signalManager = new LifecycleTestSignalManager();
        settlementObserver = new LifecycleTestSettlementObserver();
        poolManagerStub = new LifecycleTestPoolManagerStub();

        hub.setFactoryRegistered(address(factory), true);
        hub.setPairFactory(Currency.unwrap(c0), Currency.unwrap(c1), address(factory));

        factory.setProxyHook(VAULT);

        poolKey = PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))});
    }

    function _encodedSignal() internal view returns (bytes memory) {
        MarketMaker.Reserve[] memory reserves = new MarketMaker.Reserve[](1);
        reserves[0] = MarketMaker.Reserve({asset: "USD", amount: 1e18});
        LiquiditySignal memory sig = LiquiditySignal({
            nonce: 1,
            rootHash: bytes32(0),
            rootHashSignature: "",
            merkleProof: new bytes32[](0),
            mmState: MarketMaker.State({
                owner: mmOwner, reserves: reserves, sourceState: "", prover: "", nonce: "", advancer: advancer
            }),
            mmSignature: ""
        });
        return abi.encode(sig);
    }

    function _renewSignalBytes(uint256 nonce) internal view returns (bytes memory) {
        MarketMaker.Reserve[] memory reserves = new MarketMaker.Reserve[](1);
        reserves[0] = MarketMaker.Reserve({asset: "USD", amount: 1e18});
        LiquiditySignal memory sig = LiquiditySignal({
            nonce: nonce,
            rootHash: bytes32(0),
            rootHashSignature: "",
            merkleProof: new bytes32[](0),
            mmState: MarketMaker.State({
                owner: mmOwner, reserves: reserves, sourceState: "", prover: "", nonce: "", advancer: advancer
            }),
            mmSignature: ""
        });
        return abi.encode(sig);
    }

    function _routerCtx() internal view returns (VTSCommitRouterContext memory) {
        return VTSCommitRouterContext({liquidityHub: ILiquidityHub(address(hub)), signalManager: signalManager});
    }

    function _coreCtx() internal pure returns (VTSCoreHookContext memory) {
        return VTSCoreHookContext({
            poolManager: IPoolManager(address(0)),
            liquidityHub: ILiquidityHub(address(0)),
            oracleHelper: IOracleHelper(address(0))
        });
    }

    function _lifecycleCtx() internal view returns (VTSLifecycleContext memory) {
        return VTSLifecycleContext({
            poolManager: IPoolManager(address(poolManagerStub)),
            liquidityHub: ILiquidityHub(address(hub)),
            oracleHelper: IOracleHelper(address(0)),
            settlementObserver: settlementObserver
        });
    }

    // --- commitSignal / sender resolution ---

    function test_commitSignal_revertsWhenFactoryNotRegistered() public {
        vm.expectRevert(Errors.InvalidSender.selector);
        harness.commitSignal(_routerCtx(), IMarketFactory(address(0xBAD)), boundCaller, mmOwner, _encodedSignal());
    }

    function test_commitSignal_revertsWhenUnboundCallerForwardsDifferentSender() public {
        vm.expectRevert(Errors.InvalidSender.selector);
        harness.commitSignal(_routerCtx(), IMarketFactory(address(factory)), unboundCaller, mmOwner, _encodedSignal());
    }

    function test_commitSignal_succeedsWhenUnboundCallerActsAsSelf() public {
        uint256 id = harness.commitSignal(
            _routerCtx(), IMarketFactory(address(factory)), unboundCaller, unboundCaller, _encodedSignal()
        );
        assertEq(id, 1);
        assertEq(signalManager.lastSender(), unboundCaller);
    }

    function test_commitSignal_usesForwardedSenderWhenCallerIsBound() public {
        factory.setBound(boundCaller, true);
        harness.commitSignal(_routerCtx(), IMarketFactory(address(factory)), boundCaller, mmOwner, _encodedSignal());
        assertEq(harness.getCommitMMOwner(1), mmOwner);
        assertEq(signalManager.lastSender(), mmOwner);
    }

    function test_commitSignalRelayed_revertsWhenUnboundCallerForwardsDifferentSender() public {
        vm.expectRevert(Errors.InvalidSender.selector);
        harness.commitSignalRelayed(
            _routerCtx(), IMarketFactory(address(factory)), unboundCaller, mmOwner, _encodedSignal(), 0, 0, bytes("")
        );
    }

    function test_commitSignalRelayed_succeedsWhenBoundCallerForwardsMMOwner() public {
        uint256 deadline = block.timestamp + 1 hours;
        uint256 authNonce = 17;
        bytes memory authSig = hex"CAFE";
        factory.setBound(boundCaller, true);
        uint256 id = harness.commitSignalRelayed(
            _routerCtx(),
            IMarketFactory(address(factory)),
            boundCaller,
            mmOwner,
            _encodedSignal(),
            deadline,
            authNonce,
            authSig
        );
        assertEq(id, 1);
        assertEq(harness.getCommitMMOwner(1), mmOwner);
        assertEq(signalManager.lastSender(), mmOwner);
        assertEq(signalManager.lastCommitId(), 0);
        assertEq(signalManager.lastDeadline(), deadline);
        assertEq(signalManager.lastAuthNonce(), authNonce);
        assertEq(signalManager.lastAuthSig(), authSig);
    }

    function test_renewSignal_revertsWhenUnboundCallerForwardsDifferentSender() public {
        factory.setBound(boundCaller, true);
        harness.commitSignal(_routerCtx(), IMarketFactory(address(factory)), boundCaller, mmOwner, _encodedSignal());

        vm.expectRevert(Errors.InvalidSender.selector);
        harness.renewSignal(
            _routerCtx(), IMarketFactory(address(factory)), unboundCaller, mmOwner, 1, _renewSignalBytes(2)
        );
    }

    function test_renewSignal_succeedsWhenBoundCallerForwardsAdvancer() public {
        factory.setBound(boundCaller, true);
        harness.commitSignal(_routerCtx(), IMarketFactory(address(factory)), boundCaller, mmOwner, _encodedSignal());

        uint256 expBefore = harness.getCommitExpiresAt(1);
        vm.warp(block.timestamp + 100);
        // Bound caller may relay `sender`; renew internal auth requires sender == mmState.advancer
        harness.renewSignal(
            _routerCtx(), IMarketFactory(address(factory)), boundCaller, advancer, 1, _renewSignalBytes(2)
        );
        assertGt(harness.getCommitExpiresAt(1), expBefore);
        assertEq(signalManager.lastSender(), advancer);
    }

    function test_renewSignalRelayed_revertsWhenUnboundCallerForwardsDifferentSender() public {
        factory.setBound(boundCaller, true);
        harness.commitSignal(_routerCtx(), IMarketFactory(address(factory)), boundCaller, mmOwner, _encodedSignal());

        vm.expectRevert(Errors.InvalidSender.selector);
        harness.renewSignalRelayed(
            _routerCtx(),
            IMarketFactory(address(factory)),
            unboundCaller,
            mmOwner,
            1,
            _renewSignalBytes(2),
            0,
            0,
            bytes("")
        );
    }

    function test_renewSignalRelayed_succeedsWhenBoundCallerForwardsAdvancer() public {
        uint256 deadline = block.timestamp + 1 hours;
        uint256 authNonce = 29;
        bytes memory authSig = hex"BEEF";
        factory.setBound(boundCaller, true);
        harness.commitSignalRelayed(
            _routerCtx(), IMarketFactory(address(factory)), boundCaller, mmOwner, _encodedSignal(), 0, 0, bytes("")
        );

        uint256 expBefore = harness.getCommitExpiresAt(1);
        vm.warp(block.timestamp + 100);
        harness.renewSignalRelayed(
            _routerCtx(),
            IMarketFactory(address(factory)),
            boundCaller,
            advancer,
            1,
            _renewSignalBytes(2),
            deadline,
            authNonce,
            authSig
        );
        assertGt(harness.getCommitExpiresAt(1), expBefore);
        assertEq(signalManager.lastSender(), advancer);
        assertEq(signalManager.lastCommitId(), 1);
        assertEq(signalManager.lastDeadline(), deadline);
        assertEq(signalManager.lastAuthNonce(), authNonce);
        assertEq(signalManager.lastAuthSig(), authSig);
    }

    function test_extendGracePeriod_forwardsPositionIdToSettlementObserver() public {
        PoolId pid = poolKey.toId();
        PositionId positionId = PositionId.wrap(keccak256("lifecycle-position"));

        harness.testSeedPool(pid, c0, c1);
        harness.testSeedPosition(positionId, mmOwner, pid, 0, true);
        harness.testSetCheckpoint(positionId, 1, block.timestamp - 1, 0, 0, 0);
        harness.testSetCommitmentMax(positionId, 1e18, 0);
        harness.testSetCommitmentDeficit(positionId, 1e18, 0);
        settlementObserver.setExpectedPositionId(positionId);

        harness.extendGracePeriod(_lifecycleCtx(), poolKey, positionId, 0, 7, hex"ABCD");

        assertEq(PositionId.unwrap(settlementObserver.lastPositionId()), PositionId.unwrap(positionId));
    }

    // --- validateMMOperation ---

    function test_validateMMOperation_returnsFalseWhenHookDataEmpty() public view {
        bytes memory hook = "";
        assertFalse(harness.validateMMOperation(_coreCtx(), boundCaller, poolKey, hook));
    }

    function test_validateMMOperation_returnsFalseWhenCommitIdZero() public view {
        bytes memory hook = PositionModificationHookDataLib.encode(0, 0, address(0x1));
        assertFalse(harness.validateMMOperation(_coreCtx(), boundCaller, poolKey, hook));
    }

    function test_validateMMOperation_revertsWhenSignalInvalid() public {
        harness.testSeedCommit(5, mmOwner, advancer, block.timestamp + 1 days);
        vm.warp(block.timestamp + 2 days);

        bytes memory hook = PositionModificationHookDataLib.encode(5, 0, advancer);
        vm.mockCall(
            address(hub),
            abi.encodeWithSelector(ILiquidityHub.getFactory.selector, Currency.unwrap(c0), Currency.unwrap(c1)),
            abi.encode(address(factory))
        );
        factory.setBound(boundCaller, true);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignal.selector, uint256(5)));
        harness.validateMMOperation(_coreCtx(), boundCaller, poolKey, hook);
    }

    function test_validateMMOperation_revertsWhenOwnerNotBound() public {
        uint256 expires = block.timestamp + 7 days;
        harness.testSeedCommit(3, mmOwner, advancer, expires);

        bytes memory hook = PositionModificationHookDataLib.encode(3, 0, advancer);
        vm.mockCall(
            address(hub),
            abi.encodeWithSelector(ILiquidityHub.getFactory.selector, Currency.unwrap(c0), Currency.unwrap(c1)),
            abi.encode(address(factory))
        );

        vm.expectRevert(Errors.InvalidSender.selector);
        harness.validateMMOperation(
            VTSCoreHookContext({
                poolManager: IPoolManager(address(0)),
                liquidityHub: ILiquidityHub(address(hub)),
                oracleHelper: IOracleHelper(address(0))
            }),
            makeAddr("unboundOwner"),
            poolKey,
            hook
        );
    }

    function test_validateMMOperation_revertsWhenLockerNotAdvancer() public {
        uint256 expires = block.timestamp + 7 days;
        harness.testSeedCommit(4, mmOwner, advancer, expires);

        bytes memory hook = PositionModificationHookDataLib.encode(4, 0, makeAddr("badLocker"));
        vm.mockCall(
            address(hub),
            abi.encodeWithSelector(ILiquidityHub.getFactory.selector, Currency.unwrap(c0), Currency.unwrap(c1)),
            abi.encode(address(factory))
        );
        factory.setBound(boundCaller, true);

        vm.expectRevert(Errors.InvalidSender.selector);
        harness.validateMMOperation(
            VTSCoreHookContext({
                poolManager: IPoolManager(address(0)),
                liquidityHub: ILiquidityHub(address(hub)),
                oracleHelper: IOracleHelper(address(0))
            }),
            boundCaller,
            poolKey,
            hook
        );
    }

    function test_validateMMOperation_returnsTrueForSeizureWithoutLockerAdvancerMatch() public {
        uint256 expires = block.timestamp + 7 days;
        harness.testSeedCommit(6, mmOwner, advancer, expires);

        bytes memory hook = PositionModificationHookDataLib.encodeSeizure(6, 0, makeAddr("badLocker"), 0, 0);
        vm.mockCall(
            address(hub),
            abi.encodeWithSelector(ILiquidityHub.getFactory.selector, Currency.unwrap(c0), Currency.unwrap(c1)),
            abi.encode(address(factory))
        );
        factory.setBound(boundCaller, true);

        assertTrue(
            harness.validateMMOperation(
                VTSCoreHookContext({
                    poolManager: IPoolManager(address(0)),
                    liquidityHub: ILiquidityHub(address(hub)),
                    oracleHelper: IOracleHelper(address(0))
                }),
                boundCaller,
                poolKey,
                hook
            )
        );
    }

    function test_validateMMOperation_returnsTrueOnHappyPath() public {
        uint256 expires = block.timestamp + 7 days;
        harness.testSeedCommit(7, mmOwner, advancer, expires);

        bytes memory hook = PositionModificationHookDataLib.encode(7, 0, advancer);
        vm.mockCall(
            address(hub),
            abi.encodeWithSelector(ILiquidityHub.getFactory.selector, Currency.unwrap(c0), Currency.unwrap(c1)),
            abi.encode(address(factory))
        );
        factory.setBound(boundCaller, true);

        assertTrue(
            harness.validateMMOperation(
                VTSCoreHookContext({
                    poolManager: IPoolManager(address(0)),
                    liquidityHub: ILiquidityHub(address(hub)),
                    oracleHelper: IOracleHelper(address(0))
                }),
                boundCaller,
                poolKey,
                hook
            )
        );
    }

    // --- onMMSettle canonical factory ---

    function test_onMMSettle_revertsWhenFactoryNotCanonicalForPoolCurrencies() public {
        PoolId pid = poolKey.toId();
        harness.testSeedPool(pid, c0, c1);
        hub.setPairFactory(Currency.unwrap(c0), Currency.unwrap(c1), address(factoryOther));

        PositionId posId = PositionId.wrap(keccak256("position"));
        vm.expectRevert(Errors.InvalidSender.selector);
        harness.onMMSettle(
            VTSLifecycleContext({
                poolManager: IPoolManager(address(0)),
                liquidityHub: ILiquidityHub(address(hub)),
                oracleHelper: IOracleHelper(address(0)),
                settlementObserver: settlementObserver
            }),
            IMarketFactory(address(factory)),
            posId,
            pid,
            toBalanceDelta(0, 0),
            false,
            false
        );
    }

    // --- processPosition: existing position wrong pool ---

    function test_processPosition_revertsWhenExistingPositionPoolMismatch() public {
        address owner = address(0x0A11CE);
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1, salt: bytes32("salt")});
        PositionId expectedId = PositionLibrary.generateId(owner, params);

        PoolKey memory otherKey = PoolKey({
            currency0: Currency.wrap(address(0xA1)),
            currency1: Currency.wrap(address(0xA2)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PoolId posPool = PoolId.wrap(bytes32(uint256(999)));

        harness.testSeedPosition(expectedId, owner, posPool, 0, true);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPosition.selector, 0, 0, expectedId));
        harness.processPosition(
            _coreCtx(), owner, otherKey, params, toBalanceDelta(0, 0), toBalanceDelta(0, 0), bytes("")
        );
    }
}
