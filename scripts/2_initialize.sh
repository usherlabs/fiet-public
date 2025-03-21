#!/bin/bash

# ------------- #
# Configuration #
# ------------- #

# Load variables from .env file
set -o allexport
source scripts/.env
set +o allexport


# Helper constants
FILE_KEY="deployed_contract_address"

# Read in contract addresses
VRL_MANAGER_ADDRESS=$(cat "stylus/vrl_manager/$FILE_KEY")
LIQUIDITY_VERIFIER_ADDRESS=$(cat "stylus/liquidity_verifier/$FILE_KEY")
FIET_TOKEN_ADDRESS=$(cat "stylus/token/$FILE_KEY")

# -------------- #
# Initial checks #
# -------------- #

# checks to make sure that the environment variables are set
if [ -z "$PRIVATE_KEY" ] || [ -z "$ADDRESS" ]
then
    echo "You need to provide the PRIVATE_KEY and the ADDRESS of the deployer"
    exit 0
fi

if [ -z "$VRL_MANAGER_ADDRESS" ] || [ -z "$LIQUIDITY_VERIFIER_ADDRESS" ] || [ -z "$FIET_TOKEN_ADDRESS" ]

then
    echo "You need to provide the contract addresses by running the script 'bash 1_deploy.sh'"
    exit 0
fi

# -------------------------------#
# initialization of VRL Manager  #
# -------------------------------#
echo ""
echo "------------------------------------ #"
echo "initialising VRL Manager contract    #"
echo "------------------------------------ #"

# define deployment variables
UNI_HOOK_ADDRESS=$ADDRESS
VRL_DECIMALS="6"
cast send --rpc-url $RPC_URL --private-key $PRIVATE_KEY $VRL_MANAGER_ADDRESS "initialize(address, address, uint256)" "$LIQUIDITY_VERIFIER_ADDRESS" "$UNI_HOOK_ADDRESS" "$VRL_DECIMALS"


# ----------------------------------------- #
# initialization of Liquidity Verifier      #
# ----------------------------------------- #
echo ""
echo "-------------------------------------------- #"
echo "initialising Liquidity Verifier contract     #"
echo "-------------------------------------------- #"

cast send --rpc-url $RPC_URL --private-key $PRIVATE_KEY $LIQUIDITY_VERIFIER_ADDRESS "initialize(address)" "$VRL_MANAGER_ADDRESS"


# ----------------------------------------- #
# initialization of FIET Token Contract     #
# ----------------------------------------- #
echo ""
echo "-------------------------------------------- #"
echo "initialising Fiet Token contract             #"
echo "-------------------------------------------- #"

cast send --rpc-url $RPC_URL --private-key $PRIVATE_KEY $FIET_TOKEN_ADDRESS "initialize()"
