use alloy::primitives::{Address, U256};

pub fn parse_revert_error(data: &[u8]) -> String {
    if data.len() < 4 {
        return format!("Invalid revert data: {:?}", data);
    }
    let selector = &data[0..4];
    let params = &data[4..];
    match selector {
        &[0x0c, 0xa9, 0x68, 0xd8] => {
            // NotApproved(address)
            if params.len() >= 32 {
                let caller = Address::from_slice(&params[12..32]);
                format!("NotApproved({:?})", caller)
            } else {
                "NotApproved(invalid params)".to_string()
            }
        }
        &[0x3b, 0x99, 0xb5, 0x3d] => "SliceOutOfBounds".to_string(),
        &[0x01, 0x18, 0x21, 0x0a] => {
            // DeadlinePassed(uint256)
            if params.len() >= 32 {
                let deadline = U256::from_be_slice(&params[0..32]);
                format!("DeadlinePassed({})", deadline)
            } else {
                "DeadlinePassed(invalid params)".to_string()
            }
        }
        &[0x0c, 0x36, 0x0c, 0x1a] => "PoolManagerMustBeLocked".to_string(),
        &[0x4e, 0x48, 0x7b, 0x71] => {
            // General revert (Panic(uint256))
            if params.len() >= 32 {
                let code = U256::from_be_slice(&params[0..32]);
                format!("Panic({})", code)
            } else {
                "Panic(invalid params)".to_string()
            }
        }
        &[0x3b, 0x4d, 0xa4, 0x4c] => {
            // UnsupportedAction(uint256)
            if params.len() >= 32 {
                let action = U256::from_be_slice(&params[0..32]);
                format!("UnsupportedAction({})", action)
            } else {
                "UnsupportedAction(invalid params)".to_string()
            }
        }
        _ => format!("Unknown error selector: {:?}", selector),
    }
}
