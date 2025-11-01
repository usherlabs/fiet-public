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

# Read in contract addresses
VRL_MANAGER_ADDRESS=$(cat "../vrl_manager/$FILE_KEY")
LIQUIDITY_VERIFIER_ADDRESS=$(cat "../liquidity_verifier/$FILE_KEY")
FIET_TOKEN_ADDRESS=$(cat "../token/$FILE_KEY")
FIET_STAKING_ADDRESS=$(cat "../fiet_stake/$FILE_KEY")
DELTA_MANAGER_ADDRESS=$(cat "../delta_manager/$FILE_KEY")
SETTLEMENT_MANAGER=$(cat "../settlement_manager/$FILE_KEY")

# For dev/testing purposes, this should be set to this value
# as it is what is generated on the random wallet generator
# using the seed  
UNISWAP_HOOK_CONTRACT="0x25858b08541cbc24285717c2f8feab53080b1aec"

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
UNI_HOOK_ADDRESS=$UNISWAP_HOOK_CONTRACT
VRL_DECIMALS="6"
cast send --rpc-url $RPC_URL --private-key $PRIVATE_KEY $VRL_MANAGER_ADDRESS "initialize(address, address, address, uint256)" "$LIQUIDITY_VERIFIER_ADDRESS" "$DELTA_MANAGER_ADDRESS" "$UNI_HOOK_ADDRESS" "$VRL_DECIMALS"


# ----------------------------------------- #
# initialization of Liquidity Verifier      #
# ----------------------------------------- #
echo ""
echo "-------------------------------------------- #"
echo "initialising Liquidity Verifier contract     #"
echo "-------------------------------------------- #"

cast send --rpc-url $RPC_URL --private-key $PRIVATE_KEY $LIQUIDITY_VERIFIER_ADDRESS "initialize(address, address)" "$VRL_MANAGER_ADDRESS" "$DELTA_MANAGER_ADDRESS"


# ----------------------------------------- #
# initialization of FIET Token Contract     #
# ----------------------------------------- #
echo ""
echo "-------------------------------------------- #"
echo "initialising Fiet Token contract             #"
echo "-------------------------------------------- #"

cast send --rpc-url $RPC_URL --private-key $PRIVATE_KEY $FIET_TOKEN_ADDRESS "initialize()"

# ----------------------------------------- #
# initialization of FIET Staking Contract     #
# ----------------------------------------- #
echo ""
echo "-------------------------------------------- #"
echo "initialising Fiet Staking contract           #"
echo "-------------------------------------------- #"

MIN_STAKE=1000000000000000000 #10e18
cast send --rpc-url $RPC_URL --private-key $PRIVATE_KEY $FIET_STAKING_ADDRESS "initialize(address, address, address, uint256)" "$FIET_TOKEN_ADDRESS" "$DELTA_MANAGER_ADDRESS" "$SETTLEMENT_MANAGER" "$MIN_STAKE"

# ------------------------------------------------ #
# initialization of the Delta Manager Contract     #
# ------------------------------------------------ #
echo ""
echo "-------------------------------------------- #"
echo "initialising the Delta Manager Contract      #"
echo "-------------------------------------------- #"

cast send --rpc-url $RPC_URL --private-key $PRIVATE_KEY $DELTA_MANAGER_ADDRESS "initialize(address, address, address, address)" "$LIQUIDITY_VERIFIER_ADDRESS" "$FIET_STAKING_ADDRESS" "$VRL_MANAGER_ADDRESS" "$SETTLEMENT_MANAGER"

# ------------------------------------------------ #
# initialization of the Settlement Manager Contract     #
# ------------------------------------------------ #
echo ""
echo "-------------------------------------------- #"
echo "initialising the Settlement Manager Contract      #"
echo "-------------------------------------------- #"

TTL_IN_HOURS=24
cast send --rpc-url $RPC_URL --private-key $PRIVATE_KEY $SETTLEMENT_MANAGER "initialize(address, address, uint64)" "$DELTA_MANAGER_ADDRESS" "$FIET_STAKING_ADDRESS" "$TTL_IN_HOURS"
