use alloc::{collections::BTreeSet, vec::Vec};

use stylus_sdk::{
    alloy_primitives::{keccak256, Address, FixedBytes, U256},
    call::RawCall,
};

use crate::{
    errors::FactsError,
    types::facts::{FactsProvider, Slot0},
};

/// Canonical fact sources for the validator (per Kernel smart account).
#[derive(Clone, Copy, Debug)]
pub struct FactSources {
    pub state_view: Address,
    pub vts_orchestrator: Address,
    pub liquidity_hub: Address,
}

/// On-chain facts provider that uses `staticcall` with a strict allowlist and per-call gas cap.
pub struct OnchainFactsProvider {
    pub sources: FactSources,
    pub gas_cap: u64,
    pub now: u64,
    pub allowlist: BTreeSet<(Address, [u8; 4])>,
}

impl OnchainFactsProvider {
    pub fn new(sources: FactSources, gas_cap: u64, now: u64) -> Self {
        let mut allowlist = BTreeSet::new();

        // StateView.getSlot0(bytes32)
        allowlist.insert((sources.state_view, selector("getSlot0(bytes32)")));

        // VTSOrchestrator.positionToCheckpoint(bytes32)
        allowlist.insert((
            sources.vts_orchestrator,
            selector("positionToCheckpoint(bytes32)"),
        ));
        // VTSOrchestrator.getPositionSettledAmounts(bytes32)
        allowlist.insert((
            sources.vts_orchestrator,
            selector("getPositionSettledAmounts(bytes32)"),
        ));
        // VTSOrchestrator.getCommitmentMaxima(bytes32)
        allowlist.insert((
            sources.vts_orchestrator,
            selector("getCommitmentMaxima(bytes32)"),
        ));
        // VTSOrchestrator.getPosition(bytes32)
        allowlist.insert((
            sources.vts_orchestrator,
            selector("getPosition(bytes32)"),
        ));
        // VTSOrchestrator.getPool(bytes32)  (PoolId is bytes32)
        allowlist.insert((sources.vts_orchestrator, selector("getPool(bytes32)")));

        // LiquidityHub.reserveOfUnderlying(address)
        allowlist.insert((
            sources.liquidity_hub,
            selector("reserveOfUnderlying(address)"),
        ));
        // LiquidityHub.settleQueue(address,address)
        allowlist.insert((
            sources.liquidity_hub,
            selector("settleQueue(address,address)"),
        ));

        Self {
            sources,
            gas_cap,
            now,
            allowlist,
        }
    }

    fn staticcall(
        &self,
        target: Address,
        selector: [u8; 4],
        args: &[u8],
    ) -> Result<Vec<u8>, FactsError> {
        if !self.allowlist.contains(&(target, selector)) {
            return Err(FactsError::ForbiddenCall { target, selector });
        }
        let mut data = Vec::with_capacity(4 + args.len());
        data.extend_from_slice(&selector);
        data.extend_from_slice(args);

        // bytes-in, bytes-out staticcall with gas cap.
        let out = unsafe { RawCall::new_static().gas(self.gas_cap).call(target, &data) }
            .map_err(|_| FactsError::CallFailed)?;
        Ok(out)
    }
}

impl FactsProvider for OnchainFactsProvider {
    fn block_timestamp(&self) -> u64 {
        self.now
    }

    fn get_slot0(&self, pool_id: FixedBytes<32>) -> Result<Slot0, FactsError> {
        let out = self.staticcall(
            self.sources.state_view,
            selector("getSlot0(bytes32)"),
            pool_id.as_slice(),
        )?;
        // (uint160, int24, uint24, uint24) => 4 * 32 bytes
        if out.len() < 32 * 4 {
            return Err(FactsError::MalformedReturn);
        }
        let w0 = &out[0..32];
        let w1 = &out[32..64];
        let w2 = &out[64..96];
        let w3 = &out[96..128];

        let sqrt_price_x96 = U256::from_be_slice(w0);
        let tick = decode_i24(w1);
        let protocol_fee = decode_u24(w2);
        let lp_fee = decode_u24(w3);

        Ok(Slot0 {
            sqrt_price_x96,
            tick,
            protocol_fee,
            lp_fee,
        })
    }

    fn is_rfs_closed(&self, position_id: FixedBytes<32>) -> Result<bool, FactsError> {
        // positionToCheckpoint(bytes32) returns (uint256 timeOfLastTransition, bool isOpen, uint256, uint256)
        let out = self.staticcall(
            self.sources.vts_orchestrator,
            selector("positionToCheckpoint(bytes32)"),
            position_id.as_slice(),
        )?;
        if out.len() < 32 * 4 {
            return Err(FactsError::MalformedReturn);
        }
        let is_open_word = &out[32..64];
        let is_open = U256::from_be_slice(is_open_word) != U256::ZERO;
        Ok(!is_open)
    }

    fn queue_amount(&self, lcc: Address, owner: Address) -> Result<U256, FactsError> {
        let mut args = [0u8; 64];
        // address is left-padded in 32-byte ABI word
        args[12..32].copy_from_slice(lcc.as_slice());
        args[44..64].copy_from_slice(owner.as_slice());

        let out = self.staticcall(
            self.sources.liquidity_hub,
            selector("settleQueue(address,address)"),
            &args,
        )?;
        if out.len() < 32 {
            return Err(FactsError::MalformedReturn);
        }
        Ok(U256::from_be_slice(&out[0..32]))
    }

    fn reserve_of(&self, lcc: Address) -> Result<U256, FactsError> {
        let mut args = [0u8; 32];
        args[12..32].copy_from_slice(lcc.as_slice());
        let out = self.staticcall(
            self.sources.liquidity_hub,
            selector("reserveOfUnderlying(address)"),
            &args,
        )?;
        if out.len() < 32 {
            return Err(FactsError::MalformedReturn);
        }
        Ok(U256::from_be_slice(&out[0..32]))
    }

    fn get_settled_amounts(&self, position_id: FixedBytes<32>) -> Result<(U256, U256), FactsError> {
        // getPositionSettledAmounts(bytes32) returns (uint256 amount0, uint256 amount1)
        let out = self.staticcall(
            self.sources.vts_orchestrator,
            selector("getPositionSettledAmounts(bytes32)"),
            position_id.as_slice(),
        )?;
        if out.len() < 32 * 2 {
            return Err(FactsError::MalformedReturn);
        }
        let amount0 = U256::from_be_slice(&out[0..32]);
        let amount1 = U256::from_be_slice(&out[32..64]);
        Ok((amount0, amount1))
    }

    fn get_commitment_maxima(&self, position_id: FixedBytes<32>) -> Result<(U256, U256), FactsError> {
        // getCommitmentMaxima(bytes32) returns (uint256 commitment0, uint256 commitment1)
        let out = self.staticcall(
            self.sources.vts_orchestrator,
            selector("getCommitmentMaxima(bytes32)"),
            position_id.as_slice(),
        )?;
        if out.len() < 32 * 2 {
            return Err(FactsError::MalformedReturn);
        }
        let commitment0 = U256::from_be_slice(&out[0..32]);
        let commitment1 = U256::from_be_slice(&out[32..64]);
        Ok((commitment0, commitment1))
    }

    fn grace_period_remaining(&self, position_id: FixedBytes<32>) -> Result<u64, FactsError> {
        // positionToCheckpoint(bytes32) returns RFSCheckpoint:
        // (uint256 timeOfLastTransition, bool isOpen, uint256 gracePeriodExtension0, uint256 gracePeriodExtension1)
        let out = self.staticcall(
            self.sources.vts_orchestrator,
            selector("positionToCheckpoint(bytes32)"),
            position_id.as_slice(),
        )?;
        if out.len() < 32 * 4 {
            return Err(FactsError::MalformedReturn);
        }
        let time_of_last_transition = U256::from_be_slice(&out[0..32]);
        let is_open_word = &out[32..64];
        let is_open = U256::from_be_slice(is_open_word) != U256::ZERO;
        let grace_extension0 = U256::from_be_slice(&out[64..96]);
        let grace_extension1 = U256::from_be_slice(&out[96..128]);
        
        // If RFS is not open, grace period doesn't apply (treat as infinite remaining).
        if !is_open {
            return Ok(u64::MAX);
        }
        
        // Fetch position to get poolId (Position struct: owner, poolId, ...)
        let pos_out = self.staticcall(
            self.sources.vts_orchestrator,
            selector("getPosition(bytes32)"),
            position_id.as_slice(),
        )?;
        if pos_out.len() < 64 {
            return Err(FactsError::MalformedReturn);
        }
        let mut pool_id_buf = [0u8; 32];
        pool_id_buf.copy_from_slice(&pos_out[32..64]);
        let pool_id = FixedBytes(pool_id_buf);

        // Fetch pool to get MarketVTSConfiguration.token{0,1}.gracePeriodTime
        // ABI layout (words):
        // w0 id, w1 currency0, w2 currency1,
        // w3 token0.gracePeriodTime, w4 token0.seizureUnlockTime, w5 token0.baseVTSRate, w6 token0.maxGracePeriodTime,
        // w7 token1.gracePeriodTime, w8 token1.seizureUnlockTime, w9 token1.baseVTSRate, w10 token1.maxGracePeriodTime,
        // w11 coverageFeeShare, w12 minResidualUnits, w13 isPaused
        let pool_out = self.staticcall(
            self.sources.vts_orchestrator,
            selector("getPool(bytes32)"),
            pool_id.as_slice(),
        )?;
        if pool_out.len() < 32 * 14 {
            return Err(FactsError::MalformedReturn);
        }
        let grace0 = U256::from_be_slice(&pool_out[32 * 3..32 * 4]);
        let grace1 = U256::from_be_slice(&pool_out[32 * 7..32 * 8]);

        // Compute elapsed = now - timeOfLastTransition (clamp negative to 0).
        let now_u = U256::from(self.now);
        let elapsed = if now_u > time_of_last_transition {
            now_u - time_of_last_transition
        } else {
            U256::ZERO
        };

        // Total grace thresholds per token.
        let total0 = grace0 + grace_extension0;
        let total1 = grace1 + grace_extension1;
        let earliest = if total0 < total1 { total0 } else { total1 };

        // Remaining until seizable (earliest threshold).
        let remaining = if earliest > elapsed {
            earliest - elapsed
        } else {
            U256::ZERO
        };

        // Clamp to u64.
        let max_u64 = U256::from(u64::MAX);
        if remaining > max_u64 {
            Ok(u64::MAX)
        } else {
            Ok(remaining.to::<u64>())
        }
    }

    fn staticcall_u256(
        &self,
        target: Address,
        selector: [u8; 4],
        args: &[u8],
    ) -> Result<U256, FactsError> {
        let out = self.staticcall(target, selector, args)?;
        if out.len() < 32 {
            return Err(FactsError::MalformedReturn);
        }
        Ok(U256::from_be_slice(&out[0..32]))
    }
}

fn selector(sig: &str) -> [u8; 4] {
    let h = keccak256(sig.as_bytes());
    [h[0], h[1], h[2], h[3]]
}

fn decode_u24(word: &[u8]) -> u32 {
    let b = &word[29..32];
    ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | (b[2] as u32)
}

fn decode_i24(word: &[u8]) -> i32 {
    let b = &word[29..32];
    let mut v: i32 = ((b[0] as i32) << 16) | ((b[1] as i32) << 8) | (b[2] as i32);
    // sign extend 24-bit
    if (v & (1 << 23)) != 0 {
        v |= !0 << 24;
    }
    v
}
