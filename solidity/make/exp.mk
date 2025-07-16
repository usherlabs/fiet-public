
# Arbitrum Sepolia Testnet Experiments

WETH_SEPOLIA=0x980B62Da83eFf3D4576C647993b0c1D7faf17c73
USDC_SEPOLIA=0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d
SQRT_PRICE_SEPOLIA=1383400000000000000000

wrap-eth-sepolia:
	cast send $(WETH_SEPOLIA) "deposit()" --value 0.01ether --rpc-url $(ARB_SEPOLIA_RPC) --private-key $(PRIVATE_KEY)

create-market-sepolia:
	forge script solidity/script/CreateMarket.s.sol:CreateMarketScript \
		--rpc-url $(ARB_SEPOLIA_RPC) \
		--broadcast \
		--private-key $(PRIVATE_KEY) \
		-vvvv \
		--ffi \
		--sig "run()" \
		--with-gas-price 2000000000 \
		NETWORK=sepolia \
		UNDERLYING_ASSET_0=$(WETH_SEPOLIA) \
		UNDERLYING_ASSET_1=$(USDC_SEPOLIA) \
		CORE_POOL_FEE=0 \
		TICK_SPACING=60 \
		INITIAL_SQRT_PRICE_X96=$(SQRT_PRICE_SEPOLIA)

add-liquidity-sepolia:
	forge script solidity/script/AddLiquidity.s.sol:AddLiquidityScript \
		--rpc-url $(ARB_SEPOLIA_RPC) \
		--broadcast \
		--private-key $(PRIVATE_KEY) \
		-vvvv \
		--ffi \
		--sig "run()" \
		--with-gas-price 2000000000 \
		NETWORK=sepolia \
		UNDERLYING_ASSET_0=$(USDC_SEPOLIA) \
		UNDERLYING_ASSET_1=$(WETH_SEPOLIA) \
		CORE_POOL_FEE=0 \
		TICK_SPACING=60 \
		AMOUNT_0_DESIRED=10000000

# Arbitrum Mainnet Experiments

WETH_MAINNET=0x82aF49447D8a07e3bd95BD0d56f35241523fBab1
USDC_MAINNET=0xaf88d065e77c8cC2239327C5EDb3A432268e5831
SQRT_PRICE_MAINNET=4537000000000000000000000

wrap-eth-mainnet:
	cast send $(WETH_MAINNET) "deposit()" --value 0.01ether --rpc-url $(ARB_RPC) --private-key $(PRIVATE_KEY)

create-market-mainnet:
	forge script solidity/script/CreateMarket.s.sol:CreateMarketScript \
		--rpc-url $(ARB_RPC) \
		--broadcast \
		--private-key $(PRIVATE_KEY) \
		-vvvv \
		--ffi \
		--sig "run()" \
		--with-gas-price 2000000000 \
		NETWORK=arbitrum \
		UNDERLYING_ASSET_0=$(WETH_MAINNET) \
		UNDERLYING_ASSET_1=$(USDC_MAINNET) \
		CORE_POOL_FEE=0 \
		TICK_SPACING=60 \
		INITIAL_SQRT_PRICE_X96=$(SQRT_PRICE_MAINNET)

add-liquidity-mainnet:
	forge script solidity/script/AddLiquidity.s.sol:AddLiquidityScript \
		--rpc-url $(ARB_RPC) \
		--broadcast \
		--private-key $(PRIVATE_KEY) \
		-vvvv \
		--ffi \
		--sig "run()" \
		--with-gas-price 2000000000 \
		NETWORK=arbitrum \
		UNDERLYING_ASSET_0=$(WETH_MAINNET) \
		UNDERLYING_ASSET_1=$(USDC_MAINNET) \
		CORE_POOL_FEE=0 \
		TICK_SPACING=60 \
		AMOUNT_1_DESIRED=10000000

