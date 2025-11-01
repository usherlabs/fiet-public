use ethers::types::{Address, U256};

pub fn remove_0x(input: &String) -> String {
    input.strip_prefix("0x").unwrap_or(&input).to_string()
}

pub fn value_in_wei(unit: u128) -> U256 {
    return U256::from(unit * 10e18 as u128);
}

pub fn hex_to_address(address_hex_string: &String) -> Address {
    let deployer = hex::decode(remove_0x(&address_hex_string)).unwrap();
    let sender: &[u8; 20] = deployer.as_slice().try_into().unwrap();

    let sender = Address::from(sender);

    return sender;
}
