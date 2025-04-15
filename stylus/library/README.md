# 🧱 Fiet Library

A lightweight utility library for the [Fiet Protocol](https://fiet.xyz), designed for use in Arbitrum Stylus contracts. This crate provides core primitives and helper traits for working with roles, currencies, stages, and deterministic hashing within the protocol.

---

## ✨ Features

- **Currency Enum**: Hardcoded ISO 4217 currency support (`NGN`, `AUD`) with string formatting and hashing.
- **Role Enum**: Defines participant roles (`Custodian`, `LP`) and provides hashed identifiers.
- **RFS Stages**: Enum representing the lifecycle stages of a Request For Settlement (RFS).
- **Hashable Trait**: Generic trait that enables Keccak256 hashing of any `ToString`-compatible type.

---

## 📦 Modules

### `Currency`

Defines supported currencies and provides utilities for string formatting and hashing.

```rust
    use fiet_library::currency::Currency;

    let ngn = Currency::NGN;
    println!("{}", ngn);          // "NGN"
    let hash = ngn.hash();        // Keccak256 hash of "NGN"
```

### `Core`

Contains core protocol enums:
- Role: Identifies actors in the protocol (Custodian, LP)
- RFSStage: Enum for tracking the stage of a settlement lifecycle

```rust
    use fiet_library::core::{Role, RFSStage};

    let role = Role::Custodian;
    println!("{}", role);              // "CUSTODIAN"
    let hash = role.hash();            // Keccak256 hash of "CUSTODIAN"

    let stage = RFSStage::BIDDING;
    println!("{}", stage.as_u8());     // 1
```

### `Traits`

Provides the Hashable trait for generating deterministic Keccak256 hashes.
- Role: Identifies actors in the protocol (Custodian, LP)
- RFSStage: Enum for tracking the stage of a settlement lifecycle

```rust
    use fiet_library::core::{Role, RFSStage};

    let role = Role::Custodian;
    println!("{}", role);              // "CUSTODIAN"
    let hash = role.hash();            // Keccak256 hash of "CUSTODIAN"

    let stage = RFSStage::BIDDING;
    println!("{}", stage.as_u8());     // 1
```

## Usage

Add to your Stylus contract's Cargo.toml:
```toml
fiet-library = { path = "../fiet-library" }
```
Then import it into your contract:

```rust
use fiet_library::{currency::Currency, core::Role, traits::Hashable};
```
