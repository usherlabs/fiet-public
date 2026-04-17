# Echidna linked libraries

**Medusa note:** the [`FuzzEntry`](../FuzzEntry.sol) path (`just medusa-mmq-01`, [`medusa.json`](../../../medusa.json)) does **not**
use this prepare pipeline — it compiles `FuzzEntry.sol` only and needs no converged linker map.

---

Fuzz harnesses use **hard-linked library addresses** so Foundry’s linker and HEVM resolve `DELEGATECALL` targets
deterministically. Harness constructors deploy matching code at the same addresses via CREATE2
(`test/fuzz/base/EchidnaLinkedLibs.sol`).

## Runtime flow

You normally do **nothing** manually: `scripts/echidna.sh` runs `scripts/echidna_prepare_linked_libs.py`, which generates
`.echidna-gen/foundry.toml`, converges the linker map using **`GenerateEchidnaLinkedLibAddresses.printManifest()`**
([`GenerateEchidnaLinkedLibAddresses.s.sol`](./GenerateEchidnaLinkedLibAddresses.s.sol)), builds, and runs
`SmokeEchidnaLinkedLibs`.

To run only that step:

```bash
cd contracts/evm && just echidna-prepare
```

## Troubleshooting

- **`EchidnaLinkedLibs` … `AddrMismatch`**: the prepare step failed or you ran `forge build` with `FOUNDRY_PROFILE=echidna`
  without `FOUNDRY_CONFIG` set to `.echidna-gen/foundry.toml`. Re-run `just echidna-prepare` or invoke Echidna via
  `just echidna …` / `scripts/echidna.sh`.
- **Skip prepare** (advanced): `ECHIDNA_SKIP_PREPARE=1` — you must set `FOUNDRY_CONFIG` yourself and ensure
  `out-echidna/` matches that build.

## Why CREATE2 addresses change when bytecode changes

CREATE2 address = `keccak256(0xff || deployer || salt || keccak256(initCode))`. Any change to a library or its
dependencies changes `initCode` and therefore the address. The prepare script re-converges the fixed-point whenever
you run Echidna.
