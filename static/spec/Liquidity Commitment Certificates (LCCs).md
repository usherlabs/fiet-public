# Liquidity Commitment Certificates (LCCs)

Market makers (MMs) partition their Verified Reserve Liquidity (VRL) into commitments to Fiet Markets across blockchains. These commitments are represented as Liquidity Commitment Certificates (LCCs).

## What is a Liquidity Commitment Certificate?

Liquidity Commitment Certificates (LCCs) are synthetic assets in the Fiet Protocol that represent settled in-scope liquidity and out-of-scope Verified Reserve Liquidity (VRL) committed to Fiet Markets.

Verified via zero-knowledge proofs (zkTLS), LCCs ensure:

1. Traders can engage the decentralised exchange (DEX) with live price action that accounts for virtual liquidity.
2. MMs can deliver settlement tokens (e.g., USDC, ETH) held in reserves, such as bank accounts or centralised exchanges, without immediate on-chain lockup.

LCCs are non-transferable, protocol-bound assets traded exclusively on Fiet’s integrated DEX, mirroring the settlement token. Traders can exercise LCCs to redeem the underlying token. The Value-to-Signal (VTS) ratio for each token in a position dynamically adjusts collateral requirements, ensuring MMs maintain on-chain capital to support settlement obligations. This design distinguishes LCCs from stablecoins or securities, aligning with regulatory compliance.

## Traditional Finance Analogy

Fiet’s **Liquidity Commitment Certificates (LCCs)** are like bank-backed guarantees, ensuring verified liquidity with the trust of a letter of credit, but in a decentralised, transparent system.

Imagine a **LCC** as a hybrid of a [**standby letter of credit**](https://www.investopedia.com/terms/s/standbyletterofcredit.asp) and a **tradeable [warehouse receipt](https://www.investopedia.com/terms/w/warehousereceipt.asp)** used in commodity markets. In traditional finance, a standby letter of credit is a bank’s guarantee that a seller can deliver goods or funds when needed, providing confidence to buyers without immediately moving the assets. Similarly, our protocol allows **Market Makers** to commit liquidity, like US dollars or crypto, held in verified reserves, such as bank accounts or centralised exchange balances. Using **zkTLS proofs**, we verify these reserves on-chain, ensuring the liquidity is real without requiring it to move upfront.

This commitment is wrapped into a **certificate** — think of it like a warehouse receipt that proves ownership of goods, like grain or oil, stored elsewhere. In our case, the ‘goods’ are the liquidity (e.g., USDC or ETH). Traders can buy and sell these certificates on integrated decentralised exchanges, much like warehouse receipts are traded in commodity markets, allowing them to access deeper liquidity pools without the funds being locked on-chain.

When the market demands it — say, during a surge in trading — the certificate can be ‘exercised’ to deliver the actual asset, like redeeming a warehouse receipt for physical goods. But unlike a typical token or stablecoin, these certificates are **locked to our platform**, ensuring they’re used only for trading and settlement within our ecosystem, reducing risks of misclassification. Our **Value-to-Signal ratio** acts like a dynamic collateral requirement, ensuring providers always have some skin in the game on-chain, while flexibly adjusting to market needs.

In short, our Liquidity Commitment Certificate lets traders tap into massive, verified liquidity pools with the confidence of a bank-backed guarantee, but with the flexibility and efficiency of a decentralised exchange.

## Example

A market maker (MM) commits $1,000,000 in USD-denominated Verified Reserve Liquidity (VRL) to a USDC/ETH Fiet Market. The market requires 2% collateral ($20,000), allocated between USDC and ETH according to the automated market makers’ (AMM) current state and liquidity mathematics, ensuring a balanced initial position. This commitment is represented by Liquidity Commitment Certificates (LCCs), lcc-USDC and lcc-ETH, which encapsulate the settled collateral ($20,000) and the remaining VRL ($980,000) verified via zero-knowledge proofs (zkTLS), enabling trading on the Fiet Market’s AMM with settlements triggered by market demand.

## Key Features

1. **ERC20 Compliance**: LCCs adhere to the ERC20 standard, enabling compatibility with Ethereum-based AMMs.
2. **Non-Transferable**: LCCs are protocol-bound bookkeeping units, restricted to Fiet’s integrated decentralised exchange (DEX), ensuring controlled liquidity commitments.
3. **Permissionless Creation**: LCCs can be created by any MM committing Verified Reserve Liquidity (VRL) to a Fiet Market.
4. **Fungibility**: LCCs are fungible for the same settlement token (e.g., all USDC-based LCCs are lcc-USDC), facilitating uniform trading within the DEX.
5. **Regulatory Alignment**: LCCs are designed as non-transferable assets distinct from stablecoins or securities, complying with regulatory frameworks.

## Parameters

LCCs in the Fiet Protocol are defined by deployment parameters set at market creation and order parameters passed during trades to the Proxy Pool. Deployment parameters are immutable and configure the core functionality, while order parameters allow dynamic behaviour for specific trades, such as handling excess LCCs.

### Deployment Parameters

1. **DEX Pool Manager:** References the smart contract(s) managing liquidity flow in the AMM. LCCs use this address to evaluate inflows to or outflows from the DEX. These addresses are whitelisted, permitting LCC settlements to these contracts and preventing user-to-user transfers.
2. **Settlement Token:** Specifies the ERC20 token address mirrored by the LCC (e.g., USDC on Arbitrum at `0xaf88d065e77c8cc2239327c5edb3a432268e5831`).
3. **Oracle:** Maps liquidity signal reserve tickers (e.g., “usd”) to smart contracts implementing the [IOracle interface](https://github.com/morpho-org/morpho-blue/blob/main/src/interfaces/IOracle.sol) adopted from the Morpho Blue protocol. These contracts evaluate the price of the signal reserve currency relative to the settlement token.

### Order Parameters

LCCs may change behaviour based on parameters passed along with market trade orders specifically to Proxy Pools. Proxy Pools pair native assets (e.g., ARB/USDT) and proxy orders to a fixed LCC-based core pool (e.g., lcc-ARB/lcc-USDT). These parameters change how LCCs are managed within the order logic. If these parameters are not present, then the Proxy Pool will restrict the available trade size to the amount of liquidity available and settled to the market. For example, an order of $50,000 USDT → ARB, without parameters present, against a market where only $20,000 ARB in USD value is realised (settled on-chain), will restrict the trade size to $20,000. This ensures smooth predictable behaviour for traders engaging the Proxy Pool without awareness of underlying Fiet functionality. However, if these parameters are present, it is presumed the trader or integrating smart contracts are aware of Fiet protocol logic, and therefore the trade size is not restricted and instead the full order is fulfilled. Excess LCCs received from the trade that cannot be immediately unwrapped for native assets will be handled as per the provided parameters.

**Recipient:** A `recipient` address indicates to the Proxy Pool where to transfer LCCs received. Occurs specifically when the market is incapable of immediate unwrap and settlement, due to insufficient atomic liquidity. Allows the recipient to receive whatever available liquidity there is, and LCCs as excess. Any excess LCC received will be automatically replaced by underlying settlement tokens once MMs settle accordingly in a future blockchain transaction.

## Constraints

### For Traders

To engage a Fiet Market (e.g., USDC/ETH), traders must wrap assets into LCCs, as the core AMM pool is an lcc-USDC/lcc-ETH pair. Alongside the core LCC-based pool, Fiet incorporates mechanics and integration with DEXs to abstract this, presenting the market as a USDC/ETH pair that routes trades to the core lcc-USDC/lcc-ETH pool. In extensible AMMs such as Uniswap v4, this is conducted with corresponding proxy pools.

Traders can only:

1. Use LCCs on Fiet’s integrated DEX, mirroring the settlement token.
2. Exercise LCCs to redeem the underlying settlement token.

LCCs cannot be transferred between wallets or users. This constraint ensures regulatory compliance by distinguishing LCCs from stablecoins or other crypto assets and enables accurate Value-to-Signal (VTS) ratio tracking by differentiating traders’ DEX liquidity from wrapped liquidity. VTS ratios are tracked per token at the position level, not within LCCs.

### For Market Makers

Market makers (MMs) committing VRL to a Fiet Market will simultaneously and automatically create a liquidity position in the AMM. VRL cannot be committed to generate LCCs without this position, preventing arbitrary LCC management outside market operations. The split of this commitment between the paired tokens is determined by the underlying AMM’s liquidity mathematics, which calculates the allocation based on the current market price and pool state, ensuring alignment with the protocol’s trading dynamics.

Fiet’s smart contracts hold AMM liquidity position receipts on behalf of MMs, issuing a transferable receipt non-fungible token (NFT) to the MM, referencing their commitment. This NFT allows flexibility in managing position parameters and settlement obligations across wallets. Fiet proxies AMM liquidity position management functions, retaining all default configurability.

To decommit from a market, MMs:

1. Burn the Fiet Market Position NFT.
2. Liquidate the AMM liquidity position via the protocol.
3. Withdraw tokens, including fees, from the protocol.
4. Drop the VRL signal.
5. Update VRL state across Market Chains with a dropped signal message, incurring no penalties if no commitments remain.

MMs cannot decommit liquidity subject to an open Request for Settlement (RfS). Such liquidity and associated collateral remain locked until settled by the MM or a Settlement Guarantor.

## Settlement Queue

As LCCs are received from Fiet Markets, a condition applies to this subset amount of LCC, which is whether it is placed into a settlement queue.

The settlement queue addresses scenarios where immediate unwrapping of LCCs to their underlying settlement tokens is not possible due to insufficient settled liquidity at the time of a trade. This mechanism is necessary to maintain traceability and fairness in liquidity allocation, ensuring that traders receive the tokens they are entitled to without mixing settlements from unrelated sources. It solves the challenge of handling pending obligations in a decentralised system, where market makers' settlements may lag behind trader demand, while preventing disruptions to trading flow.

When a trader swaps directly with the LCC-based Core Pool, the inflow token's underlying liquidity moves "in-market" to support the pool. For the outflow token, the protocol attempts to allocate settled liquidity to the LCC for unwrapping. If insufficient, the shortfall is recorded as pending, queued chronologically for resolution. Pending items are traced to specific markets and users, based on how the LCC was acquired (e.g., from a particular swap), to ensure settlements are directed appropriately — traders acquiring LCCs from a market expect liquidity tied to that market's activity.

Market makers' settlements clear the queue, prioritising outstanding pending items before allocating excess to the market. Traders with Direct Liquidity Provider (LP) positions can unwrap immediately, as their interactions do not accrue pending items. If a trader takes further action with queued LCCs (e.g., in another swap), the pending item is cleared to reflect the updated state. This queue enables full order fulfilment without restricting trade sizes, abstracting complexity for traders while upholding protocol integrity.

## Compared with Leverage or Margin?

Fiet’s Liquidity Commitment Certificates (LCCs) may appear akin to leveraged positions, as committing a small collateral (e.g., 2% or $20,000 USDC) facilitates deployment of $1,000,000 in liquidity as lcc-USDC. However, LCCs involve neither leverage nor margin, as the protocol entails no borrowing, debt creation, or amplified exposure to price movements. Instead, LCCs encapsulate Verified Reserve Liquidity (VRL) owned by the market maker, attested via zkTLS proofs.

Distinctions include:

- Absence of Borrowing: Unlike perpetual futures platforms, where collateral (e.g., $2,000) supports borrowing $98,000 for 50x leverage, Fiet requires no loans. MMs facilitate liquidity from their verified reserves, without third-party funding.
- Operational Risk Focus: Seizure arises from failure to settle, an operational lapse, rather than price-driven liquidations. While price fluctuations can indirectly contribute — if a mismatch exists between the signal reserve currency (e.g., USD) and settlement token (e.g., ETH), such as an ETH price spike rendering the committed amount insolvent relative to the signalled value — this triggers seizure only through resultant non-delivery, not automated margin calls.
- Protocol-Bound Synthetic: lcc-USDC functions as a non-transferable token bound to Fiet’s ecosystem, backed by attested reserves, not a derivative position betting on asset prices.
- Collateral Function: The initial base Value-to-Signal rate (eg., 2%) serves to anchor the commitment and incentivise guarantors, not as margin against borrowed funds.
- Demand-Driven Settlement: MMs deliver tokens from reserves in response to trader activity, without repayment obligations. Settlement Guarantors intervene for non-fulfilment, claiming proportional position shares, distinct from closing leveraged trades.

This framework supports substantial liquidity facilitation without introducing debt or speculative amplification, prioritising verified commitments over financial gearing.