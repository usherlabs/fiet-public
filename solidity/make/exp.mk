
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
		--private-key $(LP_PRIVATE_KEY) \
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

# ? Change the CORE_POOL_ID and AMOUNT or use as a reference to execute directly from the CLI
swap-sepolia:
	forge script solidity/script/SwapV4.s.sol:SwapV4 \
		--rpc-url $(ARB_SEPOLIA_RPC) \
		--broadcast \
		--private-key $(LP_PRIVATE_KEY) \
		-vvvv \
		--ffi \
		--sig "run()" \
		--with-gas-price 2000000000 \
		NETWORK=sepolia \
		SWAP_TYPE=0 \
		CORE_POOL_ID=0x0000000000000000000000000000000000000000000000000000000000000000 \
		AMOUNT=1000000


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
		--private-key $(LP_PRIVATE_KEY) \
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


# Eth Sepolia Testnet Experiments

WETH_ETHSEPOLIA=0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9
USDC_ETHSEPOLIA=0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
SQRT_PRICE_ETHSEPOLIA=4537000000000000000000000  # Adjust as needed

wrap-eth-ethsepolia:
	cast send $(WETH_ETHSEPOLIA) "deposit()" --value 0.01ether --rpc-url $(ETH_SEPOLIA_RPC) --private-key $(PRIVATE_KEY)

create-market-ethsepolia:
	forge script solidity/script/CreateMarket.s.sol:CreateMarketScript \
		--rpc-url $(ETH_SEPOLIA_RPC) \
		--broadcast \
		--private-key $(PRIVATE_KEY) \
		-vvvv \
		--ffi \
		--sig "run()" \
		--with-gas-price 2000000000 \
		NETWORK=ethsepolia \
		UNDERLYING_ASSET_0=$(WETH_ETHSEPOLIA) \
		UNDERLYING_ASSET_1=$(USDC_ETHSEPOLIA) \
		CORE_POOL_FEE=0 \
		TICK_SPACING=60 \
		INITIAL_SQRT_PRICE_X96=$(SQRT_PRICE_ETHSEPOLIA)

add-liquidity-ethsepolia:
	forge script solidity/script/AddLiquidity.s.sol:AddLiquidityScript \
		--rpc-url $(ETH_SEPOLIA_RPC) \
		--broadcast \
		--private-key $(LP_PRIVATE_KEY) \
		-vvvv \
		--ffi \
		--sig "run()" \
		--with-gas-price 2000000000 \
		NETWORK=ethsepolia \
		UNDERLYING_ASSET_0=$(USDC_ETHSEPOLIA) \
		UNDERLYING_ASSET_1=$(WETH_ETHSEPOLIA) \
		CORE_POOL_FEE=0 \
		TICK_SPACING=60 \
		AMOUNT_0_DESIRED=10000000

