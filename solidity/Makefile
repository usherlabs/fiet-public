export $(shell sed 's/=.*//' .env)
include .env
export

MODE ?= live
ANVIL_PORT=8545
ANVIL_FORK_URL=http://localhost:$(ANVIL_PORT)
RPC_URL=$(if $(filter $(MODE),local),$(ANVIL_FORK_URL),$(ARB_SEPOLIA_RPC_URL))
VERIFY_FLAGS=$(if $(filter $(MODE),local),,--verify)
ETHERSCAN_KEY=${ETHERSCAN_API_KEY}

FORGE=forge
SCRIPT_DIR=script
DEPLOYMENTS=$(SCRIPT_DIR)/deployments/deployments.json

	
.PHONY: all build clean fork \
	deploy-tokenB deploy-lccTokenA deploy-lccTokenB deploy-proxyHook deploy-corePool deploy-proxyPool \

# === All ===
all: build deploy-tokenB deploy-lccTokenB deploy-lccTokenA deploy-proxyHook deploy-corePool deploy-proxyPool

# === Build ===
build:
	$(FORGE) build

# === Fork ===
fork:
	@echo "⛽ Starting anvil forked from Arbitrum Sepolia..."
	anvil --fork-url $(ARB_SEPOLIA_RPC_URL) --port $(ANVIL_PORT)

# === Clean ===
build:
	$(FORGE) clean

# === USDC already deployed on Arbitrum Sepolia

# === Individual deployments ===
deploy-tokenB:
	$(FORGE) script $(SCRIPT_DIR)/MockERC20script.s.sol:TokenScript \
		--rpc-url $(RPC_URL) \
		--broadcast $(VERIFY_FLAGS) -vvv

# === lcc USDC ===
deploy-lccTokenA:
	$(FORGE) script $(SCRIPT_DIR)/MockERC20script.s.sol:ITokenUSDCScript \
		--rpc-url $(RPC_URL) \
		--broadcast $(VERIFY_FLAGS) -vvv

# === lcc USDT ===
deploy-lccTokenB:
	$(FORGE) script $(SCRIPT_DIR)/MockERC20script.s.sol:ITokenUSDTScript \
		--rpc-url $(RPC_URL) \
		--broadcast $(VERIFY_FLAGS) -vvv

# === Proxy hook ===
deploy-proxyHook:
	$(FORGE) script $(SCRIPT_DIR)/ProxyHookScript.s.sol \
		--rpc-url $(RPC_URL) \
		--broadcast $(VERIFY_FLAGS) -vvv

# === Core Pool: lcc USDT/USDC ===
deploy-corePool:
	$(FORGE) script $(SCRIPT_DIR)/UniSwapV4PoolScript.s.sol:CorePoolScript \
		--rpc-url $(RPC_URL) \
		--broadcast -vvv

# === Proxy Pool: USDT/USDC ===
deploy-proxyPool:
	$(FORGE) script $(SCRIPT_DIR)/UniSwapV4PoolScript.s.sol:ProxyPoolScript \
		--rpc-url $(RPC_URL) \
		--broadcast -vvv