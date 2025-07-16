# Additional commands that can be included in the main Makefile
# This file contains utility commands and helper functions

# === Utility Commands ===
.PHONY: help clean-all check-env

help:
	@echo "Available commands:"
	@echo "  build          - Build contracts"
	@echo "  deploy         - Deploy all contracts"
	@echo "  create-market  - Create new market"
	@echo "  fork           - Start local fork"
	@echo "  dev            - Full development setup"
	@echo "  quality        - Run all quality checks"
	@echo ""
	@echo "Network options:"
	@echo "  NETWORK=sepolia  - Use Sepolia testnet"
	@echo "  NETWORK=arbitrum - Use Arbitrum mainnet"
	@echo ""
	@echo "Mode options:"
	@echo "  MODE=LOCAL     - Use local fork"
	@echo "  MODE=REMOTE    - Use remote RPC"

clean-all:
	@echo "🧹 Cleaning all build artifacts..."
	$(FORGE) clean
	rm -rf cache/
	rm -rf out/
	rm -rf deployments/

check-env:
	@echo "🔍 Checking environment variables..."
	@if [ -z "$(PRIVATE_KEY)" ]; then \
		echo "❌ PRIVATE_KEY not set"; \
		exit 1; \
	fi
	@if [ -z "$(ARB_SEPOLIA_RPC_URL)" ]; then \
		echo "❌ ARB_SEPOLIA_RPC_URL not set"; \
		exit 1; \
	fi
	@echo "✅ Environment variables OK"

# === Network-specific commands ===
.PHONY: deploy-sepolia deploy-arbitrum

deploy-sepolia:
	NETWORK=sepolia make deploy

deploy-arbitrum:
	NETWORK=arbitrum make deploy

# === Development helpers ===
.PHONY: setup-dev reset-dev

setup-dev:
	@echo "🚀 Setting up development environment..."
	make check-env
	make build
	make fork &
	@sleep 3
	make dev MODE=LOCAL

reset-dev:
	@echo "🔄 Resetting development environment..."
	make clean-all
	make setup-dev 