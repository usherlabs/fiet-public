# !/bin/bash
##### This script will deploy the contracts to the provided($1) network #####
# @dev:  sh ./deploy.sh development

# Copy the modified hardhat.config.ts to the oracle directory
cp ./hardhat.custom.config.ts ./oracle/hardhat.config.ts

# navigate into the oracle directory
cd oracle

# install dependencies
yarn install

# @dev: We could potentially load environment variables here
# @dev: However we are choosing to use the same env file as in the root directory

# command to deploy the contracts to a particular network, the output will be saved in the deployments directory(/contracts/evm/deployments/oracle_deployments/<$1)
# @dev: $1 is the network name provided via the command line e.g development, sepolia, arbitrumsepolia, arbitrumone
# @dev: --tags deploy is the tag of the deployment script
# @dev: --reset is the reset flag to force a new deployment regardless of the cache
npx hardhat deploy --network $1 --tags deploy --reset