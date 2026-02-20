// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * Nitro / Stylus E2E Infra Deploy (Mocks)
 *
 * Purpose:
 * - Provide the minimal on-chain surfaces required by the Stylus intent policy’s staticcalls:
 *   - StateView.getSlot0(bytes32)
 *   - VTSOrchestrator.{positionToCheckpoint,getPositionSettledAmounts,getCommitmentMaxima,getPosition,getPool}
 *   - LiquidityHub.{reserveOfUnderlying,settleQueue}
 * - Provide placeholder targets for the e2e harness’s CallPolicy allowlist:
 *   - MMPositionManager (mock)
 *   - PositionManager (mock getters only)
 * - Deploy a CREATE3Factory (NOT at the canonical 0x9fBB... address) for Nitro devnets.
 *
 * Output:
 * - Writes a JSON file at `DEPLOYMENTS_PATH` containing:
 *   - CREATE3_FACTORY
 *   - STATE_VIEW_ADDRESS
 *   - VTS_ORCHESTRATOR_ADDRESS
 *   - LIQUIDITY_HUB_ADDRESS
 *   - MM_POSITION_MANAGER_ADDRESS
 *   - POSITION_MANAGER_ADDRESS
 *
 * Env:
 * - PRIVATE_KEY        (bytes32)
 * - DEPLOYMENTS_PATH   (string)   e.g. "../stylus/deployments.infra.nitro.json"
 */

import "forge-std/Script.sol";

import {CREATE3Factory} from "./base/CREATE3Factory.sol";

contract MockPositionManager {
    address public immutable WETH9;
    address public immutable permit2;

    constructor(address weth9_, address permit2_) {
        WETH9 = weth9_;
        permit2 = permit2_;
    }
}

contract MockMMPositionManager {
    // Minimal stateful surface so E2E can assert “a write happened”.
    //
    // IMPORTANT CONTEXT (how this relates to Intent Policy):
    // - In production, the state-changing call goes:
    //   EntryPoint.handleOps -> Kernel wallet executes -> MMPositionManager.modifyLiquidities*
    // - The Intent Policy contract is *not* the executor. It is called during validation to decide
    //   whether the UserOp is allowed to execute.
    // - Therefore, on successful execution, `msg.sender` observed by MMPositionManager should be
    //   the Kernel wallet address (not EntryPoint, not the policy).
    uint256 public writes;
    address public lastSender;
    bytes32 public lastCallHash;

    /// @dev Mimics the production entrypoint name used by CallPolicy allowlists.
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable {
        // We don't implement PoolManager unlock flows in infra mocks.
        // For E2E, it's sufficient to have a state change that is gated by the Intent Policy.
        writes++;
        lastSender = msg.sender;
        lastCallHash = keccak256(abi.encodePacked("modifyLiquidities", unlockData, deadline, msg.sender, msg.value));
    }

    /// @dev Mimics the production entrypoint name used by CallPolicy allowlists.
    function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params) external payable {
        writes++;
        lastSender = msg.sender;
        // `abi.encodePacked` does not support `bytes[]` in packed mode.
        // This is just an E2E mock signal, so `abi.encode` is sufficient.
        lastCallHash = keccak256(abi.encode("modifyLiquiditiesWithoutUnlock", actions, params, msg.sender, msg.value));
    }
}

contract MockStateView {
    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        uint24 protocolFee;
        uint24 lpFee;
    }

    mapping(bytes32 => Slot0) internal slot0Of;

    function setSlot0(bytes32 poolId, Slot0 calldata s) external {
        slot0Of[poolId] = s;
    }

    function getSlot0(bytes32 poolId) external view returns (uint160, int24, uint24, uint24) {
        Slot0 memory s = slot0Of[poolId];
        // Provide sensible defaults if unset.
        if (s.sqrtPriceX96 == 0) {
            s.sqrtPriceX96 = uint160(79228162514264337593543950336); // 1:1 sqrtPriceX96
        }
        return (s.sqrtPriceX96, s.tick, s.protocolFee, s.lpFee);
    }
}

contract MockLiquidityHub {
    mapping(address => uint256) public reserveOfUnderlying;
    mapping(address => mapping(address => uint256)) public settleQueue;

    function setReserve(address underlying, uint256 amount) external {
        reserveOfUnderlying[underlying] = amount;
    }

    function setQueueAmount(address lcc, address owner, uint256 amount) external {
        settleQueue[lcc][owner] = amount;
    }
}

contract MockVTSOrchestrator {
    struct Checkpoint {
        uint256 timeOfLastTransition;
        bool isOpen;
        uint256 gracePeriodExtension0;
        uint256 gracePeriodExtension1;
    }

    struct Position {
        address owner;
        bytes32 poolId;
    }

    struct PoolConfig {
        uint256 grace0;
        uint256 grace1;
        bool isPaused;
    }

    mapping(bytes32 => Checkpoint) internal checkpointOf;
    mapping(bytes32 => Position) internal positionOf;
    mapping(bytes32 => PoolConfig) internal poolOf;
    mapping(bytes32 => uint256) internal settled0Of;
    mapping(bytes32 => uint256) internal settled1Of;
    mapping(bytes32 => uint256) internal commitMax0Of;
    mapping(bytes32 => uint256) internal commitMax1Of;

    // --- setters (for tests / local setup) ---
    function setCheckpoint(bytes32 positionId, Checkpoint calldata c) external {
        checkpointOf[positionId] = c;
    }

    function setPosition(bytes32 positionId, address owner, bytes32 poolId) external {
        positionOf[positionId] = Position({owner: owner, poolId: poolId});
    }

    function setPool(bytes32 poolId, uint256 grace0, uint256 grace1, bool isPaused) external {
        poolOf[poolId] = PoolConfig({grace0: grace0, grace1: grace1, isPaused: isPaused});
    }

    function setSettledAmounts(bytes32 positionId, uint256 a0, uint256 a1) external {
        settled0Of[positionId] = a0;
        settled1Of[positionId] = a1;
    }

    function setCommitmentMaxima(bytes32 positionId, uint256 c0, uint256 c1) external {
        commitMax0Of[positionId] = c0;
        commitMax1Of[positionId] = c1;
    }

    // --- policy-required getters (must match selectors exactly) ---
    function positionToCheckpoint(bytes32 positionId) external view returns (uint256, bool, uint256, uint256) {
        Checkpoint memory c = checkpointOf[positionId];
        // Default: closed (isOpen=false) so grace period checks treat as "infinite".
        return (c.timeOfLastTransition, c.isOpen, c.gracePeriodExtension0, c.gracePeriodExtension1);
    }

    function getPositionSettledAmounts(bytes32 positionId) external view returns (uint256 amount0, uint256 amount1) {
        return (settled0Of[positionId], settled1Of[positionId]);
    }

    function getCommitmentMaxima(bytes32 positionId) external view returns (uint256 commitment0, uint256 commitment1) {
        return (commitMax0Of[positionId], commitMax1Of[positionId]);
    }

    function getPosition(bytes32 positionId) external view returns (address owner, bytes32 poolId) {
        Position memory p = positionOf[positionId];
        return (p.owner, p.poolId);
    }

    function getPool(bytes32 poolId)
        external
        view
        returns (
            bytes32 id,
            address currency0,
            address currency1,
            uint256 token0GracePeriodTime,
            uint256 token0SeizureUnlockTime,
            uint256 token0BaseVTSRate,
            uint256 token0MaxGracePeriodTime,
            uint256 token1GracePeriodTime,
            uint256 token1SeizureUnlockTime,
            uint256 token1BaseVTSRate,
            uint256 token1MaxGracePeriodTime,
            uint256 coverageFeeShare,
            uint256 minResidualUnits,
            bool isPaused
        )
    {
        PoolConfig memory c = poolOf[poolId];
        // Default grace periods (seconds)
        uint256 g0 = c.grace0 == 0 ? 3600 : c.grace0;
        uint256 g1 = c.grace1 == 0 ? 3600 : c.grace1;
        return (poolId, address(0), address(0), g0, 0, 0, g0, g1, 0, 0, g1, 0, 0, c.isPaused);
    }
}

contract DeployStylusE2EInfra is Script {
    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        string memory deploymentsPath = vm.envString("DEPLOYMENTS_PATH");

        vm.startBroadcast(pk);

        // Deploy CREATE3 factory (Nitro devnet-friendly: not pinned to canonical address).
        CREATE3Factory create3Factory = new CREATE3Factory();

        // Deploy minimal mocks.
        MockStateView stateView = new MockStateView();
        MockVTSOrchestrator vts = new MockVTSOrchestrator();
        MockLiquidityHub hub = new MockLiquidityHub();
        MockMMPositionManager mmpm = new MockMMPositionManager();

        // PositionManager mock: only needs getters (WETH9 + permit2).
        // Use dummy non-zero addresses for return values.
        MockPositionManager pm = new MockPositionManager(
            address(0x1111111111111111111111111111111111111111), address(0x2222222222222222222222222222222222222222)
        );

        vm.stopBroadcast();

        // Write deployment outputs.
        string memory ns = "addrs";
        vm.serializeAddress(ns, "CREATE3_FACTORY", address(create3Factory));
        vm.serializeAddress(ns, "STATE_VIEW_ADDRESS", address(stateView));
        vm.serializeAddress(ns, "VTS_ORCHESTRATOR_ADDRESS", address(vts));
        vm.serializeAddress(ns, "LIQUIDITY_HUB_ADDRESS", address(hub));
        vm.serializeAddress(ns, "MM_POSITION_MANAGER_ADDRESS", address(mmpm));
        string memory json = vm.serializeAddress(ns, "POSITION_MANAGER_ADDRESS", address(pm));
        vm.writeJson(json, deploymentsPath);
    }
}

