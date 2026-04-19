#!/usr/bin/env python3
"""Prepare ephemeral Foundry config + linked-library map for Echidna (FOUNDRY_PROFILE=echidna).

Writes `.echidna-gen/foundry.toml` (gitignored) by copying the repo `foundry.toml` and injecting
`[profile.echidna].libraries` with a fixed-point-converged address map. Addresses come from
`GenerateEchidnaLinkedLibAddresses.printManifest()` (CREATE2 predictions via `EchidnaLinkedLibs`).

Iterates: write map → `forge build` → read manifest → repeat until the manifest matches the map (library
linking and CREATE2 predictions stabilise). Then runs `SmokeEchidnaLinkedLibs`.

Run automatically from `scripts/echidna.sh` before Echidna. Override with `ECHIDNA_SKIP_PREPARE=1` to skip.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GEN_DIR = ROOT / ".echidna-gen"
GEN_FOUNDRY_TOML = GEN_DIR / "foundry.toml"
# Canonical CREATE2 manifest emitter (see test/fuzz/script/GenerateEchidnaLinkedLibAddresses.s.sol).
GENERATE_LINKED_LIB_SCRIPT = (
    "test/fuzz/script/GenerateEchidnaLinkedLibAddresses.s.sol:GenerateEchidnaLinkedLibAddresses"
)
SMOKE_SCRIPT = "test/fuzz/script/SmokeEchidnaLinkedLibs.s.sol:SmokeEchidnaLinkedLibs"

# Bootstrap addresses for the first fixed-point iteration only (replaced after convergence).
# VTSSwapLib is a deliberate placeholder (see foundry.toml comments on VTSSwapLib).
ECHIDNA_LIBRARY_IDS: list[str] = [
    "src/libraries/LCCFactoryLib.sol:LCCFactoryLinkedLib",
    "src/libraries/LiquidityHubLinkedLib.sol:LiquidityHubLinkedLib",
    "src/libraries/VTSCommitLib.sol:VTSCommitLib",
    "src/libraries/VTSPositionLib.sol:VTSPositionLib",
    "src/libraries/VTSLifecycleLinkedLib.sol:VTSLifecycleLinkedLib",
    "src/libraries/VTSPositionMMOpsLib.sol:VTSPositionMMOpsLib",
    "src/libraries/VTSSwapLib.sol:VTSSwapLib",
]

def _progress(msg: str) -> None:
    """Human-visible progress on stderr (stdout is reserved for the generated config path)."""
    print(f"[echidna-prepare] {msg}", file=sys.stderr, flush=True)


def _lib_short_name(lib_id: str) -> str:
    return lib_id.rsplit(":", 1)[-1]


BOOTSTRAP_MANIFEST: dict[str, str] = {
    "src/libraries/LCCFactoryLib.sol:LCCFactoryLinkedLib": "0x5a3842f9d1b0f96003669a36ec4a09165bc7de54",
    "src/libraries/LiquidityHubLinkedLib.sol:LiquidityHubLinkedLib": "0x5be262f2f2f9b3b5c70a256526ee9c6dd8fc9e02",
    "src/libraries/VTSCommitLib.sol:VTSCommitLib": "0x6603f397b11b2392c245cc0c7570f6110233a473",
    "src/libraries/VTSPositionLib.sol:VTSPositionLib": "0x1eb3ddb04f2ac30a033f17d6f78a1a9fb676cc14",
    "src/libraries/VTSLifecycleLinkedLib.sol:VTSLifecycleLinkedLib": "0xc40e390701f867fe2afb676bd694826ed5e4b868",
    "src/libraries/VTSPositionMMOpsLib.sol:VTSPositionMMOpsLib": "0x96148e6576bb664ac0fb79537835eb167b629cb9",
    "src/libraries/VTSSwapLib.sol:VTSSwapLib": "0x1111111111111111111111111111111111111112",
}


def _forge_env() -> dict[str, str]:
    env = os.environ.copy()
    env["FOUNDRY_PROFILE"] = "echidna"
    env["FOUNDRY_CONFIG"] = str(GEN_FOUNDRY_TOML.resolve())
    return env


def _replace_echidna_libraries_block(foundry_source: str, inner: str) -> str:
    start_marker = "[profile.echidna]"
    idx = foundry_source.find(start_marker)
    if idx == -1:
        raise ValueError("missing [profile.echidna] in foundry.toml")

    sub = foundry_source[idx:]
    lib_kw = "libraries = ["
    pos = sub.find(lib_kw)
    if pos == -1:
        raise ValueError("missing libraries = [ under [profile.echidna]")

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
        raise ValueError("unclosed libraries = [ array in [profile.echidna]")

    new_block = lib_kw + "\n" + inner + "\n]"
    replacement = sub[:pos] + new_block + sub[bracket_close + 1 :]
    return foundry_source[:idx] + replacement


def _build_libraries_toml_inner(manifest: dict[str, str]) -> str:
    def addr(lib_id: str) -> str:
        return manifest[lib_id]

    lines: list[str] = []
    lines.append(
        f'  "src/libraries/LCCFactoryLib.sol:LCCFactoryLinkedLib:{addr("src/libraries/LCCFactoryLib.sol:LCCFactoryLinkedLib")}",'
    )
    lines.append(
        f'  "src/libraries/LiquidityHubLinkedLib.sol:LiquidityHubLinkedLib:{addr("src/libraries/LiquidityHubLinkedLib.sol:LiquidityHubLinkedLib")}",'
    )
    lines.append(
        "  # Prevent HEVM crashes by eliminating unlinked placeholders in unrelated contracts (e.g. VTSOrchestrator)."
    )
    lines.append(
        "  # Deterministic CREATE2 address deployed by the SIG-BACKING harness (avoids any RPC fetch attempts)."
    )
    lines.append(f'  "src/libraries/VTSCommitLib.sol:VTSCommitLib:{addr("src/libraries/VTSCommitLib.sol:VTSCommitLib")}",')
    lines.append(
        "  # Deterministic CREATE2 address deployed by `VTSPositionLibEchidnaHarness` (avoids Echidna RPC fetch attempts)."
    )
    lines.append(
        f'  "src/libraries/VTSPositionLib.sol:VTSPositionLib:{addr("src/libraries/VTSPositionLib.sol:VTSPositionLib")}",'
    )
    lines.append(
        f'  "src/libraries/VTSLifecycleLinkedLib.sol:VTSLifecycleLinkedLib:{addr("src/libraries/VTSLifecycleLinkedLib.sol:VTSLifecycleLinkedLib")}",'
    )
    lines.append(
        f'  "src/libraries/VTSPositionMMOpsLib.sol:VTSPositionMMOpsLib:{addr("src/libraries/VTSPositionMMOpsLib.sol:VTSPositionMMOpsLib")}",'
    )
    lines.append("  # Intentional placeholder for libs not CREATE2-validated by this script.")
    lines.append(f'  "src/libraries/VTSSwapLib.sol:VTSSwapLib:{addr("src/libraries/VTSSwapLib.sol:VTSSwapLib")}",')
    return "\n".join(lines)


def _write_gen_foundry(manifest: dict[str, str]) -> None:
    GEN_DIR.mkdir(parents=True, exist_ok=True)
    base = (ROOT / "foundry.toml").read_text()
    inner = _build_libraries_toml_inner(manifest)
    GEN_FOUNDRY_TOML.write_text(_replace_echidna_libraries_block(base, inner))


def _clean_out_echidna() -> None:
    out_echidna = ROOT / "out-echidna"
    if out_echidna.exists():
        shutil.rmtree(out_echidna)


def _run_forge_build() -> None:
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
        raise RuntimeError("forge build (FOUNDRY_PROFILE=echidna, FOUNDRY_CONFIG=.echidna-gen/foundry.toml) failed")


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


def _run_generate_linked_lib_manifest() -> dict[str, str]:
    result = subprocess.run(
        ["forge", "script", GENERATE_LINKED_LIB_SCRIPT, "--sig", "printManifest()"],
        cwd=ROOT,
        env=_forge_env(),
        capture_output=True,
        text=True,
        check=False,
    )
    combined = (result.stdout or "") + (result.stderr or "")
    if result.returncode != 0:
        sys.stderr.write(combined)
        raise RuntimeError(
            "forge script GenerateEchidnaLinkedLibAddresses.printManifest() failed"
        )
    return _parse_manifest_from_forge_output(combined)


def _run_smoke() -> None:
    result = subprocess.run(
        ["forge", "script", SMOKE_SCRIPT, "--sig", "run()"],
        cwd=ROOT,
        env=_forge_env(),
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)
        raise RuntimeError("SmokeEchidnaLinkedLibs failed")


def prepare() -> Path:
    """Converge library map, write `.echidna-gen/foundry.toml`, build, and smoke-test CREATE2 deploys."""
    _progress(
        "converging Echidna linker map via GenerateEchidnaLinkedLibAddresses (max 32 rounds) → "
        f"{GEN_FOUNDRY_TOML.relative_to(ROOT)}"
    )
    manifest = {k: BOOTSTRAP_MANIFEST[k].lower() for k in ECHIDNA_LIBRARY_IDS}

    for iteration in range(32):
        n = iteration + 1
        _progress(f"round {n}/32: writing generated Foundry config and cleaning out-echidna/")
        _write_gen_foundry(manifest)
        _clean_out_echidna()

        t_build = time.monotonic()
        _progress(
            f"round {n}/32: running forge build (FOUNDRY_PROFILE=echidna, FOUNDRY_CONFIG=.echidna-gen/foundry.toml)"
        )
        _run_forge_build()
        _progress(f"round {n}/32: forge build done in {time.monotonic() - t_build:.1f}s")

        t_manifest = time.monotonic()
        _progress(
            f"round {n}/32: CREATE2 manifest (forge script GenerateEchidnaLinkedLibAddresses.printManifest)"
        )
        new_manifest = _run_generate_linked_lib_manifest()
        _progress(f"round {n}/32: manifest read in {time.monotonic() - t_manifest:.1f}s")

        if new_manifest == manifest:
            _progress(f"fixed point reached after {n} round(s); running SmokeEchidnaLinkedLibs")
            break

        changed = [k for k in ECHIDNA_LIBRARY_IDS if new_manifest[k] != manifest[k]]
        names = ", ".join(_lib_short_name(k) for k in changed)
        _progress(
            f"round {n}/32: linker map still moving ({len(changed)} entr"
            f"{'y' if len(changed) == 1 else 'ies'}): {names}"
        )
        manifest = new_manifest
    else:
        raise RuntimeError("Echidna linked libraries did not converge within iteration limit")

    t_smoke = time.monotonic()
    _run_smoke()
    _progress(f"smoke test (CREATE2 deploys) passed in {time.monotonic() - t_smoke:.1f}s")
    _progress("preparation complete")
    return GEN_FOUNDRY_TOML.resolve()


def main() -> int:
    if os.environ.get("ECHIDNA_SKIP_PREPARE", "") == "1":
        print("ECHIDNA_SKIP_PREPARE=1: skipping echidna_prepare_linked_libs.", file=sys.stderr)
        return 0
    try:
        path = prepare()
        print(str(path))
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
