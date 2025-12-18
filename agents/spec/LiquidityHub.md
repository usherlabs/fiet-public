# LiquidityHub: Comprehensive Protocol Documentation

The LiquidityHub serves as the central contract in the Fiet protocol, orchestrating the creation, management, and settlement of Liquidity Commitment Certificates (LCCs). It acts as a hub-and-spoke model for aggregating liquidity across markets, facilitating efficient backing and flattening of LCC tokens that share the same underlying assets. This document provides a detailed, whitepaper-style explanation of all mechanisms, with particular focus on LCC-backing-LCC operations and their integration with the broader protocol architecture.

## Architecture and Design Philosophy

The LiquidityHub is designed with a fundamental principle: it remains agnostic to end-user accounts, similar to how Uniswap's PoolManager leverages periphery contracts to manage end-account balances. The Hub aggregates balances and uses LCCs to track account balances in a hub-and-spoke model, where the Hub maintains shared reserves and settlement queues, while individual LCC tokens track user positions.

This design enables several key capabilities: efficient pooling of liquidity across markets sharing the same underlying assets, lazy settlement mechanisms that defer actual transfers until liquidity becomes available, and optimised flattening strategies that prevent recursive backing chains while minimising gas costs and market interactions.

## Core State Variables and Invariants

The LiquidityHub maintains several critical state mappings that enable its functionality. The `directSupply` mapping tracks Out-of-Market (OOM) balances for each LCC token, representing liquidity directly wrapped by users and held in the Hub's reserves. The `reserveOfUnderlying` mapping aggregates underlying asset reserves across all LCCs sharing the same underlying, enabling shared liquidity pools.

Settlement queues are managed through two mappings: `settleQueue[lcc][recipient]` tracks pending settlements owed to specific recipients, while `totalQueued[lcc]` provides aggregate tracking for each LCC. These queues represent commitments to provide underlying assets when liquidity becomes available, created during unwrap operations when immediate liquidity is insufficient.

A critical innovation is the `nettedLCCsAsUnderlying` mapping, which implements lazy claiming for LCC-backing-LCC operations. This prevents over-netting across concurrent wrap operations by tracking claimed but unreconciled portions of settlement queues, enabling efficient netting without immediate queue modifications.

The fundamental invariant maintained throughout is that total LCC supply for any underlying asset must not exceed the sum of direct supply, market liquidity, and queued settlements. This ensures 1:1 backing ratios are preserved across all operations.

## LCC Creation and Initialization

The LiquidityHub inherits from LCCFactory, which provides the foundational mechanisms for creating and managing LCC tokens. When a new market is created, the factory calls `createLCCPair`, which generates two LCC tokens for the market's underlying asset pair. Each LCC token is uniquely identified through a symbol construction that includes the underlying asset symbol and a truncated market reference, ensuring uniqueness even when multiple markets share the same underlying assets.

The creation process involves generating appropriate names and symbols, determining decimals from the underlying asset (or using native asset defaults for ETH), and deploying new LiquidityCommitmentCertificate contracts. These contracts are configured with references to their market factory, underlying asset, and oracle addresses.

After creation, the `initialize` function establishes the bidirectional mappings between LCC tokens and their markets. This includes storing the market ID (derived from the core pool key), market reference (proxy hook address), factory address, and issuer permissions. The initialization also sets up mappings that allow efficient lookup of LCC tokens by market ID and underlying asset, enabling the various wrap and unwrap operations that reference markets rather than specific LCC addresses.

## Direct Wrapping Operations

The simplest operation in the LiquidityHub is direct wrapping, where users deposit underlying assets to receive LCC tokens. The `_wrap` function handles this process, accepting either ERC20 tokens or native ETH depending on the LCC's underlying asset type.

When wrapping occurs, the underlying assets are transferred to the Hub (or native ETH is received via `msg.value`), the `directSupply` for that LCC is incremented, and the shared `reserveOfUnderlying` is updated. The LCC tokens are then minted to the recipient, with the minting function distinguishing between direct (wrapped) and market-derived balances based on whether the caller is an issuer.

The wrapping process maintains strict 1:1 ratios: for every unit of underlying asset deposited, exactly one unit of LCC token is minted. The Hub provides multiple entry points for wrapping, including `wrap` and `wrapTo` functions that accept either LCC addresses directly or market identifiers with underlying asset addresses, providing flexibility for different use cases.

## LCC-backing-LCC: Flattening and Netting Mechanisms

In the Fiet protocol, LCC tokens represent commitments to provide liquidity backed by underlying assets. When one LCC is used to back another (sharing the same underlying), the LiquidityHub employs optimised flattening strategies to prevent recursive chains, reduce gas costs, and minimise unnecessary interactions with market liquidity. The `_wrapWith` function is central to this, implementing a multi-step process that prioritises direct transfers, queue netting, and residual unwrapping. Below, we describe the key steps in detail, explaining their validity and integration with the broader system components such as MarketVault, ProxyHook, and CoreHook.

### Step 0: Netting Against Target LCC Hub Queue (Immediate Annulment and Utilisation of Hub-Held Target)

The process begins with an opportunity to utilise any pending settlements already queued for the target LCC at the Hub itself. Specifically, if the Hub has a queued settlement for the target LCC (stored in `settleQueue[lcc][address(this)]`), and it holds sufficient target LCC tokens (checked via `_balanceOf(lcc, address(this))`), this step annuls a portion of that queue to directly satisfy part of the wrap request.

The annulment is capped by the minimum of the remaining wrap amount, the queue size, and the Hub-held target LCC balance. For the annulled amount (`netTarget`):

- The user's provided backing LCC (`withLCC`) is consumed proportionally from their market-derived and wrapped buckets to maintain accounting integrity.
- The queue is reduced (`settleQueue[lcc][address(this)] -= netTarget`), and the total queued amount is updated accordingly.
- The Hub-held target LCC is burned (protocol-bound, permanent removal from supply).
- An equal amount of the backing `withLCC` is also burned (protocol-bound).
- The target LCC is minted to the recipient as market-derived, reflecting the queue's origin.

This step is valid because the queue represents "pending underlying owed to the Hub" from future settlements (e.g., triggered by MarketVault's `confirmTake` after liquidity deposits via ProxyHook or CoreHook). By annulling it and burning Hub-held target LCC, the mechanism effectively cancels the pending claim, as the burned LCC was already backed by underlying assets left in the market (e.g., PoolManager reserves via MarketVault). Burning the backing `withLCC` is crucial to maintain 1:1 backing and balance total supply: without it, the mint would inflate the supply without consuming equivalent backing. Instead, this "transfers" the backing from `withLCC` to the new target LCC mint, flattening the chain immediately. The minted LCC inherits backing from underlying "left in the market" (PoolManager/vault claims), and annulling avoids redundant future settlements. This integrates with MarketVault's obligation settlements (e.g., `_settleObligationsForLCC` takes from vault to Hub after ProxyHook swaps/LP deposits), shortcutting the process without violating invariants: total LCC supply remains <= total underlying (reserves + market + queues).

### Step 1: Direct Supply Transfer (Optimised Conversion Without Unwrap)

Following Step 0, if the user has wrapped (direct) balances in the backing LCC, these are transferred directly to the target LCC's direct supply without invoking an unwrap operation. This is capped by the available direct supply in `withLCC` and the user's wrapped amount. The backing LCC is burned (protocol-bound), and the target LCC is tracked for minting as direct.

This optimisation is efficient and valid because direct supply represents liquidity already held in the Hub's reserves (not requiring market interaction). Transferring it flattens the backing without redundant operations, preserving bucket semantics and 1:1 ratios. The direct supply transfer maintains the invariant that total direct supply across all LCCs sharing an underlying asset equals the shared reserve, ensuring no liquidity is lost or duplicated in the process.

### Step 2: Netting Against Backing LCC's Effective Queue (Lazy Claiming of Pre-Utilised Backing)

For the remaining amount (prioritising market-derived portions), the mechanism nets against the backing LCC's own Hub queue (`settleQueue[withLCC][address(this)]`). This queue indicates pending underlying owed to the Hub due to prior unwrap shortfalls of `withLCC`. To prevent over-netting across concurrent wraps, a lazy-claimed mapping (`nettedLCCsAsUnderlying[withLCC]`) tracks previously claimed but unreconciled portions. The effective queue is computed as `max(0, queue - claimed)`.

The nettable amount is capped by the minimum of the remainder, the user's market-derived balance, and the effective queue. For this amount:

- The claimed mapping is incremented (lazy claim).
- The backing `withLCC` is burned (market bucket, protocol-bound).
- The target LCC is tracked for minting as market-derived.
- The user's market-derived amount is reduced.

This works because the queue represents "pre-unwrapped" capacity—amounts already utilised as backing for other LCCs (via prior shortfalls). Netting incoming `withLCC` avoids re-unwrapping these, treating the queue as reusable backing for new mints. The lazy claim ensures no over-claiming: total claims <= queue, reconciled during settlement (in `processSettlementFor`, decrementing claims before burning only unclaimed portions). This integrates with ProxyHook/CoreHook (e.g., `onCorePoolDirectSwap` settles underlying to vault, triggering MarketVault's `_settleObligationsForLCC` to clear queues via `confirmTake`). By burning `withLCC` now and minting target, it flattens chains 1:1 without immediate market pulls (via `useMarketLiquidity`), reducing costs while keeping supply <= underlying (reserves + market + queues). It's like merging backings at the Hub for same-underlying LCCs, valid as queues guarantee future replenishment.

### Step 3: Residual Unwrap and Shortfall Queuing

Any remainder after netting undergoes standard unwrapping via `_unwrapInternalLogic`, consuming direct supply then market liquidity. Burns occur for unwrapped amounts, and shortfalls are queued. The target is minted reflecting direct vs. market-derived components. This final step ensures that even when netting cannot fully satisfy the wrap request, the system gracefully handles the residual by falling back to standard unwrapping mechanisms, with any shortfalls properly queued for future settlement.

### Consolidated Burn Operations

An important optimisation in the `_wrapWith` implementation is the consolidation of burn operations. Rather than performing multiple burn calls throughout the process, the function tracks all burns for each LCC and executes them in a single consolidated call at the end. This reduces gas costs significantly, as each burn operation involves state updates and potentially external calls to the LCC contract. The consolidation maintains the same accounting semantics while improving efficiency.

## Unwrapping Operations

Unwrapping is the inverse operation to wrapping, where users exchange LCC tokens for underlying assets. The `_unwrap` function handles this process, first validating that the user has sufficient balance and then routing to the internal unwrap logic.

The `_unwrapInternalLogic` function implements a three-tier priority system for fulfilling unwrap requests. First, it attempts to consume from `directSupply[lcc]`, which represents liquidity already held in the Hub's reserves. This is the most efficient path, requiring no market interactions. Second, if direct supply is insufficient, it pulls from market liquidity via `_useMarketLiquidity`, which interacts with the MarketFactory to withdraw underlying assets from the market's PoolManager reserves. Third, if both direct supply and market liquidity are insufficient, any shortfall is queued for future settlement via `_queueSettlement`.

The unwrapping process respects bucket semantics, consuming from wrapped balances before market-derived balances, mirroring the priority order used in LCC token transfers. This ensures consistent accounting and prevents gaming scenarios where users might attempt to manipulate the order of operations.

When unwrapping completes successfully (i.e., when sufficient liquidity is available), the `_pay` function handles the final settlement: burning the LCC tokens from the user's account and transferring the underlying assets. The burn operation respects bucket accounting, decrementing the appropriate wrapped or market-derived balances based on what was consumed.

## Settlement Mechanisms

Settlement in the LiquidityHub operates through a sophisticated queue-based system that enables lazy reconciliation of liquidity commitments. When unwrap operations encounter insufficient liquidity, shortfalls are queued rather than reverting, allowing the protocol to continue operating while liquidity is sourced asynchronously.

### Queue Creation and Management

Settlement queues are created via `_queueSettlement`, which increments both the per-recipient queue (`settleQueue[lcc][recipient]`) and the aggregate total (`totalQueued[lcc]`). This dual tracking enables efficient queries while maintaining per-recipient accounting. The queue represents a commitment to provide underlying assets when they become available, without requiring immediate fulfillment.

### Settlement Processing

The `processSettlementFor` function provides a permissionless mechanism for processing settlements when liquidity becomes available. This function branches its behavior based on whether the recipient is the Hub itself (`address(this)`) or an external address, enabling different accounting paths for LCC-backing-LCC operations versus user unwraps.

For external recipients, the function checks the holder's market-derived balance, burns their LCC tokens, transfers underlying assets, and decrements reserves. This is the standard path for user-initiated unwraps that encountered shortfalls.

For Hub settlements (used in LCC-backing-LCC scenarios), the function reconciles lazy netted claims first. It decrements the `nettedLCCsAsUnderlying` mapping by the settlement amount, then burns only the unclaimed portion of Hub-held LCC tokens. This ensures that amounts already claimed during `_wrapWith` operations are properly accounted for, preventing double-burning while maintaining supply invariants.

### Settlement Preparation

The `prepareSettle` function enables MarketVaults to prepare settlements from the Hub to PoolManager. For ERC20 tokens, it approves the caller (MarketVault) to pull tokens; for native ETH, it transfers ETH directly. The function decrements `reserveOfUnderlying` immediately, ensuring atomic accounting. This is intended to be called just before settlement in the same transaction, enabling efficient liquidity flows between Hub and markets.

### Settlement Annulment

The `annulSettlementBeforeTransfer` function handles edge cases where protocol-bound transfers might otherwise fail due to settlement queue accounting. If a transfer amount exceeds the user's liquid balance (wrapped + market-derived), the excess "bleeds" into their queued settlement. This function removes that bleed from the queue up to the queued amount, ensuring transfers can proceed while maintaining accounting integrity.

## Issuer Functions

The LiquidityHub provides issuer-specific functions that enable MarketVaults and other authorised entities to manage LCC supply in response to market operations. These functions bypass normal wrapping mechanisms, directly minting or burning LCC tokens.

### Issuing LCC Tokens

The `issue` function allows authorised issuers to mint LCC tokens directly, marking them as "issued" to skip bucket accounting. This is used when MarketVaults need to create LCC tokens representing liquidity that has been deposited into markets, such as during swap operations where input tokens are converted to LCC tokens before being settled to the PoolManager.

### Cancelling LCC Tokens

The `cancel` function allows issuers to burn LCC tokens, also marked as "issued" to skip bucket accounting. This is used when MarketVaults need to remove LCC tokens from circulation, such as when output tokens are unwrapped during swap operations or when liquidity is removed from markets.

### Confirming Takes

The `confirmTake` function is called by MarketVaults after taking underlying liquidity from markets to the Hub. This function increments `reserveOfUnderlying`, processes any pending Hub queue settlements, and optionally emits a `LiquidityAvailable` event if new liquidity beyond queued amounts becomes available. This is a critical integration point between MarketVault operations and Hub accounting, ensuring that liquidity movements are properly tracked and settlements are processed promptly.

## Market Liquidity Interactions

The LiquidityHub interacts with market liquidity through the MarketFactory interface, querying available liquidity and requesting withdrawals when needed. The `marketLiquidity` function provides a view of available liquidity for a given LCC, while `_useMarketLiquidity` performs the actual withdrawal operation.

These interactions are abstracted through the MarketFactory, which coordinates with MarketVaults to manage liquidity in Uniswap V4 pools. The Hub remains agnostic to the specific implementation details, focusing instead on maintaining its own accounting and settlement mechanisms.

## Integration with Broader Protocol Components

The LiquidityHub integrates seamlessly with several key protocol components, each playing a specific role in the overall liquidity management system.

### MarketVault Integration

MarketVaults serve as intermediaries between the Hub and Uniswap V4 PoolManagers, handling the actual settlement and withdrawal of underlying assets. When MarketVaults take liquidity from markets (via `_takeUnderlyingFromVaultToHub`), they call `confirmTake` to notify the Hub and trigger settlement processing. When MarketVaults need to settle liquidity to markets (via `_settleUnderlyingToVaultFromHub`), they call `prepareSettle` to prepare the Hub's reserves for transfer.

### ProxyHook Integration

ProxyHooks manage LCC-based proxy pools, proxying swaps to underlying core pools and handling LCC conversions. During swap operations, ProxyHooks issue LCC tokens for input amounts and cancel LCC tokens for output amounts, using the Hub's issuer functions. They also trigger obligation settlements after swaps complete, ensuring that any pending unwrap shortfalls are addressed when new liquidity becomes available.

### CoreHook Integration

CoreHooks manage underlying-asset core pools, accruing growth metrics and notifying ProxyHooks of direct liquidity provision events. When direct LP operations occur, CoreHooks call ProxyHook's `onDirectLP` function, which in turn interacts with the Hub to settle or take liquidity as needed. This creates a flow where core pool operations trigger appropriate Hub operations, maintaining consistency across the protocol.

## Native Asset Handling

The LiquidityHub handles native ETH specially, using `msg.value` for wrapping operations and implementing a `receive` function that validates senders. The `receive` function ensures that only MarketVaults can send native ETH directly, preventing accidental transfers and maintaining security. This is particularly important for native asset routes where PoolManager operations might transfer ETH directly to the Hub.

## Events and Observability

The LiquidityHub emits several events that enable off-chain monitoring and indexing. `FactorySet` tracks factory authorisations, `LiquidityAvailable` signals when new liquidity becomes available for settlement, `SettlementQueued` records when shortfalls are queued, and `LccWrapped`, `LccWrappedWith`, and `LccUnwrapped` track wrapping and unwrapping operations. These events provide a complete audit trail of Hub operations, enabling analytics, monitoring, and debugging.

## Security Considerations

The LiquidityHub implements several security mechanisms. Factory authorisation ensures only approved factories can create markets and LCC tokens. Issuer permissions restrict minting and burning to authorised entities. Balance validation prevents over-wrapping and over-unwrapping. The lazy netting mechanism prevents over-claiming of settlement queues. And the consolidated burn operations reduce attack surface by minimising external calls.

The Hub's design as an account-agnostic aggregator also provides security benefits: by not tracking individual user accounts directly, the Hub reduces complexity and potential attack vectors, delegating account management to the LCC tokens themselves.

## Conclusion

The LiquidityHub represents a sophisticated system for managing liquidity commitments across multiple markets, enabling efficient flattening, netting, and settlement operations while maintaining strict 1:1 backing ratios. Its integration with MarketVaults, ProxyHooks, and CoreHooks creates a cohesive protocol where liquidity flows efficiently between markets and the Hub, with lazy settlement mechanisms ensuring smooth operation even when immediate liquidity is unavailable. The LCC-backing-LCC mechanisms in particular demonstrate the protocol's ability to handle complex backing scenarios efficiently, minimising gas costs and market interactions while preserving accounting integrity.
