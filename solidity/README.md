# Surety

## Contract addresses

### LCC tokens
- Itoken USDC: [0x4D8232aCA5264c6D9b906a9b1620230563BbdaC6](https://sepolia.arbiscan.io/address/0x4D8232aCA5264c6D9b906a9b1620230563BbdaC6#code)
- Itoken USDT: [0xa0Ec9d4AEbD41006e78dcBc956dbfE730faCf4B3](https://sepolia.arbiscan.io/address/0xa0Ec9d4AEbD41006e78dcBc956dbfE730faCf4B3#code)

### Mock tokens
USDC:[0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d](https://sepolia.arbiscan.io/address/0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d)
USDT:[0x382ED578cFBA5A1FfDD83a71CF69a00A6abaA308](https://sepolia.arbiscan.io/address/0x382ED578cFBA5A1FfDD83a71CF69a00A6abaA308)

### Uniswap V4 Core Pool LCC-USDC/LCC-USDT
Pool id: 0x3fc0b322dbe783ce0ead4f96816dbd4b06bf4448cd1833b9c6563c4002990a6f

### Uniswap V4 Proxy Pool USDC/USDT
Pool id: 0x5266fbefabdcf2f1306638431b40bbc9565ee0bb3c92071761387f694282ba86

### Uniswap V4 Proxy hook
[0x3A8d28B65085A7F916198dD6339d1Ba0Dd942888](https://sepolia.arbiscan.io/address/0x3A8d28B65085A7F916198dD6339d1Ba0Dd942888#code)
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
$ make add MODE=LOCAL
```

