#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ECHIDNA_LINKED_LIBS_PATH = ROOT / "test/fuzz/base/EchidnaLinkedLibs.sol"
FOUNDRY_TOML_PATH = ROOT / "foundry.toml"

CONSTANT_TO_LIBRARY = {
    "LCC_FACTORY_LINKED_LIB": "src/libraries/LCCFactoryLib.sol:LCCFactoryLinkedLib",
    "LIQUIDITY_HUB_LINKED_LIB": "src/libraries/LiquidityHubLinkedLib.sol:LiquidityHubLinkedLib",
    "VTS_COMMIT_LIB": "src/libraries/VTSCommitLib.sol:VTSCommitLib",
    "VTS_FEE_LINKED_LIB": "src/libraries/VTSFeeLib.sol:VTSFeeLinkedLib",
    "VTS_POSITION_LIB": "src/libraries/VTSPositionLib.sol:VTSPositionLib",
    "VTS_LIFECYCLE_LINKED_LIB": "src/libraries/VTSLifecycleLinkedLib.sol:VTSLifecycleLinkedLib",
}


def _extract_constants(source: str) -> dict[str, str]:
    matches = re.findall(r"address internal constant (\w+) = (0x[a-fA-F0-9]{40});", source)
    return {name: address.lower() for name, address in matches}


def _extract_echidna_libraries(source: str) -> dict[str, str]:
    profile_match = re.search(r"^\[profile\.echidna\]\n(.*?)(?=^\[|\Z)", source, re.MULTILINE | re.DOTALL)
    if profile_match is None:
        raise ValueError("missing [profile.echidna] block")

    libraries_match = re.search(r"libraries\s*=\s*\[(.*?)\]", profile_match.group(1), re.DOTALL)
    if libraries_match is None:
        raise ValueError("missing [profile.echidna].libraries block")

    entries: dict[str, str] = {}
    for raw_entry in re.findall(r'"([^"]+)"', libraries_match.group(1)):
        try:
            library, address = raw_entry.rsplit(":", 1)
        except ValueError as exc:
            raise ValueError(f"malformed libraries entry: {raw_entry}") from exc
        entries[library] = address.lower()

    return entries


def main() -> int:
    constants_source = ECHIDNA_LINKED_LIBS_PATH.read_text()
    foundry_source = FOUNDRY_TOML_PATH.read_text()

    constants = _extract_constants(constants_source)
    echidna_libraries = _extract_echidna_libraries(foundry_source)

    errors: list[str] = []
    for constant_name, library_path in CONSTANT_TO_LIBRARY.items():
        expected = constants.get(constant_name)
        if expected is None:
            errors.append(f"missing constant `{constant_name}` in `{ECHIDNA_LINKED_LIBS_PATH.relative_to(ROOT)}`")
            continue

        actual = echidna_libraries.get(library_path)
        if actual is None:
            errors.append(f"missing `{library_path}` in `[profile.echidna].libraries`")
            continue

        if actual != expected:
            errors.append(
                f"`{library_path}` mismatch: foundry.toml has {actual}, "
                f"but EchidnaLinkedLibs.sol has {expected} (`{constant_name}`)"
            )

    if errors:
        print("Echidna linked-library wiring is out of sync:")
        for error in errors:
            print(f"- {error}")
        print("Run `just recompute-fuzz-lib-addrs` if the bytecode changed, then update both files.")
        return 1

    print("Echidna linked-library wiring is aligned.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
