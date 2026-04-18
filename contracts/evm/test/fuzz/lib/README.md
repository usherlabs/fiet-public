# Runtime library facades (Medusa / `FuzzEntry`)

Echidna harnesses that call production **`library`** code linked at compile time use
[`echidna_prepare_linked_libs.py`](../../scripts/echidna_prepare_linked_libs.py) and CREATE2 deploy helpers in
[`../base/EchidnaLinkedLibs.sol`](../base/EchidnaLinkedLibs.sol).

The **Bunni-style** [`FuzzEntry.sol`](../FuzzEntry.sol) path avoids that pipeline by:

- composing fuzz modules (`FuzzMMQ01`, future `FuzzVTSPosition` actions), and
- using **`new`** in constructors / actions for mocks and thin harnesses.

For VTS **linked** libraries (`VTSPositionLib`, `VTSPositionMMOpsLib`, `VTSLifecycleLinkedLib`, `VTSCommitLib`, …), full
production paths use `VTSStorage` and delegatecall wiring; migrating those to Medusa typically means **new harness
contracts** that mirror call shapes, or thin **facade contracts** deployed at runtime (this folder is the home for such
stubs as they are added).

Current stubs: [`VTSLinkedLibWrappers.sol`](VTSLinkedLibWrappers.sol) (placeholders + documentation only).
