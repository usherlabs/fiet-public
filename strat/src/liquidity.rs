use alloy::primitives::U256;

pub fn mul_div(x: U256, y: U256, d: U256) -> U256 {
    // Simple implementation for illustration; replace with proper wide mul_div in production
    (x * y) / d
}

pub fn get_amount0_for_liquidity(sqrt_a: U256, sqrt_b: U256, liquidity: u128) -> U256 {
    let mut a = sqrt_a;
    let mut b = sqrt_b;
    if a > b {
        std::mem::swap(&mut a, &mut b);
    }
    let liq = U256::from(liquidity);
    // let q96 = U256::ONE << 96;
    mul_div(liq << 96, b - a, b) / a
}

pub fn get_amount1_for_liquidity(sqrt_a: U256, sqrt_b: U256, liquidity: u128) -> U256 {
    let mut a = sqrt_a;
    let mut b = sqrt_b;
    if a > b {
        std::mem::swap(&mut a, &mut b);
    }
    let liq = U256::from(liquidity);
    let q96 = U256::ONE << 96;
    mul_div(liq, b - a, q96)
}

pub fn get_amounts_for_liquidity(
    sqrt_price: U256,
    mut sqrt_a: U256,
    mut sqrt_b: U256,
    liquidity: u128,
) -> eyre::Result<(U256, U256)> {
    if sqrt_a > sqrt_b {
        std::mem::swap(&mut sqrt_a, &mut sqrt_b);
    }
    let mut amount0 = U256::ZERO;
    let mut amount1 = U256::ZERO;
    if sqrt_price <= sqrt_a {
        amount0 = get_amount0_for_liquidity(sqrt_a, sqrt_b, liquidity);
    } else if sqrt_price < sqrt_b {
        amount0 = get_amount0_for_liquidity(sqrt_price, sqrt_b, liquidity);
        amount1 = get_amount1_for_liquidity(sqrt_a, sqrt_price, liquidity);
    } else {
        amount1 = get_amount1_for_liquidity(sqrt_a, sqrt_b, liquidity);
    }
    Ok((amount0, amount1))
}

pub fn get_liquidity_for_amount0(sqrt_a: U256, sqrt_b: U256, amount0: U256) -> u128 {
    let mut a = sqrt_a;
    let mut b = sqrt_b;
    if a > b {
        std::mem::swap(&mut a, &mut b);
    }
    let q96 = U256::ONE << 96;
    let intermediate = mul_div(a, b, q96);
    let res = mul_div(amount0, intermediate, b - a);
    res.to::<u128>()
}

pub fn get_liquidity_for_amount1(sqrt_a: U256, sqrt_b: U256, amount1: U256) -> u128 {
    let mut a = sqrt_a;
    let mut b = sqrt_b;
    if a > b {
        std::mem::swap(&mut a, &mut b);
    }
    let q96 = U256::ONE << 96;
    let res = mul_div(amount1, q96, b - a);
    res.to::<u128>()
}

pub fn get_liquidity_for_amounts(
    sqrt_price: U256,
    mut sqrt_a: U256,
    mut sqrt_b: U256,
    amount0: U256,
    amount1: U256,
) -> eyre::Result<u128> {
    if sqrt_a > sqrt_b {
        std::mem::swap(&mut sqrt_a, &mut sqrt_b);
    }
    let liquidity: u128;
    if sqrt_price <= sqrt_a {
        liquidity = get_liquidity_for_amount0(sqrt_a, sqrt_b, amount0);
    } else if sqrt_price < sqrt_b {
        let liquidity0 = get_liquidity_for_amount0(sqrt_price, sqrt_b, amount0);
        let liquidity1 = get_liquidity_for_amount1(sqrt_a, sqrt_price, amount1);
        liquidity = liquidity0.min(liquidity1);
    } else {
        liquidity = get_liquidity_for_amount1(sqrt_a, sqrt_b, amount1);
    }
    Ok(liquidity)
}

pub fn get_sqrt_price_at_tick(tick: i32) -> eyre::Result<U256> {
    // Implementation as above
    let abs_tick = tick.abs() as u64;
    let mut ratio = if abs_tick & 1 != 0 {
        U256::from_str_radix("fffcb933bd6fad37aa2d162d1a594001", 16)?
    } else {
        U256::ONE << 128
    };

    // Update ratio for each bit (as in the macro)
    let ratios = [
        (0x2, "fff97272373d413259a46990580e213a"),
        (0x4, "fff2e50f5f656932ef12357cf3c7fdcc"),
        (0x8, "ffe5caca7e10e4e61c3624eaa0941cd0"),
        (0x10, "ffcb9843d60f6159c9db58835c926644"),
        (0x20, "ff973b41fa98c081472e6896dfb254c0"),
        (0x40, "ff2ea16466c96a3843ec78b326b52861"),
        (0x80, "fe5dee046a99a2a811c461f1969c3053"),
        (0x100, "fcbe86c7900a88aedcffc83b479aa3a4"),
        (0x200, "f987a7253ac413176f2b074cf7815e54"),
        (0x400, "f3392b0822b70005940c7a398e4b70f3"),
        (0x800, "e7159475a2c29b7443b29c7fa6e889d9"),
        (0x1000, "d097f3bdfd2022b8845ad8f792aa5825"),
        (0x2000, "a9f746462d870fdf8a65dc1f90e061e5"),
        (0x4000, "70d869a156d2a1b890bb3df62baf32f7"),
        (0x8000, "31be135f97d08fd981231505542fcfa6"),
        (0x10000, "9aa508b5b7a84e1c677de54f3e99bc9"),
        (0x20000, "5d6af8dedb81196699c329225ee604"),
        (0x40000, "2216e584f5fa1ea926041bedfe98"),
        (0x80000, "48a170391f7dc42444e8fa2"),
    ];

    for (mask, mul_str) in ratios {
        if abs_tick & mask != 0 {
            let mul = U256::from_str_radix(mul_str, 16)?;
            ratio = (ratio * mul) >> 128;
        }
    }

    if tick > 0 {
        ratio = U256::MAX / ratio;
    }

    let sqrt_price_x96 = (ratio >> 32)
        + if ratio % (U256::ONE << 32) == U256::ZERO {
            U256::ZERO
        } else {
            U256::ONE
        };

    Ok(sqrt_price_x96)
}
