# Surety

## Contract addresses

### LCC tokens
- Itoken USDC: [0xf38B489ac21BC30A5246D4a19Dad730D4d394b62](https://sepolia.arbiscan.io/address/0xf38B489ac21BC30A5246D4a19Dad730D4d394b62#code)
- Itoken USDT: [0xdfb445E174fD89C9919546C358C20DB780708686](https://sepolia.arbiscan.io/address/0xdfb445E174fD89C9919546C358C20DB780708686#code)

### Mock tokens
USDC:[0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d](https://sepolia.arbiscan.io/address/0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d)
USDT:[0x382ED578cFBA5A1FfDD83a71CF69a00A6abaA308](https://sepolia.arbiscan.io/address/0x382ED578cFBA5A1FfDD83a71CF69a00A6abaA308)

### Uniswap V4 Core Pool LCC-USDC/LCC-USDT
Pool id: 0xd0949d0917e91bf6167299bf4ca9c816fe4a535a0cfa319562056874f71a9b22

### Uniswap V4 Proxy Pool USDC/USDT
Pool id: 0x57df887f55f6ea24964ede5be11d58900c3f5adf85499c216a3506a3c52a8c77

### Uniswap V4 Proxy hook
[0x466Cc3d82942a19568bbC9FCBb748F044CF96888](https://sepolia.arbiscan.io/address/0x466Cc3d82942a19568bbC9FCBb748F044CF96888#code)
## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

## To delpoy this locally on Arbitrum fork

### Run fork
See .env.example for required variables
```shell
$ make fork
```

### Deploy contracts
Case sensitive

```shell
$ make all MODE=LOCAL
```

