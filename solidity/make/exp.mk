
# =============================================================================
# Fiet Protocol - Experimental Commands
# =============================================================================
# This file contains experimental commands for testing the Fiet protocol
# across different networks and configurations.
#
# 🚀 Usage: make exp <command>
# Example: make exp wrap-eth-sepolia
#
# 📋 Available Experimental Commands:
#
# Arbitrum Sepolia Testnet:
#   wrap-eth-sepolia       - Wrap ETH to WETH on Arbitrum Sepolia
#   create-market-sepolia  - Create a new market on Arbitrum Sepolia
#   add-liquidity-sepolia  - Add liquidity to market on Arbitrum Sepolia
#   swap-sepolia           - Execute a swap on Arbitrum Sepolia
#
# Arbitrum Mainnet:
#   wrap-eth-mainnet       - Wrap ETH to WETH on Arbitrum Mainnet
#   create-market-mainnet  - Create a new market on Arbitrum Mainnet
#   add-liquidity-mainnet  - Add liquidity to market on Arbitrum Mainnet
#
# Ethereum Sepolia Testnet:
#   wrap-eth-ethsepolia    - Wrap ETH to WETH on Ethereum Sepolia
#   create-market-ethsepolia - Create a new market on Ethereum Sepolia
#   add-liquidity-ethsepolia - Add liquidity to market on Ethereum Sepolia
#   unwrap-eth-ethsepolia   - Unwrap all WETH to ETH on Ethereum Sepolia testnet
#
# 📋 Prerequisites:
#   - Set up environment variables in .env file
#   - Ensure you have sufficient funds for gas fees
#   - Have the required private keys configured
#
# ⚙️  Environment Variables Required:
#   - ARB_SEPOLIA_RPC: Arbitrum Sepolia RPC URL
#   - ARB_RPC: Arbitrum Mainnet RPC URL
#   - ETH_SEPOLIA_RPC: Ethereum Sepolia RPC URL
#   - PRIVATE_KEY: Your private key for transactions
#   - LP_PRIVATE_KEY: Liquidity provider private key
#
# 💡 Usage Examples:
#   make exp wrap-eth-sepolia           # Wrap 0.01 ETH on Arbitrum Sepolia
#   make exp create-market-sepolia      # Create WETH/USDC market on Arbitrum Sepolia
#   make exp add-liquidity-sepolia      # Add liquidity to Arbitrum Sepolia market
#   make exp swap-sepolia               # Execute swap on Arbitrum Sepolia
#
# 🔧 Customisation:
#   - Modify token addresses (WETH_*, USDC_*) for different tokens
#   - Adjust SQRT_PRICE_* values for different initial prices
#   - Change gas prices and other parameters as needed
# =============================================================================

# === Experimental Commands Help ===
exp-help: ## Show available experimental commands
	@echo "🧪 Fiet Protocol - Experimental Commands"
	@echo "========================================"
	@echo ""
	@echo "📋 Usage: make exp <command>"
	@echo ""
	@echo "🚀 Available Experimental Commands:"
	@echo ""
	@echo "🔬 Arbitrum Sepolia Testnet:"
	@echo "  wrap-eth-sepolia       - Wrap ETH to WETH on Arbitrum Sepolia"
	@echo "  create-market-sepolia  - Create WETH/USDC market on Arbitrum Sepolia"
	@echo "  add-liquidity-sepolia  - Add liquidity to market on Arbitrum Sepolia"
	@echo "  swap-sepolia           - Execute swap on Arbitrum Sepolia"
	@echo ""
	@echo "🔬 Arbitrum Mainnet:"
	@echo "  wrap-eth-mainnet       - Wrap ETH to WETH on Arbitrum Mainnet"
	@echo "  create-market-mainnet  - Create WETH/USDC market on Arbitrum Mainnet"
	@echo "  add-liquidity-mainnet  - Add liquidity to market on Arbitrum Mainnet"
	@echo ""
	@echo "🔬 Ethereum Sepolia Testnet:"
	@echo "  wrap-eth-ethsepolia    - Wrap ETH to WETH on Ethereum Sepolia"
	@echo "  create-market-ethsepolia - Create WETH/USDC market on Ethereum Sepolia"
	@echo "  add-liquidity-ethsepolia - Add liquidity to market on Ethereum Sepolia"
	@echo "  unwrap-eth-ethsepolia   - Unwrap all WETH to ETH on Ethereum Sepolia testnet"
	@echo ""
	@echo "💡 Examples:"
	@echo "  make exp wrap-eth-sepolia      # Wrap 0.01 ETH on Arbitrum Sepolia"
	@echo "  make exp create-market-sepolia # Create market on Arbitrum Sepolia"
	@echo "  make exp add-liquidity-sepolia # Add liquidity to Arbitrum Sepolia"
	@echo "  make exp swap-sepolia          # Execute swap on Arbitrum Sepolia"
	@echo ""
	@echo "📋 Prerequisites:"
	@echo "  - Set up environment variables in .env file"
	@echo "  - Ensure you have sufficient funds for gas fees"
	@echo "  - Have the required private keys configured"
	@echo ""
	@echo "⚙️  Required Environment Variables:"
	@echo "  - ARB_SEPOLIA_RPC: Arbitrum Sepolia RPC URL"
	@echo "  - ARB_RPC: Arbitrum Mainnet RPC URL"
	@echo "  - ETH_SEPOLIA_RPC: Ethereum Sepolia RPC URL"
	@echo "  - PRIVATE_KEY: Your private key for transactions"
	@echo "  - LP_PRIVATE_KEY: Liquidity provider private key"


# Default exp target - show usage when no command specified
exp:
	@echo ""

# Arbitrum Sepolia Testnet Experiments

WETH_SEPOLIA=0x980B62Da83eFf3D4576C647993b0c1D7faf17c73
USDC_SEPOLIA=0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d
SQRT_PRICE_SEPOLIA=1383400000000000000000
WETH_AMOUNT=10000000000000000 # 0.01 WETH * 10^18
USDC_AMOUNT=8000000 # 8 USDC * 10^6

# CORE_POOL_ID=0x9c2ccb7d008338a01b98727a7f17c7294859eeb8061b26d5b28c74d424f2b102 # WETH/USDC
SWAP_AMOUNT=1000000 # 1 USDC * 10^6

# ? Add ARGS="--broadcast" to broadcast to the network. eg. `make exp swap-sepolia ARGS="--broadcast"`
# ? (LP_)PRIVATE_KEY removed from the commands. Load via .env file.

wrap-eth-sepolia: ## Wrap ETH to WETH on Arbitrum Sepolia testnet
	cast send $(WETH_SEPOLIA) "deposit()" --value $(WETH_AMOUNT) --rpc-url $(ARB_SEPOLIA_RPC_URL) --private-key $(PRIVATE_KEY)

create-market-sepolia: ## Create WETH/USDC market on Arbitrum Sepolia testnet
	NETWORK=sepolia \
	UNDERLYING_ASSET_0=$(WETH_SEPOLIA) \
	UNDERLYING_ASSET_1=$(USDC_SEPOLIA) \
	CORE_POOL_FEE=0 \
	TICK_SPACING=60 \
	INITIAL_SQRT_PRICE_X96=$(SQRT_PRICE_SEPOLIA) \
	forge script script/CreateMarket.s.sol:CreateMarketScript \
		--rpc-url $(ARB_SEPOLIA_RPC_URL) \
		-vvvv \
		--ffi \
		--sig "run()" \
		--with-gas-price 2000000000 \
		$(ARGS) 

add-liquidity-sepolia: ## Add liquidity to WETH/USDC market on Arbitrum Sepolia testnet
	NETWORK=sepolia \
	UNDERLYING_ASSET_0=$(WETH_SEPOLIA) \
	UNDERLYING_ASSET_1=$(USDC_SEPOLIA) \
	CORE_POOL_FEE=0 \
	TICK_SPACING=60 \
	WETH_AMOUNT=$(WETH_AMOUNT) \
	forge script script/AddLiquidity.s.sol:AddLiquidityScript \
		--rpc-url $(ARB_SEPOLIA_RPC_URL) \
		-vvvv \
		--ffi \
		--sig "run()" \
		--with-gas-price 2000000000 \
		$(ARGS)

# ? Change the CORE_POOL_ID and AMOUNT or use as a reference to execute directly from the CLI
swap-sepolia: ## Execute swap on Arbitrum Sepolia testnet
	NETWORK=sepolia \
	SWAP_TYPE=0 \
	CORE_POOL_ID=$(CORE_POOL_ID) \
	AMOUNT=$(SWAP_AMOUNT) \
	forge script script/SwapV4.s.sol:SwapV4 \
		--rpc-url $(ARB_SEPOLIA_RPC_URL) \
		-vvvv \
		--ffi \
		--sig "run()" \
		--with-gas-price 2000000000 \
		$(ARGS)


# Arbitrum Mainnet Experiments

ARB_MAINNET=0x912ce59144191c1204e64559fe8253a0e49e6548
USDT_MAINNET=0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9
SQRT_PRICE_MAINNET=54275522706223419759561
# USDT_AMOUNT=1000000 # 1 USDT * 10^6
# USDT_AMOUNT=998000000 # 998 USDT * 10^6
# USDT_AMOUNT=50000000 # 50 USDT * 10^6
USDT_AMOUNT=5660000000 # 6003 USDT * 10^6
# ARB_AMOUNT=2121256710000000000 # 2.12125671 ARB * 10^18

# wrap-eth-mainnet: ## Wrap ETH to WETH on Arbitrum mainnet
# 	cast send $(WETH_MAINNET) "deposit()" --value $(WETH_AMOUNT) --rpc-url $(ARB_MAINNET_RPC_URL) --private-key $(PRIVATE_KEY)

create-market-mainnet:
	NETWORK=arbitrum \
	UNDERLYING_ASSET_0=$(ARB_MAINNET) \
	UNDERLYING_ASSET_1=$(USDT_MAINNET) \
	CORE_POOL_FEE=400 \
	TICK_SPACING=10 \
	REFERENCE_POOL_ID=0x90adeaeba1b0550987637183712c138484af473093e2006a0fecaad3241ddb1c \
	forge script script/CreateMarket.s.sol:CreateMarketScript \
		--rpc-url $(ARB_MAINNET_RPC_URL) \
		-vvvv \
		--ffi \
		--sig "run()" \
		--with-gas-price 2000000000 \
		$(ARGS)

add-liquidity-mainnet:
	NETWORK=arbitrum \
	UNDERLYING_ASSET_0=$(ARB_MAINNET) \
	UNDERLYING_ASSET_1=$(USDT_MAINNET) \
	CORE_POOL_FEE=400 \
	TICK_SPACING=10 \
	RANGE_WIDTH=48000 \
	UA_1_AMOUNT=$(USDT_AMOUNT) \
	forge script script/AddLiquidity.s.sol:AddLiquidityScript \
		--rpc-url $(ARB_MAINNET_RPC_URL) \
		-vvvv \
		--ffi \
		--sig "run()" \
		--with-gas-price 2000000000 \
		$(ARGS)

remove-liquidity-mainnet:
	NETWORK=arbitrum \
	CORE_POOL_ID=0x9a24909eeeb9fb7bbae5e01f6bdf9d892aafdfadab304c377e2b617acb0db32a \
	TOKEN_ID=52788 \
	forge script script/RemoveLiquidity.s.sol:RemoveLiquidityScript \
		--rpc-url $(ARB_MAINNET_RPC_URL) \
		-vvvv \
		--ffi \
		--sig "run()" \
		--with-gas-price 2000000000 \
		$(ARGS)


# Eth Sepolia Testnet Experiments

WETH_ETHSEPOLIA=0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9
USDC_ETHSEPOLIA=0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
# SQRT_PRICE_ETHSEPOLIA=1080713651697821322704392060815896  # Adjust as needed - source: https://sepolia.etherscan.io/address/0x3289680dD4d6C10bb19b899729cda5eEF58AEfF1#events
ETH_WETH_AMOUNT=100000000000000000 # 0.1 WETH * 10^18

wrap-eth-ethsepolia: ## Wrap ETH to WETH on Ethereum Sepolia testnet
	cast send $(WETH_ETHSEPOLIA) "deposit()" --value $(ETH_WETH_AMOUNT) --rpc-url $(ETH_SEPOLIA_RPC_URL) --private-key $(PRIVATE_KEY)

create-market-ethsepolia: ## Create WETH/USDC market on Ethereum Sepolia testnet
	NETWORK=ethsepolia \
	UNDERLYING_ASSET_0=$(WETH_ETHSEPOLIA) \
	UNDERLYING_ASSET_1=$(USDC_ETHSEPOLIA) \
	CORE_POOL_FEE=100 \
	TICK_SPACING=2 \
	ASSET0_PRICE=1000000 \
	ASSET1_PRICE=5751990000 \
	forge script script/CreateMarket.s.sol:CreateMarketScript \
		--rpc-url $(ETH_SEPOLIA_RPC_URL) \
		-vvvv \
		--ffi \
		--sig "run()" \
		--with-gas-price 2000000000 \
		$(ARGS)

add-liquidity-ethsepolia: ## Add liquidity to WETH/USDC market on Ethereum Sepolia testnet
	NETWORK=ethsepolia \
	UNDERLYING_ASSET_0=$(USDC_ETHSEPOLIA) \
	UNDERLYING_ASSET_1=$(WETH_ETHSEPOLIA) \
	CORE_POOL_FEE=100 \
	TICK_SPACING=2 \
	RANGE_WIDTH=100 \
	UA_1_AMOUNT=$(ETH_WETH_AMOUNT) \
	forge script script/AddLiquidity.s.sol:AddLiquidityScript \
		--rpc-url $(ETH_SEPOLIA_RPC_URL) \
		-vvvv \
		--ffi \
		--sig "run()" \
		--with-gas-price 2000000000 \
		$(ARGS)

remove-liquidity-ethsepolia:
	NETWORK=ethsepolia \
	CORE_POOL_ID=0x4103a354d3ade92a0eb6b7fdb49fee00b252270d988ef6b45f022129a498fa6b \
	TOKEN_ID=15518 \
	forge script script/RemoveLiquidity.s.sol:RemoveLiquidityScript \
		--rpc-url $(ETH_SEPOLIA_RPC_URL) \
		-vvvv \
		--ffi \
		--sig "run()" \
		--with-gas-price 2000000000 \
		$(ARGS)

unwrap-eth-ethsepolia: ## Unwrap all WETH to ETH on Ethereum Sepolia testnet
	ADDRESS=$$(cast wallet address --private-key $(PRIVATE_KEY)); \
	BAL_HEX=$$(cast call $(WETH_ETHSEPOLIA) \"balanceOf(address)(uint256)\" $$ADDRESS --rpc-url $(ETH_SEPOLIA_RPC_URL)); \
	BALANCE=$$(cast --to-decimal $$BAL_HEX); \
	if [ $$BALANCE -eq 0 ]; then echo \"No WETH to unwrap\"; else cast send $(WETH_ETHSEPOLIA) \"withdraw(uint256)\" $$BALANCE --rpc-url $(ETH_SEPOLIA_RPC_URL) --private-key $(PRIVATE_KEY); fi