export $(shell sed 's/=.*//' .env)
include .env
export

include make/help.mk
include make/exp.mk

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

.PHONY: build deploy create-market

# === Experimental Commands Subcommand ===
# This allows running experimental commands via: make exp <command>
exp-%: ## Run experimental command (usage: make exp <command>)
	@$(MAKE) exp-$(subst exp-,,$@)

# === All ===
dev: deploy-tokenA deploy-tokenB deploy create-market

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
		--broadcast $(VERIFY_FLAGS) -vvv

deploy-tokenB:
	$(FORGE) script $(SCRIPT_DIR)/dev/MockERC20.s.sol:TokenScriptUSDC \
		--rpc-url $(RPC_URL) \
		--broadcast $(VERIFY_FLAGS) -vvv

deploy:
	$(FORGE) script $(SCRIPT_DIR)/DeployComplete.s.sol \
		--rpc-url $(RPC_URL) \
		--broadcast -vvv

deploy-verify:
	$(FORGE) script $(SCRIPT_DIR)/DeployComplete.s.sol \
		--rpc-url $(RPC_URL) \
		--verify -vvv

read-deployment:
	$(FORGE) script $(SCRIPT_DIR)/ReadDeployment.s.sol \
		--rpc-url $(RPC_URL) \
		--broadcast $(VERIFY_FLAGS) -vvv

create-market:
	$(FORGE) script $(SCRIPT_DIR)/CreateMarket.s.sol \
		--rpc-url $(RPC_URL) \
		--broadcast -vvv

pause-market:
	$(FORGE) script $(SCRIPT_DIR)/PauseMarket.s.sol \
		--rpc-url $(RPC_URL) \
		--broadcast -vvv

transfer-ownership:
	$(FORGE) script $(SCRIPT_DIR)/TransferOwnership.s.sol \
		--rpc-url $(RPC_URL) \
		--broadcast -vvv

add-liquidity:
	$(FORGE) script $(SCRIPT_DIR)/AddLiquidity.s.sol \
		--rpc-url $(RPC_URL) \
		--broadcast -vvv

remove-liquidity:
	$(FORGE) script $(SCRIPT_DIR)/RemoveLiquidity.s.sol \
		--rpc-url $(RPC_URL) \
		--broadcast -vvv

swap:
	$(FORGE) script $(SCRIPT_DIR)/SwapV4.s.sol \
		--rpc-url $(RPC_URL) \
		--broadcast -vvv

unwrap-all:
	$(FORGE) script $(SCRIPT_DIR)/UnwrapLCC.s.sol \
		--rpc-url $(RPC_URL) \
		--broadcast -vvv

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