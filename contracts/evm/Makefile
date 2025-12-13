# === Help ===
help: ## Show this help message
	@echo "🚀 Fiet Protocol - Solidity Development Commands"
	@echo "================================================"
	@echo ""
	@echo "📋 Available Commands:"
	@echo ""
	@echo "🔧 Development Commands:"
	@echo "  dev                    - Complete development setup (deploy tokens, contracts, create market)"
	@echo "  build                  - Build all Solidity contracts"
	@echo "  fork                   - Start Anvil fork for local development"
	@echo ""
	@echo "🚀 Deployment Commands:"
	@echo "  deploy-tokenA          - Deploy USDT mock token"
	@echo "  deploy-tokenB          - Deploy USDC mock token"
	@echo "  deploy                 - Deploy all core contracts"
	@echo "  read-deployment        - Read deployment information"
	@echo ""
	@echo "📊 Market Operations:"
	@echo "  create-market          - Create a new market"
	@echo "  pause-market           - Pause market operations"
	@echo "  add-liquidity          - Add liquidity to market"
	@echo "  remove-liquidity       - Remove liquidity from market"
	@echo "  swap                   - Execute a swap"
	@echo ""
	@echo "🔍 Quality & Security:"
	@echo "  install-deps           - Install project dependencies"
	@echo "  lint                   - Run linting checks"
	@echo "  lint-fix               - Fix linting issues"
	@echo "  format                 - Format code"
	@echo "  format-check           - Check code formatting"
	@echo "  security               - Run security analysis"
	@echo "  quality                - Run all quality checks (format, lint, security)"
	@echo ""
	@echo "⚙️  Configuration:"
	@echo "  MODE=LOCAL|REMOTE      - Set deployment mode (default: LOCAL)"
	@echo "  NETWORK=sepolia|arbitrum - Set target network (default: sepolia)"
	@echo ""
	@echo "💡 Examples:"
	@echo "  make help               - Show this help message"
	@echo "  make dev                - Complete development setup"
	@echo "  make fork               - Start local fork"
	@echo "  make NETWORK=arbitrum deploy - Deploy to Arbitrum mainnet"
	@echo "  make MODE=REMOTE deploy - Deploy to remote network"
	@echo ""
	@echo "📖 For more information, see the documentation in docs/"

# ==== Environment ====
export $(shell sed 's/=.*//' .env)
include .env
export

MODE ?= LOCAL
NETWORK ?= sepolia
ANVIL_PORT=8545
ANVIL_FORK_URL=http://localhost:$(ANVIL_PORT)
FORK_SOURCE_RPC ?= $(ARB_SEPOLIA_RPC_URL)

export NETWORK

# Network configuration
ifeq ($(NETWORK),sepolia)
	FORK_SOURCE_RPC=$(ARB_SEPOLIA_RPC_URL)
	RPC_URL=$(if $(filter $(MODE),LOCAL),$(ANVIL_FORK_URL),$(ARB_SEPOLIA_RPC_URL))
else ifeq ($(NETWORK),arbitrum)
	FORK_SOURCE_RPC=$(ARB_MAINNET_RPC_URL)
	RPC_URL=$(if $(filter $(MODE),LOCAL),$(ANVIL_FORK_URL),$(ARB_MAINNET_RPC_URL))
else ifeq ($(NETWORK),ethsepolia)
	FORK_SOURCE_RPC=$(ETH_SEPOLIA_RPC_URL)
	RPC_URL=$(if $(filter $(MODE),LOCAL),$(ANVIL_FORK_URL),$(ETH_SEPOLIA_RPC_URL))
else
	$(error Invalid NETWORK value: $(NETWORK). Must be either "sepolia" or "arbitrum")
endif

# VERIFY_FLAGS=$(if $(filter $(MODE),LOCAL),,--verify)
VERIFY_FLAGS="" # TODO: Solve etherscan issue.

FORGE=forge
SCRIPT_DIR=script
DEPLOYMENTS=deployments/$(NETWORK)_deployments.json

# === All ===

.PHONY: build deploy create-market

dev: deploy-tokenA deploy-tokenB deploy create-market

# === E2E FLOW ===
# !@deploy-tokenA Make sure to have some ETH and WETH in the attached wallet
# !@deploy-tokenB Make sure to have some USDC in the attached wallet
# !@fork Make sure the fork is running, it can be started with: make fork
e2e: deploy-tokenA deploy-tokenB deploy create-market add-liquidity swap #remove-liquidity

# === Build ===
build:
	$(FORGE) build

# === Fork ===
fork:
	@echo "⛽ Starting anvil forked from Network: $(NETWORK)..."
	anvil --fork-url $(FORK_SOURCE_RPC) --port $(ANVIL_PORT)
# --gas-limit 30000000 --block-time 1

# === Individual deployments ===
deploy-tokenA:
	$(FORGE) script $(SCRIPT_DIR)/dev/MockERC20.s.sol:TokenScriptUSDT \
		--rpc-url $(RPC_URL) \
		$(VERIFY_FLAGS) -vvv

deploy-tokenB:
	$(FORGE) script $(SCRIPT_DIR)/dev/MockERC20.s.sol:TokenScriptUSDC \
		--rpc-url $(RPC_URL) \
		$(VERIFY_FLAGS) -vvv

deploy:
	$(FORGE) script $(SCRIPT_DIR)/deploy/DeployLibraries.s.sol:DeployLibraries \
		--rpc-url $(RPC_URL) \
		-vvv
	$(FORGE) script $(SCRIPT_DIR)/deploy/DeployContracts.s.sol:DeployContracts \
		--rpc-url $(RPC_URL) \
		-vvv

read-deployment:
	$(FORGE) script $(SCRIPT_DIR)/ReadDeployment.s.sol \
		--rpc-url $(RPC_URL) \
		$(VERIFY_FLAGS) -vvv

create-market:
	$(FORGE) script $(SCRIPT_DIR)/CreateMarket.s.sol \
		--rpc-url $(RPC_URL) \
		-vvv

pause-market:
	$(FORGE) script $(SCRIPT_DIR)/PauseMarket.s.sol \
		--rpc-url $(RPC_URL) \
		-vvv

transfer-ownership:
	$(FORGE) script $(SCRIPT_DIR)/TransferOwnership.s.sol \
		--rpc-url $(RPC_URL) \
		-vvv

add-liquidity:
	$(FORGE) script $(SCRIPT_DIR)/AddLiquidity.s.sol \
		--rpc-url $(RPC_URL) \
		-vvv

remove-liquidity:
	$(FORGE) script $(SCRIPT_DIR)/RemoveLiquidity.s.sol \
		--rpc-url $(RPC_URL) \
		-vvv

swap:
	$(FORGE) script $(SCRIPT_DIR)/SwapV4.s.sol \
		--rpc-url $(RPC_URL) \
		-vvv

unwrap-all:
	$(FORGE) script $(SCRIPT_DIR)/UnwrapLCC.s.sol \
		--rpc-url $(RPC_URL) \
		-vvv

# Linting and Formatting
.PHONY: install-deps lint lint-fix format format-check

install-deps:
	pnpm install

lint:
	pnpm run lint

lint-fix:
	pnpm run lint:fix

format:
	pnpm run format

format-check:
	pnpm run format:check

# Security analysis
security:
	pnpm run security

# Combined quality check
quality: format-check lint security

# === CLI: Read proxy PoolId from Core PoolId ===
core-to-proxy: ## Usage: make core-to-proxy CORE_POOL_ID=0x...
	@if [ -z "$(CORE_POOL_ID)" ]; then \
		echo "Usage: make core-to-proxy CORE_POOL_ID=0x<core_pool_id> [NETWORK=sepolia|arbitrum|ethsepolia]"; \
		exit 1; \
	fi
	@ADDRESS=$$(jq -r '.marketFactory' $(DEPLOYMENTS)); \
	echo "Reading coreToProxy for CORE_POOL_ID=$(CORE_POOL_ID) on $(NETWORK) via $$ADDRESS"; \
	cast call $$ADDRESS "coreToProxy(bytes32)(bytes32)" $(CORE_POOL_ID) --rpc-url $(RPC_URL)

proxy-to-hook: ## Usage: make proxy-to-hook PROXY_POOL_ID=0x...
	@if [ -z "$(PROXY_POOL_ID)" ]; then \
		echo "Usage: make proxy-to-hook PROXY_POOL_ID=0x<proxy_pool_id> [NETWORK=sepolia|arbitrum|ethsepolia]"; \
		exit 1; \
	fi
	@ADDRESS=$$(jq -r '.marketFactory' $(DEPLOYMENTS)); \
	echo "Reading proxyToHook for PROXY_POOL_ID=$(PROXY_POOL_ID) on $(NETWORK) via $$ADDRESS"; \
	cast call $$ADDRESS "proxyToHook(bytes32)(address)" $(PROXY_POOL_ID) --rpc-url $(RPC_URL)