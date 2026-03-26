# VTS Configuration Considerations

VTS market creation now requires an explicit file-backed configuration. This is intentional: deployment and market creation should never silently inherit protocol defaults when configuring risk-sensitive timing and seizure parameters.

When authoring a VTS config file:

- Treat every field as an explicit risk decision, not boilerplate.
- Keep the file complete and reviewable so production values are visible in version control and deployment review.
- Pay particular attention to time-based fields such as `gracePeriodTime`, `maxGracePeriodTime`, and `unbackedCommitmentGraceBypassTime`.
- Remember that these values are enforced on-chain using `block.timestamp`, so the safety margin must reflect the timestamp behaviour of the target chain.

## Blockchain time skew and config implications

### Ethereum mainnet (post-Merge / current PoS, 12-second slots)

Almost zero manipulation is possible.

- The execution payload timestamp must exactly equal the Beacon Chain slot time: `genesis_time + slot_index * 12`.
- This is a hard consensus rule in the specs. If the proposer sets anything else, the block is invalid.
- A single validator cannot nudge the timestamp by even one second.
- Consecutive proposers cannot accumulate drift because each slot has a fixed timestamp target.
- Real-world accuracy is typically within a few seconds of wall-clock time, accounting for node NTP sync and minor network delay.
- Missed slots only advance time in 12-second jumps; that is not timestamp manipulation.

Implication for VTS config:

- Mainnet permits tighter wall-clock assumptions than most chains.
- Even so, avoid configuring irreversible transitions so tightly that ordinary transaction latency becomes the dominant risk.
- Very short bypass ages or grace windows are still operationally brittle, even if timestamp drift itself is negligible.

### Pre-Merge Ethereum (PoW) or many EVM-compatible chains (BSC, Polygon, Avalanche C-Chain, sidechains, forks)

Block producers can usually adjust timestamps by roughly +/-12 to 15 seconds, with forward skew being the practical vector.

- A block timestamp must be strictly greater than the parent block timestamp.
- Most clients reject blocks that are materially too far in the future relative to local clock time, commonly around 15 seconds.
- Backward movement is constrained by the parent timestamp, so forward nudging is the realistic concern.
- Older references to 900 seconds or 15 minutes are generally myths or misquotes from unrelated rules and should not be used for EVM risk modelling.

Implication for VTS config:

- Do not set `unbackedCommitmentGraceBypassTime` or other loss-triggering timers so low that a single producer’s forward skew can flip the state earlier than intended.
- If a timer is security-critical, its minimum safe value should exceed expected timestamp discretion and normal inclusion latency by a comfortable margin.
- Treat sub-minute safety buffers with caution on these chains unless there is a strong, reviewed reason.

### Layer 2s and sequencer-based chains (Optimism, Arbitrum, Base and similar)

The sequencer sets the timestamp.

- In normal operation the timestamp is usually highly accurate, often within sub-second or low-single-digit-second bounds.
- The trust model is more centralised than Ethereum mainnet because one sequencer controls ordering and timestamping in the short term.
- Some L2s permit much wider bounds in edge cases. For example, Arbitrum can tolerate substantial future or backward drift in extreme delay scenarios.
- Multiple L2 blocks can sometimes share the same timestamp.

Implication for VTS config:

- Treat time-based enforcement as a sequencer-trust assumption, not purely a decentralised consensus property.
- Size grace periods and bypass delays for sequencing power, censorship risk, and timestamp discretion, not just nominal clock accuracy.
- Prefer generous buffers for any setting that can accelerate seizure, expiry, or other irreversible enforcement.
- A non-zero `unbackedCommitmentGraceBypassTime` is strongly preferred on sequencer-driven deployments unless a tighter value has been explicitly reviewed against that chain’s operational model.

## Practical guidance

- Use `block.timestamp` for wall-clock policy, but configure it conservatively for the target chain.
- Do not rely on `block.number` as a general replacement for elapsed time; block cadence varies by chain and does not remove sequencing or censorship risk.
- Keep bundled config files explicit, environment-specific, and audited alongside the deployment plan.
- Revisit VTS timing parameters whenever deploying to a new chain, changing sequencer assumptions, or tightening seizure/expiry behaviour.
