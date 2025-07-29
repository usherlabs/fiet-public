use alloy::primitives::Address;

// Network constants derived from solidity/script/constants/
#[derive(Debug, Clone)]
pub struct NetworkConstants {
    pub pool_manager: Address,
    pub position_manager: Address,
    pub rpc_url: &'static str,
}

impl NetworkConstants {
    pub fn arbitrum() -> Self {
        Self {
            pool_manager: "0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32"
                .parse()
                .expect("Invalid pool manager address"),
            position_manager: "0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869"
                .parse()
                .expect("Invalid position manager address"),
            rpc_url: "https://arb1.arbitrum.io/rpc",
        }
    }

    pub fn arbitrum_sepolia() -> Self {
        Self {
            pool_manager: "0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317"
                .parse()
                .expect("Invalid pool manager address"),
            position_manager: "0xAc631556d3d4019C95769033B5E719dD77124BAc"
                .parse()
                .expect("Invalid position manager address"),
            rpc_url: "https://sepolia-rollup.arbitrum.io/rpc",
        }
    }

    pub fn eth_sepolia() -> Self {
        Self {
            pool_manager: "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543"
                .parse()
                .expect("Invalid pool manager address"),
            position_manager: "0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4"
                .parse()
                .expect("Invalid position manager address"),
            rpc_url: "https://rpc.sepolia.org",
        }
    }
}

#[derive(Debug, Clone)]
pub struct UniswapActions {
    pub burn_position: u8,
    pub mint_position: u8,
    pub take_pair: u8,
}

impl UniswapActions {
    pub fn new() -> Self {
        Self {
            burn_position: 0x03,
            mint_position: 0x02,
            take_pair: 0x11,
        }
    }
}
