#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloy_primitives::Address;
use alloy_sol_types::sol;
use stylus_sdk::{alloy_primitives::U256, prelude::*};

// Define some persistent storage using the Solidity ABI.
sol_storage! {
    #[entrypoint]
    pub struct Settlement {
        uint256 ttl;
        // uint256 abstain_amount;
        address owner;
        uint256 num_rfs;
        bool initialized;
        mapping(address => uint256) active_rfs;
        mapping(uint256 => RFS) settlement_requests;
        Contracts contracts;
    }

    pub struct Contracts{
        address delta_manager;
        address stake_manager;
    }

    pub struct RFS {
        uint256 index;
        address owner;
        uint256 amount;
        uint256 amount_filled;

        address[] participants;
        address[] bidders;

        mapping(address => uint256) bids;
        // mapping(address => bool) has_abstained;
        bool closed;
    }
}

sol_interface! {
    interface IDeltaManager{
        function isActiveParticipant(address owner) external returns (bool);
        function getCurrencyParticipants(bytes32 currency_hash) external returns (address[] memory);
        function currencyHashOfParticipant(address owner) external returns (bytes32);
        function deltaOfParticipant(address owner) external returns (int256);
        function adminSettle(uint256 amount, address user) external;
    }

    interface IFietStake{
        function getStakedToken() external returns (address);
        function stakeFor(address owner, uint256 amount) external;
        function slashByAmount(address owner, uint256 target_amount, int256 delta_amount) external;
    }

    interface IErc20  {
        function transferFrom(address from, address to, uint256 value) external returns (bool);
        function approve(address spender, uint256 value) external returns (bool);
    }
}

sol! {
    event RFSCreated(address indexed owner, uint256 indexed rfs_id, uint256 ttl);
    event RFSBid(uint256 indexed rfs_id, address indexed bidder, uint256 amount);
    event RFSClosed(address indexed owner, uint256 indexed rfs_id);
}

#[public]
impl Settlement {
    pub fn initialize(
        &mut self,
        delta_manager: Address,
        stake_manager: Address,
        ttl: U256,
        // abstain_amount: U256,
    ) -> Result<(), Vec<u8>> {
        // make sure the contract is initialized yet
        if self.initialized.get() {
            return Err("NOT_INITIALIZED".into());
        };

        // initialize important variables
        self.contracts.delta_manager.set(delta_manager);
        self.contracts.stake_manager.set(stake_manager);

        // set the initialized value to be true to prevent another reinitialization
        self.initialized.set(true);
        // set the owner of the contract
        self.owner.set(self.vm().msg_sender());
        self.ttl.set(ttl);
        // self.abstain_amount.set(abstain_amount);
        // initialize the rfc index to 1
        self.num_rfs.set(U256::from(1));

        return Ok(());
    }

    pub fn create_request_for_settlement(&mut self, settle_amount: U256) -> Result<(), Vec<u8>> {
        let index = self.num_rfs.get();
        let ttl = self.ttl.get();

        let sender = self.vm().msg_sender();

        let delta_manager_address = self.contracts.delta_manager.get();
        let delta_manger = IDeltaManager::new(delta_manager_address);

        // set the amount
        if settle_amount == U256::from(0) {
            return Err("INVALID AMOUNT".into());
        }

        // make sure there is no active RFS for this participant
        let active_rfs = self.active_rfs.get(sender);
        if active_rfs != U256::ZERO {
            return Err("ACTIVE RFS".into());
        }

        // get the delta of this participant and make sure its <= amount provided
        // the more positive the amount, the more the protocol 'owes' them
        // make sure the protocol owes them at least the
        let participant_delta = delta_manger.delta_of_participant(&mut *self, sender)?;
        let participant_delta = U256::try_from(participant_delta.abs()).unwrap();
        if settle_amount > participant_delta {
            return Err("INSUFFICIENT DELTA".into());
        }

        // get all the participants as at the time of initiating
        let currency_hash = delta_manger.currency_hash_of_participant(&mut *self, sender)?;
        let rfs_participants = delta_manger.get_currency_participants(&mut *self, currency_hash)?;

        // Create a new RFS instance
        let mut rfs_setter = self.settlement_requests.setter(index);

        // set the index and owner and amount
        rfs_setter.index.set(index);
        rfs_setter.owner.set(sender);
        rfs_setter.amount.set(settle_amount);

        // set all the participants
        for participant in rfs_participants {
            rfs_setter.participants.push(participant);
        }
        // Create a new RFS instance

        // create mapping for who has an active rfs ongoing to prevent creating multiple at a go
        self.active_rfs.setter(sender).set(index);
        self.num_rfs.set(index + U256::from(1));

        log(
            self.vm(),
            RFSCreated {
                owner: sender,
                rfs_id: index,
                ttl,
            },
        );

        return Ok(());
    }

    // called by a participant of an rfs to settle their delta by burning vrl for delta by settling some part or more of their signalled liquidity
    pub fn bid(&mut self, rfs_id: U256, amount: U256) -> Result<(), Vec<u8>> {
        let caller = self.vm().msg_sender();
        let mut rfs = self.settlement_requests.setter(rfs_id);

        // validate it is still active
        if rfs.closed.get() {
            return Err("REQUEST CLOSED".into());
        }

        // if rfs.has_abstained.get(caller) {
        //     return Err("SENDER HAS ABSTAINED".into());
        // }

        let amount_left = rfs.amount.get() - rfs.amount_filled.get();
        if amount < U256::ZERO || amount > amount_left {
            return Err("INVALID AMOUNT".into());
        }

        // settle the admin
        // now delta(d) should be in the range d >=0
        // i.e if they had -100 delta and have 80vrl from making a deposit
        // if the settle amount is 60, then 60vrl will be burned and delta = -100 + 60 = -40
        // since it was a deposit, the delta of the custodian will tends towards -inf as more settlements are made
        // beause more settlements would negate the custodian's delta, giving them enough to conver the potential offramp
        let dm = self.contracts.delta_manager.get();
        let delta_manager_contract = IDeltaManager::new(dm);

        // update the amount left
        let amount_filled = rfs.amount_filled.get() + amount;
        rfs.amount_filled.set(amount_filled);

        // map the settled amount
        let existing_bid = rfs.bids.get(caller);
        // if no existing bid, then we add them to participant list
        if existing_bid == U256::ZERO {
            rfs.bidders.push(caller);
        };
        // increment bid amount by deposit
        rfs.bids.setter(caller).set(existing_bid + amount);

        // settle the vrl aginst the delta i.e make the call to burn VRL to clear up their delta by the amount
        delta_manager_contract.admin_settle(&mut *self, amount, caller)?;
        // log related event
        log(
            self.vm(),
            RFSBid {
                rfs_id,
                bidder: caller,
                amount,
            },
        );
        return Ok(());
    }

    // called by a participant to abstain via staking an amount
    // pub fn abstain(&mut self, rfs_id: U256) -> Result<(), Vec<u8>> {
    //     let sender = self.vm().msg_sender();
    //     let contract_address = self.vm().contract_address();
    //     let abstain_amount = self.abstain_amount.get();
    //     let stake_contract = IFietStake::new(self.contracts.stake_manager.get());
    //     let rfs = self.settlement_requests.get(rfs_id);

    // // validate it is still active
    // if rfs.closed.get() {
    //     return Err("REQUEST CLOSED".into());
    // }

    // // make sure this person has not bid
    // // make sure this person is a participant
    // if rfs.bids.get(sender) != U256::ZERO || rfs.has_abstained.get(sender) {
    //     return Err("ALREADY PARTICIPATED IN RFS".into());
    // }

    // // derive erc20 token
    // let token_address =
    //     IFietStake::new(self.contracts.stake_manager.get()).get_staked_token(&mut *self)?;
    // let token = IErc20::new(token_address);
    // // transfer some tokens to this contract
    // token.transfer_from(&mut *self, sender, contract_address, abstain_amount)?;

    // // call stake on behalf of function on stake contract no need to blacklist access
    // stake_contract.stake_for(&mut *self, sender, abstain_amount)?;

    // // add to stakes mapping as participant
    // let mut rfs = self.settlement_requests.setter(rfs_id);
    // rfs.has_abstained.setter(sender).set(true);

    //     return Ok(());
    // }

    pub fn close_request_for_settlement(&mut self) -> Result<(), Vec<u8>> {
        let sender = self.vm().msg_sender();

        // get the active rfs for this sender
        let active_rfs_id = self.active_rfs.get(sender);
        if active_rfs_id == U256::ZERO {
            return Err("NO ACTIVE RFS".into());
        }

        let delta_manager = IDeltaManager::new(self.contracts.delta_manager.get());
        let fiet_stake = IFietStake::new(self.contracts.stake_manager.get());

        // get participants who did not stake and shash their funds
        let rfs_amount = self.settlement_requests.get(active_rfs_id).amount.get();
        let num_rfs_participants = self
            .settlement_requests
            .get(active_rfs_id)
            .participants
            .len();

        // get participants who bid zero and slash
        for participant_index in 0..num_rfs_participants {
            let rfs_getter = self.settlement_requests.get(active_rfs_id);
            // get this participant
            let participant = rfs_getter.participants.get(participant_index).unwrap();
            // check their bid
            let particpipant_bid = rfs_getter.bids.get(sender);
            // let participant_abstained = rfs_getter.has_abstained.get(sender);
            // if the participant has no bid and didnt abstain then we slash them
            if particpipant_bid == U256::ZERO {
                // get their delta which should be negative
                let participant_delta_debt = delta_manager
                    .delta_of_participant(&mut *self, participant)
                    .unwrap()
                    .abs();
                // slash them by the determined amount
                fiet_stake.slash_by_amount(
                    &mut *self,
                    participant,
                    rfs_amount,
                    participant_delta_debt,
                )?;
            }
        }

        // get the rfs and mark it as closed
        let mut rfs_setter = self.settlement_requests.setter(active_rfs_id);
        rfs_setter.closed.set(true);
        self.active_rfs.setter(sender).set(U256::ZERO);

        // log related event
        log(
            self.vm(),
            RFSClosed {
                owner: sender,
                rfs_id: active_rfs_id,
            },
        );

        return Ok(());
    }
}
