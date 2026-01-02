#!/usr/bin/env bash
set -euo pipefail

# Mutation testing driver for a Foundry project using Gambit-generated mutants.
#
# Requirements:
# - gambit on PATH
# - solc on PATH (matching your project, or set SOLC=solc8.26 etc)
# - forge on PATH
# - git (for worktree)

find_foundry_root() {
  # Prefer the nearest parent directory containing foundry.toml (and ideally remappings.txt).
  local start
  start="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  local dir="$start"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/foundry.toml" ]]; then
      echo "$dir"
      return 0
    fi
    dir="$(cd "$dir/.." && pwd)"
  done

  # Fallback: original behaviour (parent of script dir) if foundry.toml can't be located.
  echo "$(cd "$start/.." && pwd)"
}

FOUNDRY_ROOT="$(find_foundry_root)"
# The actual Git repo root may be above the Foundry project root (e.g. monorepos).
GIT_ROOT="$(git -C "$FOUNDRY_ROOT" rev-parse --show-toplevel 2>/dev/null || echo "$FOUNDRY_ROOT")"

OUTDIR="${OUTDIR:-"$FOUNDRY_ROOT/gambit_out"}"
WORKTREE_DIR="${WORKTREE_DIR:-"$FOUNDRY_ROOT/.mutation-worktree"}"
SOLC_BIN="${SOLC:-solc}"
EVM_VERSION="${EVM_VERSION:-cancun}"

# In monorepos, the git worktree is checked out at repo root, so the Foundry project
# lives at a subdirectory inside the worktree.
FOUNDRY_SUBDIR="$(
  FOUNDRY_ROOT="$FOUNDRY_ROOT" GIT_ROOT="$GIT_ROOT" python3 - <<'PY'
import os
print(os.path.relpath(os.environ["FOUNDRY_ROOT"], os.environ["GIT_ROOT"]))
PY
)"
if [[ "$FOUNDRY_SUBDIR" == "." ]]; then
  WORKTREE_FOUNDRY_ROOT="$WORKTREE_DIR"
else
  WORKTREE_FOUNDRY_ROOT="$WORKTREE_DIR/$FOUNDRY_SUBDIR"
fi

# Behaviour toggles
# - CLEAN_BEFORE=1: remove OUTDIR and WORKTREE_DIR before starting
# - CLEAN_AFTER=1: remove WORKTREE_DIR at the end (leaves OUTDIR/results intact)
# - REUSE_OUTDIR=1: if OUTDIR already has mutants, skip regeneration
# - RESUME=1: if results CSV exists, skip already-recorded mutant IDs
# - FAIL_FAST=0: continue on unexpected per-mutant errors (records "errored")
CLEAN_BEFORE="${CLEAN_BEFORE:-0}"
CLEAN_AFTER="${CLEAN_AFTER:-0}"
REUSE_OUTDIR="${REUSE_OUTDIR:-0}"
RESUME="${RESUME:-0}"
FAIL_FAST="${FAIL_FAST:-1}"

# Provide targets as args; defaults to "core" contracts (adjust to taste).
TARGETS=("$@")
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  TARGETS=(
    "src/LiquidityHub.sol"
    "src/MarketFactory.sol"
    "src/MMPositionManager.sol"
    "src/MMPositionActionsImpl.sol"
    "src/ProxyHook.sol"
    "src/VTSOrchestrator.sol"
    "src/LCC.sol"
  )
fi

# Controls
NUM_MUTANTS="${NUM_MUTANTS:-""}"       # e.g. 50 to downsample; empty means "all"
SKIP_VALIDATE="${SKIP_VALIDATE:-0}"    # 1 to skip Gambit solc validation step
MIDS="${MIDS:-""}"                    # e.g. "1 2 3" to only run some mutant IDs

log() { printf '%s\n' "$*" >&2; }

cleanup() {
  if [[ "$CLEAN_AFTER" == "1" ]]; then
    log "Cleaning worktree dir: $WORKTREE_DIR"
    rm -rf "$WORKTREE_DIR" || true
    # Best-effort: unregister the worktree if possible.
    git -C "$GIT_ROOT" worktree prune >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

ensure_worktree() {
  if [[ -d "$WORKTREE_DIR/.git" || -f "$WORKTREE_DIR/.git" ]]; then
    # Ensure dependencies are available even if worktree already exists.
    ensure_lib_in_worktree
    if [[ ! -f "$WORKTREE_FOUNDRY_ROOT/foundry.toml" ]]; then
      log "ERROR: Foundry project not found in worktree at: $WORKTREE_FOUNDRY_ROOT"
      log "Tip: check GIT_ROOT=$GIT_ROOT and FOUNDRY_ROOT=$FOUNDRY_ROOT"
      exit 1
    fi
    return 0
  fi
  log "Creating worktree at: $WORKTREE_DIR"
  git -C "$GIT_ROOT" worktree add "$WORKTREE_DIR" HEAD >/dev/null
  ensure_lib_in_worktree
  if [[ ! -f "$WORKTREE_FOUNDRY_ROOT/foundry.toml" ]]; then
    log "ERROR: Foundry project not found in worktree at: $WORKTREE_FOUNDRY_ROOT"
    log "Tip: check GIT_ROOT=$GIT_ROOT and FOUNDRY_ROOT=$FOUNDRY_ROOT"
    exit 1
  fi
}

ensure_lib_in_worktree() {
  # Ensure lib/ directory is available in the worktree's Foundry project for dependencies.
  local lib_target
  lib_target="$(cd "$FOUNDRY_ROOT" && pwd)/lib"

  # In monorepos, the worktree may contain *empty* submodule directories unless submodules are initialised.
  # Treat that as "missing" and fall back to symlinking the fully-populated lib/ from the main Foundry root.
  local needs_link="0"
  local check_needs_link
  check_needs_link() {
    needs_link="0"
    if [[ ! -d "$WORKTREE_FOUNDRY_ROOT/lib" ]]; then
      needs_link="1"
    fi
    if [[ ! -f "$WORKTREE_FOUNDRY_ROOT/lib/openzeppelin-contracts/contracts/access/Ownable.sol" ]]; then
      needs_link="1"
    fi
    if [[ ! -f "$WORKTREE_FOUNDRY_ROOT/lib/solady/src/utils/SafeTransferLib.sol" ]]; then
      needs_link="1"
    fi
    if [[ ! -f "$WORKTREE_FOUNDRY_ROOT/lib/v4-periphery/lib/v4-core/src/types/Currency.sol" ]]; then
      needs_link="1"
    fi
  }

  check_needs_link

  if [[ "$needs_link" == "1" ]]; then
    # First try to initialise/update submodules in the worktree (preferred; avoids symlinks).
    # This is usually fast and offline if your main checkout already has submodule objects.
    if [[ -f "$GIT_ROOT/.gitmodules" ]]; then
      if [[ -L "$WORKTREE_FOUNDRY_ROOT/lib" ]]; then
        rm -f "$WORKTREE_FOUNDRY_ROOT/lib"
      fi

      set +e
      git -C "$WORKTREE_DIR" submodule update --init --recursive -- \
        "$FOUNDRY_SUBDIR/lib/forge-std" \
        "$FOUNDRY_SUBDIR/lib/openzeppelin-contracts" \
        "$FOUNDRY_SUBDIR/lib/oracle" \
        "$FOUNDRY_SUBDIR/lib/permit2" \
        "$FOUNDRY_SUBDIR/lib/solady" \
        "$FOUNDRY_SUBDIR/lib/v4-periphery" \
        >/dev/null 2>&1
      set -e

      check_needs_link
    fi
  fi

  if [[ "$needs_link" == "1" ]]; then
    log "Linking lib/ directory into worktree Foundry project"
    # Remove existing lib if it exists but is broken/empty
    rm -rf "$WORKTREE_FOUNDRY_ROOT/lib"
    # Use absolute path for symlink target
    ln -sf "$lib_target" "$WORKTREE_FOUNDRY_ROOT/lib"
  fi
}

clean_worktree() {
  # Keep it deterministic between mutants.
  git -C "$WORKTREE_FOUNDRY_ROOT" reset --hard >/dev/null
  git -C "$WORKTREE_FOUNDRY_ROOT" clean -fd >/dev/null
  # Ensure lib/ is still available after cleaning.
  ensure_lib_in_worktree
}

build_gambit_config() {
  # Produces a Gambit config array on stdout.
  python3 - <<'PY'
import json, os, sys

root = os.environ["ROOT"]
solc = os.environ["SOLC_BIN"]
evm_version = os.environ["EVM_VERSION"]
outdir = os.environ["OUTDIR"]
skip_validate = os.environ.get("SKIP_VALIDATE", "0") == "1"
num_mutants = os.environ.get("NUM_MUTANTS") or None

targets = os.environ["TARGETS_JSON"]
targets = json.loads(targets)

remap_path = os.path.join(root, "remappings.txt")
remappings = []
if os.path.exists(remap_path):
  with open(remap_path, "r", encoding="utf-8") as f:
    for line in f:
      line = line.strip()
      if not line or line.startswith("#"):
        continue
      remappings.append(line)

conf = []
for filename in targets:
  entry = {
    "filename": filename,
    "sourceroot": ".",
    "outdir": outdir,
    "solc": solc,
    "solc_evm_version": evm_version,
    "solc_optimize": False,

    # Make import resolution behave like a Foundry repo.
    #
    # IMPORTANT: Do NOT set solc_base_path here.
    # Gambit canonicalises config paths and will pass an *absolute* --base-path to solc.
    # With solc 0.8.30+ this can break remapped imports in this repo and yield
    # "Source ... not found" even when the file exists.
    #
    # Allow paths still work (Gambit will canonicalise these too).
    "solc_allow_paths": [".", "lib"],
    "solc_remappings": remappings,

    "skip_validate": skip_validate,
  }
  if num_mutants is not None:
    entry["num_mutants"] = int(num_mutants)
  conf.append(entry)

print(json.dumps(conf, indent=2))
PY
}

generate_mutants() {
  if [[ "$REUSE_OUTDIR" == "1" && -d "$OUTDIR/mutants" ]]; then
    log "Reusing existing mutants in: $OUTDIR (REUSE_OUTDIR=1)"
    return 0
  fi

  log "Generating mutants into: $OUTDIR"
  rm -rf "$OUTDIR"
  mkdir -p "$OUTDIR"

  local tmp_conf
  # IMPORTANT: Gambit resolves paths (including remappings) relative to the
  # configuration file's parent directory. To ensure `remappings.txt` entries
  # like `v4-periphery/=lib/v4-periphery/` resolve correctly, we must place this
  # temp config under the repo root (the Foundry project root), not under OUTDIR.
  tmp_conf="$(mktemp "$FOUNDRY_ROOT/.gambit_conf.XXXXXX")"
  export ROOT="$FOUNDRY_ROOT" OUTDIR SOLC_BIN EVM_VERSION SKIP_VALIDATE NUM_MUTANTS
  export TARGETS_JSON
  # Robustly encode the bash array of targets as a JSON list (safe for paths).
  TARGETS_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${TARGETS[@]}")"

  build_gambit_config > "$tmp_conf"

  # Run from repo root so "sourceroot": "." and relative filenames work.
  (cd "$FOUNDRY_ROOT" && gambit mutate --json "$tmp_conf")

  rm -f "$tmp_conf"
}

overlay_mutant_into_worktree() {
  local mid="$1"
  local mutant_dir="$OUTDIR/mutants/$mid"
  if [[ ! -d "$mutant_dir" ]]; then
    log "Missing mutant dir: $mutant_dir"
    return 2
  fi

  # Overlay the mutant’s files (typically a single .sol) onto the worktree's Foundry project.
  rsync -a "$mutant_dir"/ "$WORKTREE_FOUNDRY_ROOT"/
}

run_forge_tests_for_mutant() {
  local mid="$1"

  # Prefer a dedicated Foundry profile if you have one, otherwise try env overrides.
  #
  # Recommended (most deterministic):
  # - add a [profile.mutation] with via_ir=false, optimizer=false, optimizer_runs=0
  # - run with: FOUNDRY_PROFILE=mutation forge test
  #
  # Fallback:
  # - use env overrides (works on many Foundry versions/setups).
  if [[ -f "$FOUNDRY_ROOT/foundry.toml" ]] && grep -qE '^\[profile\.mutation\]' "$FOUNDRY_ROOT/foundry.toml"; then
    FOUNDRY_PROFILE=mutation forge test -q
  else
    FOUNDRY_VIA_IR=false \
    FOUNDRY_OPTIMIZER=false \
    FOUNDRY_OPTIMIZER_RUNS=0 \
    forge test -q
  fi
}

main() {
  log "Targets:"
  for t in "${TARGETS[@]}"; do log "  - $t"; done

  if [[ "$CLEAN_BEFORE" == "1" ]]; then
    log "Cleaning before run (CLEAN_BEFORE=1)"
    rm -rf "$OUTDIR" "$WORKTREE_DIR"
    git -C "$GIT_ROOT" worktree prune >/dev/null 2>&1 || true
  fi

  generate_mutants

  # If Gambit failed to compile the target(s), it may produce no mutants directory.
  if [[ ! -d "$OUTDIR/mutants" ]]; then
    log "ERROR: Gambit produced no mutants at: $OUTDIR/mutants"
    log "This usually means solc failed to compile the target with the provided remappings."
    log "Tip: ensure your remappings are correct and that 'solc --ast-compact-json <file>' succeeds."
    exit 1
  fi

  # If the directory exists but is empty, stop early.
  if [[ -z "$(find "$OUTDIR/mutants" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)" ]]; then
    log "ERROR: Gambit mutants directory is empty: $OUTDIR/mutants"
    exit 1
  fi

  ensure_worktree

  local results_csv="$OUTDIR/mutation_results.csv"
  if [[ "$RESUME" == "1" && -f "$results_csv" ]]; then
    log "Resuming from existing results CSV (RESUME=1): $results_csv"
  else
    echo "mid,status" > "$results_csv"
  fi

  local mids_to_run=()
  if [[ -n "${MIDS:-}" ]]; then
    # shellcheck disable=SC2206
    mids_to_run=($MIDS)
  else
    while IFS= read -r d; do
      mids_to_run+=("$(basename "$d")")
    done < <(find "$OUTDIR/mutants" -mindepth 1 -maxdepth 1 -type d | sort -V)
  fi

  local killed=0 survived=0 errored=0

  for mid in "${mids_to_run[@]}"; do
    log ""
    log "== Mutant $mid =="

    if [[ "$RESUME" == "1" && -f "$results_csv" ]] && grep -qE "^${mid}," "$results_csv"; then
      log "Skipping mutant $mid (already recorded)"
      continue
    fi

    if ! clean_worktree; then
      log "ERROR: failed to clean worktree"
      echo "$mid,errored" >> "$results_csv"
      errored=$((errored + 1))
      [[ "$FAIL_FAST" == "1" ]] && exit 1 || continue
    fi

    if ! overlay_mutant_into_worktree "$mid"; then
      log "ERROR: failed to overlay mutant $mid"
      echo "$mid,errored" >> "$results_csv"
      errored=$((errored + 1))
      [[ "$FAIL_FAST" == "1" ]] && exit 1 || continue
    fi

    set +e
    (cd "$WORKTREE_FOUNDRY_ROOT" && run_forge_tests_for_mutant "$mid")
    local rc=$?
    set -e

    if [[ $rc -eq 0 ]]; then
      log "SURVIVED (tests passed)"
      echo "$mid,survived" >> "$results_csv"
      survived=$((survived + 1))
    else
      log "KILLED (tests failed) [exit=$rc]"
      echo "$mid,killed" >> "$results_csv"
      killed=$((killed + 1))
    fi
  done

  log ""
  log "Done."
  log "Killed:   $killed"
  log "Survived: $survived"
  log "Errored:  $errored"
  log "Results:  $results_csv"
}

main
