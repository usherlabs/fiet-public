#!/usr/bin/env bash
set -euo pipefail

# Mutation testing driver for a Foundry project using Gambit-generated mutants.
#
# Requirements:
# - gambit on PATH
# - solc on PATH (matching your project, or set SOLC=solc8.26 etc)
# - forge on PATH
# - git (for worktree)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
OUTDIR="${OUTDIR:-"$ROOT/gambit_out"}"
WORKTREE_DIR="${WORKTREE_DIR:-"$ROOT/.mutation-worktree"}"
SOLC_BIN="${SOLC:-solc}"
EVM_VERSION="${EVM_VERSION:-cancun}"

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

ensure_worktree() {
  if [[ -d "$WORKTREE_DIR/.git" || -f "$WORKTREE_DIR/.git" ]]; then
    return 0
  fi
  log "Creating worktree at: $WORKTREE_DIR"
  git -C "$ROOT" worktree add "$WORKTREE_DIR" HEAD >/dev/null
}

clean_worktree() {
  # Keep it deterministic between mutants.
  git -C "$WORKTREE_DIR" reset --hard >/dev/null
  git -C "$WORKTREE_DIR" clean -fd >/dev/null
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
    "solc_base_path": ".",
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
  log "Generating mutants into: $OUTDIR"
  rm -rf "$OUTDIR"
  mkdir -p "$OUTDIR"

  local tmp_conf
  tmp_conf="$(mktemp)"
  export ROOT OUTDIR SOLC_BIN EVM_VERSION SKIP_VALIDATE NUM_MUTANTS
  export TARGETS_JSON
  TARGETS_JSON="$(python3 - <<PY
import json
print(json.dumps(${TARGETS[@]+"${TARGETS[@]}"}))
PY
  )"

  # The python one-liner above is a bit bashy; re-encode robustly:
  TARGETS_JSON="$(python3 - <<'PY'
import json, os, sys
# Read targets from argv (bash passes words), emit JSON list
print(json.dumps(sys.argv[1:]))
PY
  "${TARGETS[@]}")"

  build_gambit_config > "$tmp_conf"

  # Run from repo root so "sourceroot": "." and relative filenames work.
  (cd "$ROOT" && gambit mutate --json "$tmp_conf")

  rm -f "$tmp_conf"
}

overlay_mutant_into_worktree() {
  local mid="$1"
  local mutant_dir="$OUTDIR/mutants/$mid"
  if [[ ! -d "$mutant_dir" ]]; then
    log "Missing mutant dir: $mutant_dir"
    return 2
  fi

  # Overlay the mutant’s files (typically a single .sol) onto the worktree.
  rsync -a "$mutant_dir"/ "$WORKTREE_DIR"/
}

run_forge_tests_for_mutant() {
  local mid="$1"

  # Override Foundry compilation knobs by editing foundry.toml.
  # - add a [profile.mutation] with via_ir=false, optimizer=false, optimizer_runs=0
  # - run with: FOUNDRY_PROFILE=mutation forge test
  FOUNDRY_PROFILE=mutation forge test -q
}

main() {
  log "Targets:"
  for t in "${TARGETS[@]}"; do log "  - $t"; done

  generate_mutants
  ensure_worktree

  local results_csv="$OUTDIR/mutation_results.csv"
  echo "mid,status" > "$results_csv"

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

    clean_worktree
    overlay_mutant_into_worktree "$mid"

    set +e
    (cd "$WORKTREE_DIR" && run_forge_tests_for_mutant "$mid")
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
  log "Results:  $results_csv"
}

main
