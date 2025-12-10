// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SepoliaConstants} from "../constants/ArbitrumSepolia.sol";
import {EthSepoliaConstants} from "../constants/EthSepolia.sol";
import {ArbitrumConstants} from "../constants/Arbitrum.sol";
import {CurrencySortHelper} from "../libraries/CurrencySortHelper.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

interface IERC20 {
    function decimals() external view returns (uint8);
}

contract GetCurrentSqrtPrice is Script {
    using StateLibrary for IPoolManager;

    function run() external view {
        string memory networkName = vm.envString("NETWORK");

        address poolManagerAddress;
        if (keccak256(bytes(networkName)) == keccak256(bytes("arbitrum"))) {
            poolManagerAddress = ArbitrumConstants.POOL_MANAGER;
        } else if (keccak256(bytes(networkName)) == keccak256(bytes("sepolia"))) {
            poolManagerAddress = SepoliaConstants.POOL_MANAGER;
        } else if (keccak256(bytes(networkName)) == keccak256(bytes("ethsepolia"))) {
            poolManagerAddress = EthSepoliaConstants.POOL_MANAGER;
        } else {
            revert("Unsupported network");
        }

        IPoolManager manager = IPoolManager(poolManagerAddress);

        string memory poolIdStr = vm.envString("POOL_ID");
        require(bytes(poolIdStr).length > 0, "POOL_ID must be provided");

        bytes32 poolIdBytes = vm.parseBytes32(poolIdStr);
        PoolId poolId = PoolId.wrap(poolIdBytes);

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);

        console.log("Current sqrtPriceX96: %s", sqrtPriceX96);

        // Calculate current price assuming 18 decimals scaling
        uint256 sqrtMid = (uint256(sqrtPriceX96) * 1_000_000_000) >> 96;
        uint256 price = sqrtMid * sqrtMid;
        console.log("Current price (with 18 decimals, no decimal adjustment): %s", price);

        address tokenA;
        address tokenB;
        try vm.envAddress("TOKEN_A") returns (address _tokenA) {
            tokenA = _tokenA;
        } catch {}
        try vm.envAddress("TOKEN_B") returns (address _tokenB) {
            tokenB = _tokenB;
        } catch {}

        uint256 decA = tokenA == address(0) ? 18 : IERC20(tokenA).decimals();
        uint256 decB = tokenB == address(0) ? 18 : IERC20(tokenB).decimals();

        (Currency currency0, Currency currency1) = CurrencySortHelper.sortAddresses(tokenA, tokenB);

        uint256 dec0 = Currency.unwrap(currency0) == tokenA ? decA : decB;
        uint256 dec1 = Currency.unwrap(currency1) == tokenB ? decB : decA;

        // Adjust the price for decimals: adjusted_price = price * 10^(dec0 - dec1)
        // Since price is P_internal * 10^18, adjusted is human_price_of_token0_in_token1 * 10^18
        int256 decimalDiff = int256(dec0) - int256(dec1);
        uint256 adjustedPrice;
        if (decimalDiff >= 0) {
            adjustedPrice = price * (10 ** uint256(decimalDiff));
        } else {
            adjustedPrice = price / (10 ** uint256(-decimalDiff));
        }

        console.log("Adjusted price (with 18 decimals): %s", adjustedPrice);
        console.log("This represents the price of 1 whole token0 in whole token1 units, scaled by 10^18");
    }
}
