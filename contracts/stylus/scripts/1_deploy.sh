#!/bin/bash

# ------------- #
# Configuration #
# ------------- #

# Load variables from .env file
set -o allexport
source .env
set +o allexport


# Helper constants
FILE_KEY="deployed_contract_address"
ABI_NAME="abi.sol"

# -------------- #
# Initial checks #
# -------------- #

# checks to make sure that the environment variables are set
if [ -z "$PRIVATE_KEY" ] || [ -z "$ADDRESS" ]
then
    echo "You need to provide the PRIVATE_KEY and the ADDRESS of the deployer"
    exit 0
fi

# ---------------------------------- #
# Deployment of VRL Manager #
# ---------------------------------- #
echo ""
echo "------------------------------ #"
echo "Deploying VRL Manager          #"
echo "--------------delta_manager---------------- #"

# Move to vrl manager folder
cd ./vrl_manager

# Deploy contract
cargo stylus deploy -e $RPC_URL --private-key $PRIVATE_KEY --no-verify | sed 's/[^a-zA-Z0-9 ]//g' | grep 'deployed code' | grep -oP '0x[0-9a-fA-F]{40}' > $FILE_KEY
cargo stylus export-abi > $ABI_NAME

# reset directory
cd ..


# ---------------------------------- #
# Deployment of Liquidity Verifier   #
# ---------------------------------- #
echo ""
echo "------------------------------ #"
echo "Deploying Liquidity Verifier   #"
echo "------------------------------ #"

# Move to liquidity verifier folder
cd ./liquidity_verifier

# deploy contract
cargo stylus deploy -e $RPC_URL --private-key $PRIVATE_KEY --no-verify | sed 's/[^a-zA-Z0-9 ]//g' | grep 'deployed code' | grep -oP '0x[0-9a-fA-F]{40}' > $FILE_KEY
cargo stylus export-abi > $ABI_NAME

# reset directory
cd ..


# ---------------------------------- #
# Deployment of FIET$ Token           #
# ---------------------------------- #
echo ""
echo "------------------------------ #"
echo "Deploying FIET$ Token          #"
echo "------------------------------ #"

# Move to liquidity verifier folder
cd ./token

# deploy contract
cargo stylus deploy -e $RPC_URL --private-key $PRIVATE_KEY --no-verify | sed 's/[^a-zA-Z0-9 ]//g' | grep 'deployed code' | grep -oP '0x[0-9a-fA-F]{40}' > $FILE_KEY
cargo stylus export-abi > $ABI_NAME

# reset directory
cd ..

# ---------------------------------- #
# Deployment of Staking Contract     #
# ---------------------------------- #
echo ""
echo "------------------------------ #"
echo "Deploying Staking Contract     #"
echo "------------------------------ #"

# Move to liquidity verifier folder
cd ./fiet_stake

# deploy contract
cargo stylus deploy -e $RPC_URL --private-key $PRIVATE_KEY --no-verify | sed 's/[^a-zA-Z0-9 ]//g' | grep 'deployed code' | grep -oP '0x[0-9a-fA-F]{40}' > $FILE_KEY
cargo stylus export-abi > $ABI_NAME

# reset directory
cd ..


# ---------------------------------- #
# Deployment of Delta Manager        #
# ---------------------------------- #
echo ""
echo "------------------------------ #"
echo "Deploying Delta Manager        #"
echo "------------------------------ #"

# Move to liquidity verifier folder
cd ./delta_manager

# deploy contract
cargo stylus deploy -e $RPC_URL --private-key $PRIVATE_KEY --no-verify | sed 's/[^a-zA-Z0-9 ]//g' | grep 'deployed code' | grep -oP '0x[0-9a-fA-F]{40}' > $FILE_KEY
cargo stylus export-abi > $ABI_NAME

# reset directory
cd ..

# ---------------------------------- #
# Deployment of Settlement Manager   #
# ---------------------------------- #
echo ""
echo "------------------------------ #"
echo "Deploying Settlement Manager   #"
echo "------------------------------ #"

# Move to liquidity verifier folder
cd ./settlement_manager

# deploy contract
cargo stylus deploy -e $RPC_URL --private-key $PRIVATE_KEY --no-verify | sed 's/[^a-zA-Z0-9 ]//g' | grep 'deployed code' | grep -oP '0x[0-9a-fA-F]{40}' > $FILE_KEY
cargo stylus export-abi > $ABI_NAME

# reset directory
cd ..
