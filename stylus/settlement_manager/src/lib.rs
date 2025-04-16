//! SettlementManager - VRL-Based Settlement Engine for Fiet Protocol
//!
//! This contract finalizes settlement between LPs and custodians by burning VRL and
//! zeroing out deltas. Deployed on Arbitrum Stylus, it works alongside DeltaManager
//! and VRLManager to ensure accurate and trust-minimized resolution of obligations.
//
// This contract is responsible for:
// - Settling deltas between participants using VRL tokens
// - Burning VRL from the payer and reducing delta for the counterparty
// - Ensuring delta sums remain zero-sum after settlement
// - Verifying permissions and sufficient VRL balances via VRLManager
//
// Settlement is permissioned and atomic—ensuring that no delta is cleared
// without an equivalent VRL burn, maintaining integrity of the protocol’s accounting.

#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloy_primitives::{Address, I256, U64, U8};
use alloy_sol_types::sol;
use fiet_library::core::RFSStage;
use stylus_sdk::{alloy_primitives::U256, prelude::*};

sol_interface! {
    interface IDeltaManager{
        function getCurrencySignalledParticipants(bytes32 currency_hash) external returns (address[] memory);
        function currencyHashOfParticipant(address owner) external returns (bytes32);
        function deltaOfParticipant(address owner) external returns (int256);
        function adminSettleDelta(uint256 amount, address user) external;
    }

    interface IFietStake{
        function getStakedToken() external returns (address);
        function slashByAmount(address owner, uint256 target_amount, uint64 slash_factor) external;
    }

    interface IErc20  {
        function transferFrom(address from, address to, uint256 value) external returns (bool);
        function approve(address spender, uint256 value) external returns (bool);
    }
}

sol! {
    event RFSCreated(address indexed owner, uint64 indexed rfs_id, uint64 ttl);
    event RFSBid(uint64 indexed rfs_id, address indexed bidder, uint256 amount);
    event RFSClosed(address indexed owner, uint64 indexed rfs_id);
}

sol_storage! {
    #[entrypoint]
    pub struct Settlement {
        uint64 ttl;
        uint64 num_rfs;
        address owner;
        mapping(address => uint64) active_rfs;
        mapping(uint64 => RFS) settlement_requests;
        bool initialized;
        Contracts contracts;
    }

    pub struct Contracts{
        address delta_manager;
        address stake_manager;
    }


// the stage of the RFS
// 0 means unintiialized
// 1 means bidding has started
// 2 means settlement has started
// 3 means complete
// 4 means expired or failed
    pub struct RFS {
        uint8 stage;
        uint64 index;
        uint64 timestamp;
        address owner;
        uint256 amount;
        uint256 total_bid;
        address[] participants;
        mapping(address => uint256) bids;
        mapping(address => bool) settled;
        mapping(address => uint64) slash_tiers;
    }
}

#[public]
impl Settlement {
    /// Initializes the Settlement contract with core dependencies and configuration.
    ///
    /// This function sets up the DeltaManager and StakeManager contract addresses, TTL (time-to-live) for each RFS,
    /// and marks the contract as initialized. It also sets the contract owner and prepares the first RFS index.
    ///
    /// # Arguments
    /// * `delta_manager` - Address of the deployed DeltaManager contract.
    /// * `stake_manager` - Address of the deployed FietStake contract.
    /// * `ttl` - The number of hours each RFS remains valid (time-to-live).
    ///
    /// # Returns
    /// * `Ok(())` if the contract is successfully initialized.
    /// * `Err(Vec<u8>)` if the contract has already been initialized.
    ///
    /// # Notes
    /// - This function can only be called once; subsequent calls will fail.
    pub fn initialize(
        &mut self,
        delta_manager: Address,
        stake_manager: Address,
        ttl: U64,
    ) -> Result<(), Vec<u8>> {
        // make sure the contract is not initialized yet
        if self.initialized.get() {
            return Err("ALREADY_INITIALIZED".into());
        };

        // initialize important variables
        self.contracts.delta_manager.set(delta_manager);
        self.contracts.stake_manager.set(stake_manager);

        // set the initialized value to be true to prevent another reinitialization
        self.initialized.set(true);

        // set the owner of the contract
        self.owner.set(self.vm().msg_sender());
        self.ttl.set(ttl);

        // initialize the rfc index to 1
        // i.e the first RFS will have an id of one and increment accordingly
        self.num_rfs.set(U64::from(1));

        return Ok(());
    }

    /// Creates a new Request For Settlement (RFS) for the caller.
    ///
    /// This function allows a participant with a valid, positive delta to initiate a new settlement request.
    /// It ensures the participant has no other active RFS and that the settle amount is within their current delta.
    /// Upon success, it logs the creation and tracks the RFS state.
    ///
    /// # Arguments
    /// * `settle_amount` - The unsigned delta amount the participant wants to settle.
    ///
    /// # Returns
    /// * `Ok(())` if the RFS is successfully created.
    /// * `Err(Vec<u8>)` if the participant has an active RFS or the settle amount is invalid.
    ///
    /// # Notes
    /// - Each participant can only have one active RFS at a time.
    /// - The settle amount must be positive and not exceed the participant's delta.
    pub fn create_request_for_settlement(&mut self, settle_amount: U256) -> Result<(), Vec<u8>> {
        let index = self.num_rfs.get();
        let ttl = self.ttl.get();

        let sender = self.vm().msg_sender();
        let timestamp = self.vm().block_timestamp();

        let delta_manager = IDeltaManager::new(self.contracts.delta_manager.get());

        // make sure this sender does not have an active RFS
        let active_rfs = self.active_rfs.get(sender);
        if active_rfs != U64::ZERO {
            return Err("USER HAS ACTIVE RFS".into());
        }

        // make sure the sender has sufficient delta
        let signed_settle_amount = I256::try_from(settle_amount).unwrap();
        let participant_delta = delta_manager.delta_of_participant(&mut *self, sender)?;
        let currency_hash = delta_manager.currency_hash_of_participant(&mut *self, sender)?;

        if signed_settle_amount > participant_delta || signed_settle_amount <= I256::ZERO {
            return Err("INVALID DELTA AMOUNT".into());
        }

        // get all the participants as at the time of initiating
        let rfs_participants =
            delta_manager.get_currency_signalled_participants(&mut *self, currency_hash)?;

        // Create a new RFS instance
        let mut rfs_setter = self.settlement_requests.setter(index);

        // set the index and owner and amount
        rfs_setter.index.set(index);
        rfs_setter.owner.set(sender);
        rfs_setter.amount.set(settle_amount);
        rfs_setter.participants.extend(rfs_participants);

        // set all the participants
        rfs_setter.stage.set(U8::from(RFSStage::BIDDING.as_u8()));
        rfs_setter.timestamp.set(U64::from(timestamp));

        // create mapping for who has an active rfs ongoing to prevent creating multiple at a go
        self.active_rfs.setter(sender).set(index);
        self.num_rfs.set(index + U64::from(1));

        log(
            self.vm(),
            RFSCreated {
                owner: sender,
                rfs_id: index.try_into().unwrap(),
                ttl: ttl.try_into().unwrap(),
            },
        );

        return Ok(());
    }

    /// Allows a participant to place a bid on an active RFS (Request For Settlement)
    ///
    /// # Arguments
    /// * `rfs_id` - The ID of the RFS to bid on
    /// * `amount` - The amount the participant wants to bid
    ///
    /// # Requirements
    /// * RFS must exist and be in the BIDDING stage
    /// * The RFS must not be expired (more than 3 bid rounds elapsed)
    /// * The bidder and the RFS owner must have the same currency hash
    ///
    /// # Behavior
    /// * Records the user's bid amount
    /// * Tracks the round in which the user bid (for slashing tiers)
    /// * If the total bid amount reaches the target, moves the RFS to SETTLEMENT stage
    ///
    /// # Errors
    /// * `"CANNOT BID IN THIS STAGE"` - If bidding is not allowed due to stage or timeout
    /// * `"INVALID CURRENCY"` - If the bidder is using a different currency than the RFS
    pub fn bid(&mut self, rfs_id: U64, amount: U256) -> Result<(), Vec<u8>> {
        let max_bid_rounds = U64::from(3);
        let caller = self.vm().msg_sender();
        let rfs_owner = self.settlement_requests.get(rfs_id).owner.get();

        // get currency hashes of participants
        let delta_manager = IDeltaManager::new(self.contracts.delta_manager.get());
        let rfs_currency_hash =
            delta_manager.currency_hash_of_participant(&mut *self, rfs_owner)?;
        let bidder_currency_hash =
            delta_manager.currency_hash_of_participant(&mut *self, caller)?;

        let rfs_getter = self.settlement_requests.get(rfs_id);
        let updated_total_bid = rfs_getter.total_bid.get() + amount;
        let rfs_amount = rfs_getter.amount.get();
        let user_bid = rfs_getter.bids.get(caller);

        // validate the stage
        if rfs_getter.stage.get() != U8::from(RFSStage::BIDDING.as_u8()) {
            return Err("CANNOT BID IN THIS STAGE".into());
        }

        let rfs_start_ts = rfs_getter.timestamp.get();
        let bid_rounds_elapsed = self.hours_elapsed_since(rfs_start_ts);

        let mut rfs_setter = self.settlement_requests.setter(rfs_id);

        // if one round lasts an hour and we have a maximum of three rounds
        if bid_rounds_elapsed > max_bid_rounds {
            rfs_setter.stage.set(U8::from(RFSStage::EXPIRED.as_u8()));
            return Err("CANNOT BID IN THIS STAGE".into());
        }

        // check if the bidder and the rfs have the same currency
        if bidder_currency_hash != rfs_currency_hash {
            return Err("INVALID CURRENCY".into());
        }

        // store bid since both bidder and RFS are valid
        // if bid completes change status to enable settlement
        rfs_setter.bids.setter(caller).set(user_bid + amount);
        rfs_setter.total_bid.set(updated_total_bid);

        // store when this bidder made a bid to know how much to slash
        rfs_setter
            .slash_tiers
            .setter(caller)
            .set(bid_rounds_elapsed);
        if updated_total_bid >= rfs_amount {
            rfs_setter.stage.set(U8::from(RFSStage::SETTLEMENT.as_u8()));
        }

        return Ok(());
    }

    /// Settles a participant's bid in a completed RFS (Request For Settlement)
    ///
    /// # Arguments
    /// * `rfs_id` - The ID of the RFS being settled
    ///
    /// # Requirements
    /// * RFS must be in the SETTLEMENT stage
    /// * Caller must be a bidder in the RFS
    /// * Settlement must occur within the configured TTL window
    ///
    /// # Behavior
    /// * Marks the caller as settled for this RFS
    /// * Calls the DeltaManager to burn VRL and clear the participant's delta
    ///
    /// # Errors
    /// * `"CANNOT BID IN THIS STAGE"` - If RFS is not in SETTLEMENT stage
    /// * `"EXPIRED"` - If the TTL (settlement window) has passed
    /// * `"NONE BIDDER"` - If caller did not place a bid on this RFS
    pub fn settle(&mut self, rfs_id: U64) -> Result<(), Vec<u8>> {
        let delta_manager_contract = IDeltaManager::new(self.contracts.delta_manager.get());
        let rfs_getter = self.settlement_requests.get(rfs_id);
        let rfs_ttl = self.ttl.get();
        let caller = self.vm().msg_sender();

        if rfs_getter.stage.get() != U8::from(RFSStage::SETTLEMENT.as_u8()) {
            return Err("CANNOT BID IN THIS STAGE".into());
        }

        let hours_elapsed = self.hours_elapsed_since(rfs_getter.timestamp.get());

        // make sure this is within a 24hour window
        // ttl can be set to any hours but standard used was 24 hours
        if hours_elapsed > rfs_ttl {
            return Err("EXPIRED".into());
        }

        let bid_amount = rfs_getter.bids.get(caller);
        if bid_amount == U256::ZERO {
            return Err("NONE BIDDER".into());
        }

        let mut rfs_setter = self.settlement_requests.setter(rfs_id);
        rfs_setter.settled.setter(caller).set(true);

        // settle the vrl aginst the delta i.e make the call to burn VRL to clear up their delta by the amount
        delta_manager_contract.admin_settle_delta(&mut *self, bid_amount, caller)?;
        return Ok(());
    }

    /// Closes an active Request For Settlement (RFS) for the sender and applies penalties
    ///
    /// # Requirements
    /// * Sender must have an active RFS
    ///
    /// # Behavior
    /// * Iterates through all participants of the RFS
    /// * Calculates a `slash_factor` based on:
    ///     - Bidding too late (or not bidding)
    ///     - Not settling after bidding
    /// * Slashes each participant proportionally to their `slash_factor`
    /// * Marks the RFS as closed
    /// * Resets the sender's active RFS
    ///
    /// # Errors
    /// * `"NO ACTIVE RFS"` - If sender does not currently have an active RFS
    ///
    /// # Notes
    /// * Slash factor increases for zero bids and unfulfilled settlements
    /// * Slash is enforced using `IFietStake::slash_by_amount`
    pub fn close_request_for_settlement(&mut self) -> Result<(), Vec<u8>> {
        let sender = self.vm().msg_sender();

        // get the active rfs for this sender
        let active_rfs_id = self.get_active_rfs(self.vm().msg_sender());
        if active_rfs_id == U64::ZERO {
            return Err("NO ACTIVE RFS".into());
        }

        let fiet_stake = IFietStake::new(self.contracts.stake_manager.get());

        // get participants who did not stake and slash their funds
        let rfs_amount = self.settlement_requests.get(active_rfs_id).amount.get();
        let num_rfs_participants = self
            .settlement_requests
            .get(active_rfs_id)
            .participants
            .len();

        // TODO: maybe only slash if the target was not met?
        // get participants who bid zero and slash
        for participant_index in 0..num_rfs_participants {
            let rfs_getter = self.settlement_requests.get(active_rfs_id);
            // get this participant
            let participant = rfs_getter.participants.get(participant_index).unwrap();

            // get their slash tier
            let bid_slash_tier = rfs_getter.slash_tiers.get(participant);

            // check their bid which goes higher the later the bid is placed
            // it is a numerical number ranging from 0 upwards in increments of one
            let participant_settled = rfs_getter.settled.get(sender);
            let participant_bid = rfs_getter.bids.get(participant);
            let mut slash_factor = bid_slash_tier;

            // ----- Increment the slash factor based on several criteria
            // if participant did not bid at all, increment the slash tier by 4,
            // since there are 3 rounds, the max fee tier for the lattest bidder is 3 so we go higher by 1 giving 4
            if participant_bid == U256::from(0) {
                slash_factor += U64::from(4);
            }
            // if participant did not settle, increase factor by 1
            if !participant_settled {
                slash_factor += U64::from(1);
            }

            // if there is a slash factor, that means the participant must have done at least one of the following
            // bid late or not at all
            // bid and not settled or not at all
            // and the more they are guilty of, the higher the factor,
            if slash_factor > U64::ZERO {
                // slash them by the determined amount
                fiet_stake.slash_by_amount(
                    &mut *self,
                    participant,
                    rfs_amount,
                    slash_factor.try_into().unwrap(),
                )?;
            }
        }

        // get the rfs and mark it as closed
        let mut rfs_setter = self.settlement_requests.setter(active_rfs_id);
        rfs_setter.stage.set(U8::from(RFSStage::CLOSED.as_u8()));
        self.active_rfs.setter(sender).set(U64::ZERO);

        // log related event
        log(
            self.vm(),
            RFSClosed {
                owner: sender,
                rfs_id: active_rfs_id.try_into().unwrap(),
            },
        );

        return Ok(());
    }

    /// Returns the active RFS ID for a given user address
    pub fn hours_elapsed_since(&self, start_timestamp: U64) -> U64 {
        let current_timestamp = U64::from(self.vm().block_timestamp());
        let hours_elapsed = (current_timestamp - start_timestamp) / U64::from(3600);

        return hours_elapsed;
    }

    /// Returns the active RFS ID for a given user address
    pub fn get_active_rfs(&self, owner: Address) -> U64 {
        return self.active_rfs.get(owner);
    }
}
