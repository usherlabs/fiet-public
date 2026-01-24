#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]

#[cfg(not(any(test, feature = "export-abi")))]
#[no_mangle]
pub extern "C" fn main() {}

/// ABI export entrypoint used by `cargo stylus export-abi`.
#[cfg(feature = "export-abi")]
fn main() {
    use stylus_sdk::abi::export::print_abi;

    // The ABI surface is derived from the `#[public]` impls on `IntentPolicy`.
    use fiet_maker_policy::IntentPolicy;

    print_abi::<IntentPolicy>("BUSL-1.1", "pragma solidity ^0.8.23;");
}


