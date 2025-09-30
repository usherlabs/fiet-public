// SPDX-License-Identifier: MIT
// This contract is inherited by the core hook contract and it is responsible for tracking state wide variables for the VTS
pragma solidity ^0.8.26;

import {MarketVTSConfiguration} from "../types/VTS.sol";
import {EventRing, DeficitEvent, SettlementEvent, SwapEvent} from "../libraries/EventRing.sol";
import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {IPositionIndex, PositionMeta} from "../interfaces/IPositionIndex.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TimeBucketOutflowTracker, TimeBucketOutflowTrackerLibrary} from "../libraries/TimeBucket.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCastLib} from "v4-periphery/lib/v4-core/lib/solmate/src/utils/SafeCastLib.sol";
import {PositionLibrary, PositionId} from "../types/Position.sol";
import {IVTSManager} from "../interfaces/IVTSManager.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-periphery/lib/v4-core/src/libraries/SqrtPriceMath.sol";
import {VTSMath} from "../libraries/VTSMath.sol";
import {IVTSCalculator} from "../interfaces/IVTSCalculator.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
// import {IMMPositionManager} from "../interfaces/IMMPositionManager.sol";

abstract contract VTSManager is IVTSManager {
    using SafeCastLib for *;
    using TimeBucketOutflowTrackerLibrary for TimeBucketOutflowTracker;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using EventRing for EventRing.RingD;
    using EventRing for EventRing.RingS;
    using EventRing for EventRing.RingSwap;

    // Mapping from core pool ID to VTS configuration
    mapping(PoolId => MarketVTSConfiguration) public corePoolToVTSConfiguration;
    // Mapping from core pool ID to rolling outflow tracker
    mapping(PoolId => TimeBucketOutflowTracker) public marketOutflow;
    // Event rings per market (swaps, deficits, settlements)
    mapping(PoolId => EventRing.RingSwap) internal swapRing;
    mapping(PoolId => EventRing.RingD) internal deficitRing;
    mapping(PoolId => EventRing.RingS) internal settlementRing;
    // Flushed merkle roots (optional off-chain verification)
    mapping(PoolId => uint256) private swapFlushCount;
    mapping(PoolId => mapping(uint256 => bytes32)) private swapFlushedRoots;
    mapping(PoolId => uint256) private deficitFlushCount;
    mapping(PoolId => mapping(uint256 => bytes32)) private deficitFlushedRoots;
    mapping(PoolId => uint256) private settlementFlushCount;
    mapping(PoolId => mapping(uint256 => bytes32)) private settlementFlushedRoots;
    // Mapping to store maximum potential commitment for each position
    mapping(PositionId => uint256[2]) internal commitmentMaxima;
    // Mapping to store the total settlement amount for each position
    mapping(PositionId => uint256[2]) internal totalSettlementAmount;
    // Mapping from position to its core pool id (for reading window outflows)
    mapping(PositionId => PoolId) internal positionPoolId;
    // Deprecated: previous per-position committed-at-add amounts (replaced by commitmentMaxima)
    // mapping(PositionId => uint256[2]) internal commitment;

    error InvalidCaller();
    error InvalidMarketVTSConfiguration(PoolId corePoolId);
    error NotEnoughSettlementBalance(uint256 amount0, uint256 amount1);

    // Event to notify that the VTS configuration has been set/initialized for a core pool
    event VTSConfigurationSet(PoolId indexed corePoolId, MarketVTSConfiguration indexed vtsConfiguration);
    // Event to notify that the assets have been settled on a position
    event AssetsSettled(PositionId indexed positionId, int128 amount0, int128 amount1);
    // Per-entry events for off-chain fallback
    event SwapRecorded(
        PoolId indexed poolId, uint64 ts, uint160 sqrtP_before, uint160 sqrtP_after, uint128 out0, uint128 out1
    );
    event DeficitRecorded(PoolId indexed poolId, uint8 token, uint128 deficit, uint64 ts);
    event SettlementRecorded(
        PoolId indexed poolId, uint8 token, uint128 settled, uint128 marketDeficitBefore, uint64 ts
    );
    // ringType: 0=Swap,1=Deficit,2=Settlement
    event RingFlushed(
        PoolId indexed poolId, uint8 ringType, uint256 segmentId, bytes32 root, uint16 startIndex, uint16 endIndex
    );

    address private immutable marketFactory;
    address private immutable mmPositionManager;
    IPoolManager private immutable poolManager;
    IVTSCalculator private calculator; // optional external calculator (Stylus or pure)
    IPositionIndex internal positionIndex; // external index for position metadata and liquidity history

    modifier onlyMarketFactory() {
        if (msg.sender != marketFactory) revert InvalidCaller();
        _;
    }

    modifier onlyMarketAssets(PoolId corePoolId) {
        address[2] memory currencies = IMarketFactory(marketFactory).corePoolToCurrencyPair(corePoolId);
        if (msg.sender != currencies[0] && msg.sender != currencies[1]) revert InvalidCaller();
        _;
    }

    constructor(address _poolManager, address _marketFactory, address _mmPositionManager, address _calculator) {
        poolManager = IPoolManager(_poolManager);
        marketFactory = _marketFactory;
        mmPositionManager = _mmPositionManager;
        if (_calculator != address(0)) {
            calculator = IVTSCalculator(_calculator);
        }
    }

    /**
     * @notice Sets the VTS configuration for a core pool
     * @param corePoolId The core pool ID
     * @param vtsConfiguration The VTS configuration
     */
    function setMarketVTSConfiguration(PoolId corePoolId, MarketVTSConfiguration memory vtsConfiguration)
        public
        onlyMarketFactory
    {
        corePoolToVTSConfiguration[corePoolId] = vtsConfiguration;
        marketOutflow[corePoolId].initialize(vtsConfiguration.timeWindow);
        uint16 spsz = vtsConfiguration.deficitRingSize == 0 ? 1024 : vtsConfiguration.deficitRingSize; // reuse
        uint16 dsz = vtsConfiguration.deficitRingSize == 0 ? 1024 : vtsConfiguration.deficitRingSize;
        uint16 ssz = vtsConfiguration.settlementRingSize == 0 ? 512 : vtsConfiguration.settlementRingSize;
        swapRing[corePoolId].initSwap(spsz);
        deficitRing[corePoolId].initD(dsz);
        settlementRing[corePoolId].initS(ssz);

        emit VTSConfigurationSet(corePoolId, vtsConfiguration);
    }

    function setPositionIndex(address index) external onlyMarketFactory {
        positionIndex = IPositionIndex(index);
    }

    // --- Event recording (protocol bounds only) ---
    function recordDeficitEvent(PoolId corePoolId, uint8 token, uint128 deficit)
        external
        onlyMarketAssets(corePoolId)
    {
        // flush if full (half ring flush)
        if (EventRing.isFull(deficitRing[corePoolId])) {
            _flushDeficit(corePoolId);
        }
        deficitRing[corePoolId].push(DeficitEvent({ts: uint64(block.timestamp), token: token, deficit: deficit}));
        emit DeficitRecorded(corePoolId, token, deficit, uint64(block.timestamp));
    }

    function recordSettlementEvent(PoolId corePoolId, uint8 token, uint128 settled, uint128 marketDeficitBefore)
        external
        onlyMarketAssets(corePoolId)
    {
        if (EventRing.isFull(settlementRing[corePoolId])) {
            _flushSettlement(corePoolId);
        }
        settlementRing[corePoolId].push(
            SettlementEvent({
                ts: uint64(block.timestamp),
                token: token,
                settled: settled,
                marketDeficitBefore: marketDeficitBefore
            })
        );
        emit SettlementRecorded(corePoolId, token, settled, marketDeficitBefore, uint64(block.timestamp));
    }

    function recordSwapEvent(
        PoolId corePoolId,
        uint64 ts,
        uint160 sqrtP_before,
        uint160 sqrtP_after,
        uint128 out0,
        uint128 out1
    ) internal {
        if (EventRing.isFull(swapRing[corePoolId])) {
            _flushSwap(corePoolId);
        }
        swapRing[corePoolId].push(
            SwapEvent({ts: ts, sqrtP_before: sqrtP_before, sqrtP_after: sqrtP_after, out0: out0, out1: out1})
        );
        emit SwapRecorded(corePoolId, ts, sqrtP_before, sqrtP_after, out0, out1);
    }

    function getPositionSettledAmounts(PositionId positionId) public view returns (uint256 amount0, uint256 amount1) {
        return (totalSettlementAmount[positionId][0], totalSettlementAmount[positionId][1]);
    }

    /**
     * @notice Gets the VTS configuration for a core pool
     * @param corePoolId The core pool ID
     * @return The VTS configuration
     */
    function getMarketVTSConfiguration(PoolId corePoolId) public view returns (MarketVTSConfiguration memory) {
        return corePoolToVTSConfiguration[corePoolId];
    }

    /// @dev Register/update position metadata and liquidity snapshots in the PositionIndex
    function _touchPositionIndex(address router, PoolId corePoolId, ModifyLiquidityParams calldata params) internal {
        if (address(positionIndex) == address(0)) return;
        // Derive position id consistent with Uniswap position keying
        PositionId positionId = PositionLibrary.generateId(router, params);
        // Ensure registration exists (owner set) and current liquidity snapshot is appended
        // Read meta; if not registered, owner will be zero address
        PositionMeta memory positionMeta = positionIndex.getMeta(positionId);
        if (positionMeta.owner == address(0)) {
            positionIndex.register(
                positionId, corePoolId, params.tickLower, params.tickUpper, router, uint64(block.timestamp)
            );
        }
        // Snapshot current on-chain liquidity
        uint128 liq = poolManager.getPositionLiquidity(corePoolId, PositionId.unwrap(positionId));
        positionIndex.updateLiquidity(positionId, liq);
    }

    /**
     * @notice Gets the total outflow for the currencies in a core pool/Market
     * @param corePoolId The core pool ID
     * @return totalOutflow0 Total outflow for currency0
     * @return totalOutflow1 Total outflow for currency1
     */
    function getMarketOutflow(PoolId corePoolId) public view returns (uint256 totalOutflow0, uint256 totalOutflow1) {
        return marketOutflow[corePoolId].getTotalOutflow();
    }

    /**
     * @notice Records the outflow for the currencies in a core pool/Market
     * @param corePoolId The core pool ID
     * @param delta The balance delta
     */
    function _recordOutflow(PoolId corePoolId, BalanceDelta delta) internal {
        // Extract outflow amounts (negative deltas indicate outflow)
        int256 delta0 = delta.amount0();
        int256 delta1 = delta.amount1();

        uint256 outflow0 = delta0 < 0 ? uint256(-delta0) : 0;
        uint256 outflow1 = delta1 < 0 ? uint256(-delta1) : 0;

        // Record both outflows (even if one is 0)
        marketOutflow[corePoolId].recordOutflow(outflow0, outflow1);
    }

    /**
     * @notice Calculates the maximum potential commitment for both tokens over a tick range for a given liquidity
     * @dev Uses CLMM formulas based on tick bounds and liquidity. Results are in raw token units.
     * @param tickLower The lower tick bound of the position
     * @param tickUpper The upper tick bound of the position
     * @param liquidity The position liquidity to evaluate against the tick range
     * @return c0 The maximum potential commitment for token0 over [tickLower, tickUpper]
     * @return c1 The maximum potential commitment for token1 over [tickLower, tickUpper]
     */
    function calculateCommitmentMaxima(int24 tickLower, int24 tickUpper, uint128 liquidity)
        public
        pure
        returns (uint256 c0, uint256 c1)
    {
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        // Token0 amount across the full range for this liquidity
        c0 = SqrtPriceMath.getAmount0Delta(sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity, true);
        // Token1 amount across the full range for this liquidity
        c1 = SqrtPriceMath.getAmount1Delta(sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity, true);
    }

    /**
     * @notice Tracks the maximum potential commitment for both tokens in a position
     * @param router The sender of the transaction
     * @param params The parameters of the transaction
     */
    function _trackCommitment(address router, PoolId corePoolId, ModifyLiquidityParams calldata params) public {
        PositionId positionId = PositionLibrary.generateId(router, params);
        // Associate position with its core pool id for later reads
        positionPoolId[positionId] = corePoolId;

        // Current tracked maxima for this position
        uint256 currentC0 = commitmentMaxima[positionId][0];
        uint256 currentC1 = commitmentMaxima[positionId][1];

        if (params.liquidityDelta > 0) {
            // Liquidity added: increase tracked maxima by the delta's maxima over the tick range
            uint128 liquidityAdded = SafeCastLib.safeCastTo128(uint256(params.liquidityDelta));
            (uint256 addC0, uint256 addC1) =
                calculateCommitmentMaxima(params.tickLower, params.tickUpper, liquidityAdded);

            commitmentMaxima[positionId][0] = currentC0 + addC0;
            commitmentMaxima[positionId][1] = currentC1 + addC1;
        } else if (params.liquidityDelta < 0) {
            // Liquidity removed: decrease tracked maxima by the delta's maxima over the tick range
            uint128 liquidityRemoved = SafeCastLib.safeCastTo128(uint256(-params.liquidityDelta));
            (uint256 subC0, uint256 subC1) =
                calculateCommitmentMaxima(params.tickLower, params.tickUpper, liquidityRemoved);

            // Clamp at zero to avoid underflow; if fully removed, both become zero
            commitmentMaxima[positionId][0] = currentC0 > subC0 ? (currentC0 - subC0) : 0;
            commitmentMaxima[positionId][1] = currentC1 > subC1 ? (currentC1 - subC1) : 0;
        } else {
            // No-op if liquidityDelta == 0 (poke)
            return;
        }
    }

    // Placeholder: without duplicating enumeration, we approximate share using position's own liquidity vs pool liquidity
    // For exact per-position allocation, wire a pool-wide position iterator (e.g., from MMPositionManager) later.
    function _getLiquidityShareForPosition(PoolId corePoolId, PositionId positionId)
        internal
        view
        returns (uint128 positionLiquidity, uint256 inRangeTotal)
    {
        // Position-specific liquidity
        uint128 liqPos = poolManager.getPositionLiquidity(corePoolId, PositionId.unwrap(positionId));
        // Use pool total in-range liquidity as denominator approximation - See explaination: static/poolManager-getLiquidity.md
        uint128 poolLiq = poolManager.getLiquidity(corePoolId);
        return (liqPos, uint256(poolLiq));
    }

    /**
     * @notice Records the settlement of assets on a position
     * @dev make sure this function can only be called by the position manager since that is the interface through which settlements are going to be made
     * @param positionId The id of the position
     * @param balanceDelta The balance delta of the settlement
     */
    function onMMLiquidityModify(PositionId positionId, BalanceDelta balanceDelta) external {
        if (msg.sender != mmPositionManager) {
            revert InvalidCaller();
        }
        int128 amount0 = balanceDelta.amount0();
        int128 amount1 = balanceDelta.amount1();

        totalSettlementAmount[positionId][0] =
            _updateSettlement(totalSettlementAmount[positionId][0], balanceDelta.amount0());
        totalSettlementAmount[positionId][1] =
            _updateSettlement(totalSettlementAmount[positionId][1], balanceDelta.amount1());

        // emit an event to notify that the assets have been settled on a position
        emit AssetsSettled(positionId, amount0, amount1);
    }

    /**
     * @notice Gets the current vts for a position
     * @param positionId The position id
     * @return vtsCurrent0 The current vts for token0
     * @return vtsCurrent1 The current vts for token1
     */
    function getVTSCurrent(PositionId positionId)
        public
        view
        virtual
        returns (uint256 vtsCurrent0, uint256 vtsCurrent1)
    {
        uint256 c0 = commitmentMaxima[positionId][0];
        uint256 c1 = commitmentMaxima[positionId][1];
        uint256 s0 = totalSettlementAmount[positionId][0];
        uint256 s1 = totalSettlementAmount[positionId][1];

        vtsCurrent0 = VTSMath.vtsCurrentBps(s0, c0);
        vtsCurrent1 = VTSMath.vtsCurrentBps(s1, c1);
    }

    /**
     * @notice Gets the required vts for a position
     * @dev this function is virtual and can be overridden in order to mock the values
     * @param _positionId The position id
     * @return vtsRequired0 The required vts for token0
     * @return vtsRequired1 The required vts for token1
     */
    function getVTSRequired(PositionId _positionId)
        public
        view
        virtual
        returns (uint256 vtsRequired0, uint256 vtsRequired1)
    {
        // If calculator is set, try calculator first
        if (address(calculator) != address(0)) {
            return (0, 0);
        }

        // Position metadata
        PositionMeta memory meta = positionIndex.getMeta(_positionId);
        PoolId corePoolId = meta.poolId;
        if (PoolId.unwrap(corePoolId) == bytes32(0)) {
            return (0, 0);
        }

        // Commitment caps
        uint256 c0 = commitmentMaxima[_positionId][0];
        uint256 c1 = commitmentMaxima[_positionId][1];
        if (c0 == 0 && c1 == 0) {
            return (0, 0);
        }

        // Accumulators for per-position deficits
        uint256 Dr0 = 0;
        uint256 Dr1 = 0;

        // Walk deficits in chronological order; attribute across all prior swaps (no fallback)
        EventRing.RingD storage dRing = deficitRing[corePoolId];
        EventRing.RingSwap storage sRing = swapRing[corePoolId];

        // Precompute position range sqrt bounds
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(meta.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(meta.tickUpper);

        // For each DeficitEvent, it sums pool outflows and the position’s attributed outflows across all SwapEvents with ts <= deficit.ts, intersecting the swap path with the position’s price range and using liquidityAt(ts).
        uint16 dHead = dRing.head;
        for (uint16 di = dRing.tail; di != dHead; di = (di + 1) & (dRing.cap - 1)) {
            DeficitEvent storage de = dRing.buf[di];

            // Sum pool outflow and position-attributed outflow across all swaps with ts <= deficit.ts
            uint256 sumPoolOut = 0;
            uint256 sumPosOut = 0;

            uint16 sHead2 = sRing.head;
            uint16 sTail2 = sRing.tail;
            for (uint16 si = sTail2; si != sHead2; si = (si + 1) & (sRing.cap - 1)) {
                SwapEvent storage sv = sRing.buf[si];
                if (sv.ts == 0 || sv.ts > de.ts) {
                    // only consider swaps at or before deficit timestamp
                    if (sv.ts == 0) continue;
                    break;
                }

                // Accumulate total pool outflow for selected token
                uint256 outTot = de.token == 0 ? uint256(sv.out0) : uint256(sv.out1);
                if (outTot == 0) {
                    continue;
                }
                sumPoolOut += outTot;

                // Attribute position share if swap path intersects position range at that time
                uint128 Lr = positionIndex.liquidityAt(_positionId, sv.ts);
                if (Lr == 0) {
                    continue;
                }
                uint160 a = sv.sqrtP_before;
                uint160 b = sv.sqrtP_after;
                uint160 start = a < b ? a : b;
                uint160 end = a < b ? b : a;
                if (end <= sqrtLower || start >= sqrtUpper) {
                    continue; // no intersection
                }
                uint160 isStart = start < sqrtLower ? sqrtLower : start;
                uint160 isEnd = end > sqrtUpper ? sqrtUpper : end;
                if (isStart == isEnd) {
                    continue;
                }

                uint256 posOut;
                if (de.token == 0) {
                    posOut = SqrtPriceMath.getAmount0Delta(isStart, isEnd, Lr, true);
                } else {
                    posOut = SqrtPriceMath.getAmount1Delta(isStart, isEnd, Lr, true);
                }
                if (posOut == 0) {
                    continue;
                }
                sumPosOut += posOut;
            }

            if (sumPoolOut == 0 || sumPosOut == 0) {
                // No attribution possible on-chain within ring window; skip (no fallback)
                continue;
            }

            uint256 attributed = (uint256(de.deficit) * sumPosOut) / sumPoolOut;
            if (de.token == 0) {
                Dr0 += attributed;
            } else {
                Dr1 += attributed;
            }
        }

        // Apply pro-rata decay from settlements
        EventRing.RingS storage rRing = settlementRing[corePoolId];
        uint16 rHead = rRing.head;
        for (uint16 ri = rRing.tail; ri != rHead; ri = (ri + 1) & (rRing.cap - 1)) {
            SettlementEvent storage se = rRing.buf[ri];
            if (se.marketDeficitBefore == 0) continue;
            if (se.token == 0) {
                if (Dr0 > 0) {
                    Dr0 = Dr0 - ((Dr0 * se.settled) / se.marketDeficitBefore);
                }
            } else {
                if (Dr1 > 0) {
                    Dr1 = Dr1 - ((Dr1 * se.settled) / se.marketDeficitBefore);
                }
            }
        }

        vtsRequired0 = VTSMath.vtsRequired(Dr0, c0);
        vtsRequired1 = VTSMath.vtsRequired(Dr1, c1);
        return (vtsRequired0, vtsRequired1);
    }

    /**
     * @notice Gets the commitment for a position
     * @param positionId The position id
     * @return commitment0 The commitment for token0
     * @return commitment1 The commitment for token1
     */
    function _getCommitment(PositionId positionId)
        internal
        view
        virtual
        returns (uint256 commitment0, uint256 commitment1)
    {
        return (commitmentMaxima[positionId][0], commitmentMaxima[positionId][1]);
    }

    /**
     * @notice Gets the RFS for a position
     * @param positionId The position id
     * @return rfsOpen Whether the RFS is open
     * @return balanceDelta The balance delta of the amount of required to be settled or allowed to be withdrawn depending on if it is negative or positive
     */
    function getRFS(PositionId positionId) public view returns (bool, BalanceDelta) {
        (uint256 commitment0, uint256 commitment1) = _getCommitment(positionId);

        // get vts current
        (uint256 vtsCurrent0, uint256 vtsCurrent1) = getVTSCurrent(positionId);
        // get vts required
        (uint256 vtsRequired0, uint256 vtsRequired1) = getVTSRequired(positionId);

        // is rfs open if vts current is less than vts required for either currency0 or currency 1
        bool rfsOpen = vtsCurrent0 < vtsRequired0 || vtsCurrent1 < vtsRequired1;

        // get the balance delta required to be settled
        // the delta could either be positive or negative
        // if positive, it means the mm can withdraw the positive amount specified
        // if negative, it means the mm needs to settle the negative amount specified to at least meet the required vts treshold
        int128 delta0 = int128(int256(vtsCurrent0) - int256(vtsRequired0));
        int128 delta1 = int128(int256(vtsCurrent1) - int256(vtsRequired1));

        // calculate the fraction of commitment based on delta (in bps)
        int128 commitmentFraction0 = (int128(int256(commitment0)) * delta0) / 10000;
        int128 commitmentFraction1 = (int128(int256(commitment1)) * delta1) / 10000;

        BalanceDelta balanceDelta = toBalanceDelta(commitmentFraction0, commitmentFraction1);

        return (rfsOpen, balanceDelta);
    }

    /**
     * @notice Updates the settlement amount by a delta which could be positive or negative
     * @param currentSettled The current settlement amount
     * @param delta The delta of the settlement
     * @return The updated settlement amount
     */
    function _updateSettlement(uint256 currentSettled, int256 delta) internal pure returns (uint256) {
        if (delta > 0) {
            return currentSettled + uint256(delta);
        }

        if (delta < 0) {
            uint256 subtract = uint256(-delta);
            if (currentSettled >= subtract) {
                return currentSettled - subtract;
            } else {
                revert NotEnoughSettlementBalance(currentSettled, subtract);
            }
        }

        return currentSettled;
    }

    function _flushSwap(PoolId poolId) internal {
        EventRing.RingSwap storage r = swapRing[poolId];
        uint16 cap = r.cap;
        uint16 start = r.tail;
        uint16 count = cap / 2;
        bytes32 h;
        for (uint16 i = 0; i < count; i++) {
            uint16 idx = (start + i) & (cap - 1);
            SwapEvent storage e = r.buf[idx];
            h = keccak256(abi.encodePacked(h, e.ts, e.sqrtP_before, e.sqrtP_after, e.out0, e.out1));
        }
        uint256 seg = swapFlushCount[poolId]++;
        swapFlushedRoots[poolId][seg] = h;
        emit RingFlushed(poolId, 0, seg, h, start, uint16((start + count) & (cap - 1)));
        r.tail = uint16((start + count) & (cap - 1));
    }

    function _flushDeficit(PoolId poolId) internal {
        EventRing.RingD storage r = deficitRing[poolId];
        uint16 cap = r.cap;
        uint16 start = r.tail;
        uint16 count = cap / 2;
        bytes32 h;
        for (uint16 i = 0; i < count; i++) {
            uint16 idx = (start + i) & (cap - 1);
            DeficitEvent storage e = r.buf[idx];
            h = keccak256(abi.encodePacked(h, e.ts, e.token, e.deficit));
        }
        uint256 seg = deficitFlushCount[poolId]++;
        deficitFlushedRoots[poolId][seg] = h;
        emit RingFlushed(poolId, 1, seg, h, start, uint16((start + count) & (cap - 1)));
        r.tail = uint16((start + count) & (cap - 1));
    }

    function _flushSettlement(PoolId poolId) internal {
        EventRing.RingS storage r = settlementRing[poolId];
        uint16 cap = r.cap;
        uint16 start = r.tail;
        uint16 count = cap / 2;
        bytes32 h;
        for (uint16 i = 0; i < count; i++) {
            uint16 idx = (start + i) & (cap - 1);
            SettlementEvent storage e = r.buf[idx];
            h = keccak256(abi.encodePacked(h, e.ts, e.token, e.settled, e.marketDeficitBefore));
        }
        uint256 seg = settlementFlushCount[poolId]++;
        settlementFlushedRoots[poolId][seg] = h;
        emit RingFlushed(poolId, 2, seg, h, start, uint16((start + count) & (cap - 1)));
        r.tail = uint16((start + count) & (cap - 1));
    }

    // Debugging helpers
    function getSwapRingState(PoolId poolId) external view returns (uint16 head, uint16 tail) {
        return (swapRing[poolId].head, swapRing[poolId].tail);
    }

    function getDeficitRingState(PoolId poolId) external view returns (uint16 head, uint16 tail) {
        return (deficitRing[poolId].head, deficitRing[poolId].tail);
    }

    function getSettlementRingState(PoolId poolId) external view returns (uint16 head, uint16 tail) {
        return (settlementRing[poolId].head, settlementRing[poolId].tail);
    }

    function getFlushedCounts(PoolId poolId)
        external
        view
        returns (uint256 swapCount, uint256 deficitCount, uint256 settlementCount)
    {
        return (swapFlushCount[poolId], deficitFlushCount[poolId], settlementFlushCount[poolId]);
    }
}
