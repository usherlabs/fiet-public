# Fetch tick indexed fee growth from Uniswap
_Exported on 09/10/2025 at 2:33:43 GMT+11 from Cursor (1.7.38)_

---

**User**

Is here a way to fetch tick indexed fee growth from Uniswap contracts relative to a tick-range or position from an integrating hook or third-party contract?

---

**Cursor**

I'll search the codebase for how fee growth is stored/computed for ticks/positions and what view helpers exist to access it, then open the relevant interfaces/utilities.

Let me quickly check if the manager exposes any direct getters vs using the helper library, and capture the exact helper functions you can use inside a hook or third-party contract.

Yes. You can read tick-indexed fee growth for a tick, a tick range, or a specific position from a hook or any third-party contract by using the `StateLibrary` helpers (backed by `extsload`) against the `IPoolManager`.

### How to use
- Import the library and add the extension:
  - `using StateLibrary for IPoolManager;`
- Read tick-level or range-level fee growth:
  - `manager.getTickFeeGrowthOutside(poolId, tick)`
  - `manager.getFeeGrowthInside(poolId, tickLower, tickUpper)`
  - `manager.getFeeGrowthGlobals(poolId)`
- Read position cache (liquidity and last cached inside-fee growth):
  - `manager.getPositionInfo(poolId, owner, tickLower, tickUpper, salt)`

### Minimal examples (hook or third-party)
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolManager} from "src/interfaces/IPoolManager.sol";
import {PoolId} from "src/types/PoolId.sol";
import {StateLibrary} from "src/libraries/StateLibrary.sol";
import {FullMath} from "src/libraries/FullMath.sol";
import {FixedPoint128} from "src/libraries/FixedPoint128.sol";

contract Reader {
    using StateLibrary for IPoolManager;

    function feeGrowthForRange(
        IPoolManager manager,
        PoolId poolId,
        int24 lower,
        int24 upper
    ) external view returns (uint256 feeGrowth0X128, uint256 feeGrowth1X128) {
        return manager.getFeeGrowthInside(poolId, lower, upper);
    }

    function feeGrowthOutsideTick(
        IPoolManager manager,
        PoolId poolId,
        int24 tick
    ) external view returns (uint256 fg0OutsideX128, uint256 fg1OutsideX128) {
        return manager.getTickFeeGrowthOutside(poolId, tick);
    }

    function positionFeesOwed(
        IPoolManager manager,
        PoolId poolId,
        address owner,
        int24 lower,
        int24 upper,
        bytes32 salt
    ) external view returns (uint256 owed0, uint256 owed1) {
        (uint128 liq, uint256 last0, uint256 last1) =
            manager.getPositionInfo(poolId, owner, lower, upper, salt);
        (uint256 fg0, uint256 fg1) = manager.getFeeGrowthInside(poolId, lower, upper);
        unchecked {
            owed0 = FullMath.mulDiv(fg0 - last0, liq, FixedPoint128.Q128);
            owed1 = FullMath.mulDiv(fg1 - last1, liq, FixedPoint128.Q128);
        }
    }
}
```

### Relevant code in this repo
```122:144:src/libraries/StateLibrary.sol
    function getTickFeeGrowthOutside(IPoolManager manager, PoolId poolId, int24 tick)
        internal
        view
        returns (uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128)
    {
        bytes32 slot = _getTickInfoSlot(poolId, tick);

        // offset by 1 word, since the first word is liquidityGross + liquidityNet
        bytes32[] memory data = manager.extsload(bytes32(uint256(slot) + 1), 2);
        assembly ("memory-safe") {
            feeGrowthOutside0X128 := mload(add(data, 32))
            feeGrowthOutside1X128 := mload(add(data, 64))
        }
    }
```

```146:174:src/libraries/StateLibrary.sol
    function getFeeGrowthGlobals(IPoolManager manager, PoolId poolId)
        internal
        view
        returns (uint256 feeGrowthGlobal0, uint256 feeGrowthGlobal1)
    {
        bytes32 stateSlot = _getPoolStateSlot(poolId);
        bytes32 slot_feeGrowthGlobal0X128 = bytes32(uint256(stateSlot) + FEE_GROWTH_GLOBAL0_OFFSET);
        bytes32[] memory data = manager.extsload(slot_feeGrowthGlobal0X128, 2);
        assembly ("memory-safe") {
            feeGrowthGlobal0 := mload(add(data, 32))
            feeGrowthGlobal1 := mload(add(data, 64))
        }
    }
```

```288:322:src/libraries/StateLibrary.sol
    function getFeeGrowthInside(IPoolManager manager, PoolId poolId, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) = getFeeGrowthGlobals(manager, poolId);

        (uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128) =
            getTickFeeGrowthOutside(manager, poolId, tickLower);
        (uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128) =
            getTickFeeGrowthOutside(manager, poolId, tickUpper);
        (, int24 tickCurrent,,) = getSlot0(manager, poolId);
        unchecked {
            if (tickCurrent < tickLower) {
                feeGrowthInside0X128 = lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            } else if (tickCurrent >= tickUpper) {
                feeGrowthInside0X128 = upperFeeGrowthOutside0X128 - lowerFeeGrowthOutside0X128;
                feeGrowthInside1X128 = upperFeeGrowthOutside1X128 - lowerFeeGrowthOutside1X128;
            } else {
                feeGrowthInside0X128 = feeGrowthGlobal0X128 - lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = feeGrowthGlobal1X128 - lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            }
        }
    }
```

```91:101:src/libraries/Position.sol
        unchecked {
            feesOwed0 =
                FullMath.mulDiv(feeGrowthInside0X128 - self.feeGrowthInside0LastX128, liquidity, FixedPoint128.Q128);
            feesOwed1 =
                FullMath.mulDiv(feeGrowthInside1X128 - self.feeGrowthInside1LastX128, liquidity, FixedPoint128.Q128);
        }

        // update the position
        self.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        self.feeGrowthInside1LastX128 = feeGrowthInside1X128;
```

- Note: these are reads only; integrators should be mindful that `feeGrowthGlobal` can be inflated via donations, so use range-level `getFeeGrowthInside` and position-level last-cached values to compute fees precisely.

- Works the same way in hooks; most hooks keep an `IPoolManager` reference and can call these view helpers during hook callbacks.

- Summary
  - Use `StateLibrary` with `using ... for IPoolManager;` to get tick-level, range-level, or position-level fee growth.
  - Helpers: `getTickFeeGrowthOutside`, `getFeeGrowthInside`, `getFeeGrowthGlobals`, `getPositionInfo`.
  - Compute fees owed: multiply the delta of inside fee growth by position liquidity, scaled by `Q128`.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolManager} from "src/interfaces/IPoolManager.sol";
import {PoolId} from "src/types/PoolId.sol";
import {StateLibrary} from "src/libraries/StateLibrary.sol";
import {FullMath} from "src/libraries/FullMath.sol";
import {FixedPoint128} from "src/libraries/FixedPoint128.sol";

contract Reader {
    using StateLibrary for IPoolManager;

    function feeGrowthForRange(
        IPoolManager manager,
        PoolId poolId,
        int24 lower,
        int24 upper
    ) external view returns (uint256 feeGrowth0X128, uint256 feeGrowth1X128) {
        return manager.getFeeGrowthInside(poolId, lower, upper);
    }

    function feeGrowthOutsideTick(
        IPoolManager manager,
        PoolId poolId,
        int24 tick
    ) external view returns (uint256 fg0OutsideX128, uint256 fg1OutsideX128) {
        return manager.getTickFeeGrowthOutside(poolId, tick);
    }

    function positionFeesOwed(
        IPoolManager manager,
        PoolId poolId,
        address owner,
        int24 lower,
        int24 upper,
        bytes32 salt
    ) external view returns (uint256 owed0, uint256 owed1) {
        (uint128 liq, uint256 last0, uint256 last1) =
            manager.getPositionInfo(poolId, owner, lower, upper, salt);
        (uint256 fg0, uint256 fg1) = manager.getFeeGrowthInside(poolId, lower, upper);
        unchecked {
            owed0 = FullMath.mulDiv(fg0 - last0, liq, FixedPoint128.Q128);
            owed1 = FullMath.mulDiv(fg1 - last1, liq, FixedPoint128.Q128);
        }
    }
}
```

```plaintext
    function getTickFeeGrowthOutside(IPoolManager manager, PoolId poolId, int24 tick)
        internal
        view
        returns (uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128)
    {
        bytes32 slot = _getTickInfoSlot(poolId, tick);

        // offset by 1 word, since the first word is liquidityGross + liquidityNet
        bytes32[] memory data = manager.extsload(bytes32(uint256(slot) + 1), 2);
        assembly ("memory-safe") {
            feeGrowthOutside0X128 := mload(add(data, 32))
            feeGrowthOutside1X128 := mload(add(data, 64))
        }
    }
```

```plaintext
    function getFeeGrowthGlobals(IPoolManager manager, PoolId poolId)
        internal
        view
        returns (uint256 feeGrowthGlobal0, uint256 feeGrowthGlobal1)
    {
        bytes32 stateSlot = _getPoolStateSlot(poolId);
        bytes32 slot_feeGrowthGlobal0X128 = bytes32(uint256(stateSlot) + FEE_GROWTH_GLOBAL0_OFFSET);
        bytes32[] memory data = manager.extsload(slot_feeGrowthGlobal0X128, 2);
        assembly ("memory-safe") {
            feeGrowthGlobal0 := mload(add(data, 32))
            feeGrowthGlobal1 := mload(add(data, 64))
        }
    }
```

```plaintext
    function getFeeGrowthInside(IPoolManager manager, PoolId poolId, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) = getFeeGrowthGlobals(manager, poolId);

        (uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128) =
            getTickFeeGrowthOutside(manager, poolId, tickLower);
        (uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128) =
            getTickFeeGrowthOutside(manager, poolId, tickUpper);
        (, int24 tickCurrent,,) = getSlot0(manager, poolId);
        unchecked {
            if (tickCurrent < tickLower) {
                feeGrowthInside0X128 = lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            } else if (tickCurrent >= tickUpper) {
                feeGrowthInside0X128 = upperFeeGrowthOutside0X128 - lowerFeeGrowthOutside0X128;
                feeGrowthInside1X128 = upperFeeGrowthOutside1X128 - lowerFeeGrowthOutside1X128;
            } else {
                feeGrowthInside0X128 = feeGrowthGlobal0X128 - lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = feeGrowthGlobal1X128 - lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            }
        }
    }
```

```plaintext
        unchecked {
            feesOwed0 =
                FullMath.mulDiv(feeGrowthInside0X128 - self.feeGrowthInside0LastX128, liquidity, FixedPoint128.Q128);
            feesOwed1 =
                FullMath.mulDiv(feeGrowthInside1X128 - self.feeGrowthInside1LastX128, liquidity, FixedPoint128.Q128);
        }

        // update the position
        self.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        self.feeGrowthInside1LastX128 = feeGrowthInside1X128;
```

