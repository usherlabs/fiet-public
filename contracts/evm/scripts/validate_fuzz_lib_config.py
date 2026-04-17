#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ECHIDNA_LINKED_LIBS_PATH = ROOT / "test/fuzz/base/EchidnaLinkedLibs.sol"
FOUNDRY_TOML_PATH = ROOT / "foundry.toml"
MANIFEST_PATH = ROOT / "test/fuzz/echidna-linked-libs.txt"
VALIDATE_SCRIPT = "test/fuzz/script/ValidateEchidnaLinkedLibs.s.sol:ValidateEchidnaLinkedLibs"

MANIFEST_HEADER = """# Single source of truth for Medusa [profile.medusa] hard-linked libraries.
# Updated by `just recompute-fuzz-lib-addrs` (converges linked initcode) or `just print-fuzz-lib-manifest`.
# One line per library: src/path/File.sol:Symbol=0x...
# VTSSwapLib is a fixed placeholder (not CREATE2-validated in harness helpers).
"""

# Maps Solidity constant name -> foundry library id (path:Symbol)
CONSTANT_TO_LIBRARY: dict[str, str] = {
    "LCC_FACTORY_LINKED_LIB": "src/libraries/LCCFactoryLib.sol:LCCFactoryLinkedLib",
    "LIQUIDITY_HUB_LINKED_LIB": "src/libraries/LiquidityHubLinkedLib.sol:LiquidityHubLinkedLib",
    "VTS_COMMIT_LIB": "src/libraries/VTSCommitLib.sol:VTSCommitLib",
    "VTS_FEE_LINKED_LIB": "src/libraries/VTSFeeLib.sol:VTSFeeLinkedLib",
    "VTS_POSITION_LIB": "src/libraries/VTSPositionLib.sol:VTSPositionLib",
    "VTS_LIFECYCLE_LINKED_LIB": "src/libraries/VTSLifecycleLinkedLib.sol:VTSLifecycleLinkedLib",
    "VTS_POSITION_MM_OPS_LIB": "src/libraries/VTSPositionMMOpsLib.sol:VTSPositionMMOpsLib",
}

# Order and keys written to foundry.toml [profile.medusa].libraries (includes VTSSwap placeholder).
ECHIDNA_LIBRARY_IDS: list[str] = [
    "src/libraries/LCCFactoryLib.sol:LCCFactoryLinkedLib",
    "src/libraries/LiquidityHubLinkedLib.sol:LiquidityHubLinkedLib",
    "src/libraries/VTSCommitLib.sol:VTSCommitLib",
    "src/libraries/VTSFeeLib.sol:VTSFeeLinkedLib",
    "src/libraries/VTSPositionLib.sol:VTSPositionLib",
    "src/libraries/VTSLifecycleLinkedLib.sol:VTSLifecycleLinkedLib",
    "src/libraries/VTSPositionMMOpsLib.sol:VTSPositionMMOpsLib",
    "src/libraries/VTSSwapLib.sol:VTSSwapLib",
]


def _extract_constants(source: str) -> dict[str, str]:
    matches = re.findall(r"address internal constant (\w+) = (0x[a-fA-F0-9]{40});", source)
    return {name: address.lower() for name, address in matches}


def _extract_echidna_libraries(source: str) -> dict[str, str]:
    profile_match = re.search(r"^\[profile\.medusa\]\n(.*?)(?=^\[|\Z)", source, re.MULTILINE | re.DOTALL)
    if profile_match is None:
        raise ValueError("missing [profile.medusa] block")

    libraries_match = re.search(r"libraries\s*=\s*\[(.*?)\]", profile_match.group(1), re.DOTALL)
    if libraries_match is None:
        raise ValueError("missing [profile.medusa].libraries block")

    entries: dict[str, str] = {}
    for raw_entry in re.findall(r'"([^"]+)"', libraries_match.group(1)):
        try:
            library, address = raw_entry.rsplit(":", 1)
        except ValueError as exc:
            raise ValueError(f"malformed libraries entry: {raw_entry}") from exc
        entries[library] = address.lower()

    return entries


def _parse_manifest(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"manifest line must be path:Symbol=0x...: {raw_line!r}")
        key, _, addr = line.partition("=")
        key = key.strip()
        addr = addr.strip()
        if not re.fullmatch(r"0x[a-fA-F0-9]{40}", addr):
            raise ValueError(f"invalid address in manifest: {raw_line!r}")
        out[key] = addr.lower()
    return out


def _forge_env() -> dict[str, str]:
    env = os.environ.copy()
    env["FOUNDRY_PROFILE"] = "medusa"
    return env


def _forge_build_echidna() -> None:
    # [profile.medusa] uses `out = "out-medusa"`. Incremental caches can skip recompiling
    # EchidnaLinkedLibs.sol after manifest apply, leaving stale constants in linked artifacts.
    out_echidna = ROOT / "out-medusa"
    if out_echidna.exists():
        shutil.rmtree(out_echidna)

    result = subprocess.run(
        ["forge", "build"],
        cwd=ROOT,
        env=_forge_env(),
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)
        raise RuntimeError("forge build (FOUNDRY_PROFILE=medusa) failed")


def _run_forge_script(sig: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["forge", "script", VALIDATE_SCRIPT, "--sig", sig],
        cwd=ROOT,
        env=_forge_env(),
        capture_output=True,
        text=True,
        check=False,
    )


def _parse_manifest_from_forge_output(text: str) -> dict[str, str]:
    begin, end = "FUZZ_LIB_MANIFEST_BEGIN", "FUZZ_LIB_MANIFEST_END"
    if begin not in text or end not in text:
        raise ValueError("forge output missing FUZZ_LIB_MANIFEST_BEGIN/END markers")
    chunk = text.split(begin, 1)[1].split(end, 1)[0]
    out: dict[str, str] = {}
    for raw in chunk.splitlines():
        line = raw.strip()
        if not line or not line.startswith("src/"):
            continue
        if "=" not in line:
            continue
        key, _, addr = line.partition("=")
        key = key.strip()
        addr = addr.strip()
        if not re.fullmatch(r"0x[a-fA-F0-9]{40}", addr):
            continue
        out[key] = addr.lower()
    if len(out) < len(ECHIDNA_LIBRARY_IDS):
        raise ValueError(f"parsed manifest incomplete: got {sorted(out.keys())}")
    return out


def _write_manifest_file(manifest: dict[str, str]) -> None:
    lines = [MANIFEST_HEADER.rstrip(), ""]
    for lib_id in ECHIDNA_LIBRARY_IDS:
        lines.append(f"{lib_id}={manifest[lib_id].lower()}")
    lines.append("")
    MANIFEST_PATH.write_text("\n".join(lines))


def _to_checksum_address(address_lower: str) -> str:
    result = subprocess.run(
        ["cast", "to-check-sum-address", address_lower],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)
        raise RuntimeError(f"cast to-check-sum-address failed for `{address_lower}`")
    return result.stdout.strip()


def _validate_manifest_against_files(manifest: dict[str, str]) -> list[str]:
    errors: list[str] = []
    for lib_id in ECHIDNA_LIBRARY_IDS:
        if lib_id not in manifest:
            errors.append(f"missing `{lib_id}` in `{MANIFEST_PATH.relative_to(ROOT)}`")

    unknown = set(manifest.keys()) - set(ECHIDNA_LIBRARY_IDS)
    for key in sorted(unknown):
        errors.append(f"unknown manifest key `{key}` (typo or stale entry)")

    constants_source = ECHIDNA_LINKED_LIBS_PATH.read_text()
    foundry_source = FOUNDRY_TOML_PATH.read_text()
    constants = _extract_constants(constants_source)
    echidna_libraries = _extract_echidna_libraries(foundry_source)

    for constant_name, library_path in CONSTANT_TO_LIBRARY.items():
        m = manifest.get(library_path)
        if m is None:
            continue
        c = constants.get(constant_name)
        if c is None:
            errors.append(f"missing constant `{constant_name}` in `{ECHIDNA_LINKED_LIBS_PATH.relative_to(ROOT)}`")
            continue
        if c != m:
            errors.append(
                f"manifest `{library_path}` ({m}) does not match "
                f"`{constant_name}` in EchidnaLinkedLibs.sol ({c})"
            )

        t = echidna_libraries.get(library_path)
        if t is None:
            errors.append(f"missing `{library_path}` in `[profile.medusa].libraries`")
        elif t != m:
            errors.append(
                f"manifest `{library_path}` ({m}) does not match foundry.toml ({t})"
            )

    # VTSSwapLib only in foundry + manifest
    swap_id = "src/libraries/VTSSwapLib.sol:VTSSwapLib"
    if swap_id in manifest:
        t = echidna_libraries.get(swap_id)
        m = manifest[swap_id]
        if t is None:
            errors.append(f"missing `{swap_id}` in `[profile.medusa].libraries`")
        elif t != m:
            errors.append(f"manifest `{swap_id}` ({m}) does not match foundry.toml ({t})")

    return errors


def _validate_sync() -> int:
    try:
        manifest = _parse_manifest(MANIFEST_PATH.read_text())
    except FileNotFoundError:
        print(f"Missing manifest `{MANIFEST_PATH.relative_to(ROOT)}`.")
        print("Create it from `just print-fuzz-lib-manifest` output, then `just recompute-fuzz-lib-addrs`.")
        return 1
    except (ValueError, RuntimeError) as exc:
        print(f"Manifest error: {exc}")
        return 1

    errors = _validate_manifest_against_files(manifest)
    if errors:
        print("Fuzz linked-library wiring is out of sync with the manifest:")
        for error in errors:
            print(f"- {error}")
        print(f"Update `{MANIFEST_PATH.relative_to(ROOT)}` from `just print-fuzz-lib-manifest`, then:")
        print("  just recompute-fuzz-lib-addrs")
        return 1

    print("Fuzz linked-library manifest matches foundry.toml and EchidnaLinkedLibs.sol.")
    return 0


def _build_libraries_toml_inner(manifest: dict[str, str]) -> str:
    def addr(lib_id: str) -> str:
        return manifest[lib_id]

    lines: list[str] = []
    lines.append(f'  "src/libraries/LCCFactoryLib.sol:LCCFactoryLinkedLib:{addr("src/libraries/LCCFactoryLib.sol:LCCFactoryLinkedLib")}",')
    lines.append(f'  "src/libraries/LiquidityHubLinkedLib.sol:LiquidityHubLinkedLib:{addr("src/libraries/LiquidityHubLinkedLib.sol:LiquidityHubLinkedLib")}",')
    lines.append(
        "  # Prevent unlinked placeholders in unrelated contracts (e.g. VTSOrchestrator)."
    )
    lines.append("  # Deterministic CREATE2 address deployed by the SIG-BACKING harness.")
    lines.append(f'  "src/libraries/VTSCommitLib.sol:VTSCommitLib:{addr("src/libraries/VTSCommitLib.sol:VTSCommitLib")}",')
    lines.append(f'  "src/libraries/VTSFeeLib.sol:VTSFeeLinkedLib:{addr("src/libraries/VTSFeeLib.sol:VTSFeeLinkedLib")}",')
    lines.append(
        "  # Deterministic CREATE2 address deployed by `VTSPositionLibEchidnaHarness`."
    )
    lines.append(f'  "src/libraries/VTSPositionLib.sol:VTSPositionLib:{addr("src/libraries/VTSPositionLib.sol:VTSPositionLib")}",')
    lines.append(
        f'  "src/libraries/VTSLifecycleLinkedLib.sol:VTSLifecycleLinkedLib:{addr("src/libraries/VTSLifecycleLinkedLib.sol:VTSLifecycleLinkedLib")}",'
    )
    lines.append(
        f'  "src/libraries/VTSPositionMMOpsLib.sol:VTSPositionMMOpsLib:{addr("src/libraries/VTSPositionMMOpsLib.sol:VTSPositionMMOpsLib")}",'
    )
    lines.append("  # Intentional placeholder for libs not CREATE2-validated by this script.")
    lines.append(f'  "src/libraries/VTSSwapLib.sol:VTSSwapLib:{addr("src/libraries/VTSSwapLib.sol:VTSSwapLib")}",')
    return "\n".join(lines)


def _replace_echidna_libraries_block(foundry_source: str, inner: str) -> str:
    start_marker = "[profile.medusa]"
    idx = foundry_source.find(start_marker)
    if idx == -1:
        raise ValueError("missing [profile.medusa] in foundry.toml")

    sub = foundry_source[idx:]
    lib_kw = "libraries = ["
    pos = sub.find(lib_kw)
    if pos == -1:
        raise ValueError("missing libraries = [ under [profile.medusa]")

    bracket_open = pos + len(lib_kw) - 1
    depth = 0
    i = bracket_open
    while i < len(sub):
        if sub[i] == "[":
            depth += 1
        elif sub[i] == "]":
            depth -= 1
            if depth == 0:
                bracket_close = i
                break
        i += 1
    else:
        raise ValueError("unclosed libraries = [ array in [profile.medusa]")

    new_block = lib_kw + "\n" + inner + "\n]"
    replacement = sub[:pos] + new_block + sub[bracket_close + 1 :]
    return foundry_source[:idx] + replacement


def _rewrite_echidna_linked_libs(manifest: dict[str, str]) -> None:
    source = ECHIDNA_LINKED_LIBS_PATH.read_text()
    updated = source
    for constant_name, library_path in CONSTANT_TO_LIBRARY.items():
        addr_lower = manifest[library_path]
        checksum = _to_checksum_address(addr_lower)
        updated, n = re.subn(
            rf"(address internal constant {re.escape(constant_name)} = )0x[a-fA-F0-9]{{40}};",
            rf"\g<1>{checksum};",
            updated,
            count=1,
        )
        if n != 1:
            raise ValueError(f"failed to rewrite `{constant_name}` in EchidnaLinkedLibs.sol")
    ECHIDNA_LINKED_LIBS_PATH.write_text(updated)


def _apply_impl() -> None:
    manifest = _parse_manifest(MANIFEST_PATH.read_text())
    missing = [k for k in ECHIDNA_LIBRARY_IDS if k not in manifest]
    if missing:
        raise ValueError("manifest incomplete: missing " + ", ".join(missing))

    inner = _build_libraries_toml_inner(manifest)
    foundry_source = FOUNDRY_TOML_PATH.read_text()
    FOUNDRY_TOML_PATH.write_text(_replace_echidna_libraries_block(foundry_source, inner))
    _rewrite_echidna_linked_libs(manifest)


def _apply_from_manifest() -> int:
    try:
        _apply_impl()
    except (FileNotFoundError, ValueError, RuntimeError) as exc:
        print(f"apply failed: {exc}", file=sys.stderr)
        return 1

    print(f"Applied `{MANIFEST_PATH.relative_to(ROOT)}` -> `{FOUNDRY_TOML_PATH.relative_to(ROOT)}` + `{ECHIDNA_LINKED_LIBS_PATH.relative_to(ROOT)}`.")
    return 0


def _converge() -> int:
    """Apply manifest-driven config and verify the resulting build."""
    if not MANIFEST_PATH.exists():
        print(f"Missing `{MANIFEST_PATH.relative_to(ROOT)}`.", file=sys.stderr)
        return 1

    try:
        _apply_impl()
        _forge_build_echidna()
    except (ValueError, RuntimeError) as exc:
        print(f"converge: apply/build failed: {exc}", file=sys.stderr)
        return 1

    val = _run_forge_script("run()")
    if val.returncode != 0:
        sys.stderr.write(val.stdout)
        sys.stderr.write(val.stderr)
        print("converge: ValidateEchidnaLinkedLibs.run() failed after apply/build.", file=sys.stderr)
        return 1

    print("converge: applied manifest and verified ValidateEchidnaLinkedLibs.run().")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Fuzz linked-library manifest: validate, apply, or converge.")
    parser.add_argument(
        "command",
        nargs="?",
        choices=("validate", "apply", "converge"),
        default="validate",
        help="validate | apply (once) | converge (iterate until stable)",
    )
    args = parser.parse_args()
    if args.command == "apply":
        return _apply_from_manifest()
    if args.command == "converge":
        try:
            return _converge()
        except (FileNotFoundError, RuntimeError) as exc:
            print(f"converge failed: {exc}", file=sys.stderr)
            return 1
    return _validate_sync()


if __name__ == "__main__":
    sys.exit(main())
