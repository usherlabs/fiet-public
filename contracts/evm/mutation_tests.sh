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

# In multi-target runs we will write into per-target subdirectories under OUTDIR_BASE
# to avoid Gambit outputs clobbering each other.
OUTDIR_BASE="${OUTDIR:-"$FOUNDRY_ROOT/gambit_out"}"
OUTDIR="$OUTDIR_BASE"
WORKTREE_DIR="${WORKTREE_DIR:-"$FOUNDRY_ROOT/.mutation-worktree"}"
SOLC_BIN="${SOLC:-solc}"
EVM_VERSION="${EVM_VERSION:-cancun}"
FLAT_OUTDIR="${FLAT_OUTDIR:-0}" # 1 to write into OUTDIR_BASE directly (legacy behaviour)

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

safe_rm_rf() {
  # Safety guard for destructive deletes.
  #
  # Usage:
  #   safe_rm_rf "<path>" "<must_be_under_prefix>"
  #
  # Refuses to delete if:
  # - path is empty / unset
  # - path resolves to "/" (or ".")
  # - path is not under the provided prefix (when non-empty)
  #
  # NOTE: This is a best-effort guard; still be careful when calling rm -rf.
  local target="${1:-}"
  local prefix="${2:-}"

  if [[ -z "$target" ]]; then
    log "ERROR: refusing to rm -rf an empty path"
    return 2
  fi

  # Normalise a few obviously-dangerous cases.
  if [[ "$target" == "/" || "$target" == "." ]]; then
    log "ERROR: refusing to rm -rf dangerous path: '$target'"
    return 2
  fi

  if [[ -n "$prefix" ]]; then
    # Ensure prefix itself is sane.
    if [[ "$prefix" == "/" || "$prefix" == "." ]]; then
      log "ERROR: refusing to use dangerous prefix for safe_rm_rf: '$prefix'"
      return 2
    fi
    # Require target to be under prefix (prefix itself or prefix/<something>).
    if [[ "$target" != "$prefix" && "$target" != "$prefix/"* ]]; then
      log "ERROR: refusing to rm -rf '$target' (not under expected prefix '$prefix')"
      return 2
    fi
  fi

  rm -rf -- "$target"
}

target_slug() {
  # Turn a target path like "src/LiquidityHub.sol" into a stable, filesystem-safe slug.
  # We include the full path (not just basename) to avoid collisions.
  local t="$1"
  t="${t#./}"
  t="${t//\//__}"
  t="${t//[^A-Za-z0-9_.-]/_}"
  echo "$t"
}

mutation_score_pct() {
  # killed / (killed + survived) * 100, as a string with 2 dp.
  # Excludes "errored" from the denominator since those are neither killed nor survived.
  local killed="$1"
  local survived="$2"
  awk -v k="$killed" -v s="$survived" 'BEGIN {
    t = k + s;
    if (t <= 0) { printf "0.00"; exit 0; }
    printf "%.2f", (100.0 * k / t);
  }'
}

cleanup() {
  if [[ "$CLEAN_AFTER" == "1" ]]; then
    log "Cleaning worktree dir: $WORKTREE_DIR"
    safe_rm_rf "$WORKTREE_DIR" "$FOUNDRY_ROOT" || true
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
        safe_rm_rf "$WORKTREE_FOUNDRY_ROOT/lib" "$WORKTREE_DIR"
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
    safe_rm_rf "$WORKTREE_FOUNDRY_ROOT/lib" "$WORKTREE_DIR"
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
  safe_rm_rf "$OUTDIR" "$OUTDIR_BASE"
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

write_detailed_report() {
  # Enrich the minimal `mutation_results.csv` with Gambit metadata so survivors can be reviewed.
  #
  # Inputs (under $OUTDIR):
  # - mutation_results.csv: mid,status
  # - mutants.log: mid,mutation_type,file,line:col,original_expr,mutant_expr
  # - gambit_results.json: includes per-mutant diff + description
  #
  # Outputs (under $OUTDIR):
  # - mutation_results_detailed.csv: one row per mutant with original/mutant + diff
  # - mutation_survivors_detailed.csv: filtered to status==survived
  OUTDIR="$OUTDIR" python3 - <<'PY'
import csv
import json
import os
import sys

outdir = os.environ["OUTDIR"]

results_csv = os.path.join(outdir, "mutation_results.csv")
mutants_log = os.path.join(outdir, "mutants.log")
gambit_results = os.path.join(outdir, "gambit_results.json")

def warn(msg: str) -> None:
    print(f"[mutation_tests] {msg}", file=sys.stderr)

if not os.path.exists(results_csv):
    warn(f"Skipping detailed report: missing {results_csv}")
    sys.exit(0)

statuses: dict[str, str] = {}
with open(results_csv, newline="", encoding="utf-8") as f:
    r = csv.DictReader(f)
    if not r.fieldnames or "mid" not in r.fieldnames or "status" not in r.fieldnames:
        warn(f"Skipping detailed report: unexpected CSV header in {results_csv}: {r.fieldnames}")
        sys.exit(0)
    for row in r:
        mid = (row.get("mid") or "").strip()
        status = (row.get("status") or "").strip()
        if mid:
            statuses[mid] = status

meta: dict[str, dict[str, str]] = {}
if os.path.exists(mutants_log):
    with open(mutants_log, newline="", encoding="utf-8") as f:
        r = csv.reader(f)
        for row in r:
            if not row:
                continue
            # Expected: mid, mutation_type, file, line:col, original_expr, mutant_expr
            # Be tolerant if extra commas appear in expr columns (csv handles quotes).
            if len(row) < 6:
                continue
            mid, mut_type, path, linecol, orig_expr, mut_expr = row[:6]
            line, col = "", ""
            if ":" in linecol:
                line, col = (linecol.split(":", 1) + [""])[:2]
            else:
                line = linecol
            meta[mid] = {
                "mutation_type": mut_type,
                "file": path,
                "line": line,
                "col": col,
                "original_expr": orig_expr,
                "mutant_expr": mut_expr,
            }
else:
    warn(f"Missing {mutants_log}; detailed report will omit original/mutant expressions.")

diffs: dict[str, dict[str, str]] = {}
if os.path.exists(gambit_results):
    with open(gambit_results, encoding="utf-8") as f:
        arr = json.load(f)
    if isinstance(arr, list):
        for item in arr:
            if not isinstance(item, dict):
                continue
            mid = str(item.get("id", "")).strip()
            if not mid:
                continue
            diffs[mid] = {
                "description": str(item.get("description", "") or ""),
                "diff": str(item.get("diff", "") or ""),
            }
else:
    warn(f"Missing {gambit_results}; detailed report will omit diffs.")

def mid_sort_key(m: str):
    try:
        return int(m)
    except Exception:
        return m

cols = [
    "mid", "status",
    "mutation_type", "description",
    "file", "line", "col",
    "original_expr", "mutant_expr",
    "diff",
]

detailed_path = os.path.join(outdir, "mutation_results_detailed.csv")
survivors_path = os.path.join(outdir, "mutation_survivors_detailed.csv")

rows: list[list[str]] = []
for mid in sorted(statuses.keys(), key=mid_sort_key):
    m = meta.get(mid, {})
    d = diffs.get(mid, {})
    rows.append([
        mid,
        statuses.get(mid, ""),
        m.get("mutation_type", ""),
        d.get("description", ""),
        m.get("file", ""),
        m.get("line", ""),
        m.get("col", ""),
        m.get("original_expr", ""),
        m.get("mutant_expr", ""),
        d.get("diff", ""),
    ])

with open(detailed_path, "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(cols)
    w.writerows(rows)

with open(survivors_path, "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(cols)
    for r in rows:
        if r[1] == "survived":
            w.writerow(r)

warn(f"Wrote detailed report: {detailed_path}")
warn(f"Wrote survivors report: {survivors_path}")
PY
}

main() {
  log "Targets:"
  for t in "${TARGETS[@]}"; do log "  - $t"; done

  if [[ "$CLEAN_BEFORE" == "1" ]]; then
    log "Cleaning before run (CLEAN_BEFORE=1)"
    safe_rm_rf "$OUTDIR_BASE" "$FOUNDRY_ROOT"
    safe_rm_rf "$WORKTREE_DIR" "$FOUNDRY_ROOT"
    git -C "$GIT_ROOT" worktree prune >/dev/null 2>&1 || true
  fi

  ensure_worktree

  local overall_killed=0 overall_survived=0 overall_errored=0

  local targets_to_run=("${TARGETS[@]}")
  if [[ "$FLAT_OUTDIR" != "1" ]]; then
    log ""
    log "Per-target outdir mode: writing outputs under: $OUTDIR_BASE/<target>"
    log "Tip: set FLAT_OUTDIR=1 to write directly into: $OUTDIR_BASE (legacy)"
  fi

  for target in "${targets_to_run[@]}"; do
    if [[ "$FLAT_OUTDIR" == "1" ]]; then
      OUTDIR="$OUTDIR_BASE"
    else
      OUTDIR="$OUTDIR_BASE/$(target_slug "$target")"
    fi

    log ""
    log "=== Target: $target ==="
    log "Outdir: $OUTDIR"

    # Generate mutants for this target only (Gambit outdir is per-target in multi-target mode).
    TARGETS=("$target")
    generate_mutants

    # If Gambit failed to compile the target, it may produce no mutants directory.
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

    local results_csv="$OUTDIR/mutation_results.csv"
    if [[ "$RESUME" == "1" && -f "$results_csv" ]]; then
      log "Resuming from existing results CSV (RESUME=1): $results_csv"
    else
      mkdir -p "$OUTDIR"
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

    write_detailed_report

    log ""
    log "Target done."
    log "Killed:   $killed"
    log "Survived: $survived"
    log "Errored:  $errored"
    local target_total=$((killed + survived))
    local target_pct
    target_pct="$(mutation_score_pct "$killed" "$survived")"
    log "Score:    $killed/$target_total killed (${target_pct}%)"
    log "Results:  $results_csv"

    {
      echo "killed=$killed"
      echo "survived=$survived"
      echo "errored=$errored"
      echo "total=$target_total"
      echo "score_pct=$target_pct"
    } > "$OUTDIR/mutation_score.txt"

    # Convenience pointer to the most recently-written per-target directory.
    if [[ "$FLAT_OUTDIR" != "1" ]]; then
      ln -sfn "$OUTDIR" "$OUTDIR_BASE/_latest" >/dev/null 2>&1 || true
    fi

    overall_killed=$((overall_killed + killed))
    overall_survived=$((overall_survived + survived))
    overall_errored=$((overall_errored + errored))
  done

  log ""
  log "Done."
  log "Killed:   $overall_killed"
  log "Survived: $overall_survived"
  log "Errored:  $overall_errored"
  local overall_total=$((overall_killed + overall_survived))
  local overall_pct
  overall_pct="$(mutation_score_pct "$overall_killed" "$overall_survived")"
  log "Score:    $overall_killed/$overall_total killed (${overall_pct}%)"
  log "Outdir:   $OUTDIR_BASE"

  {
    echo "killed=$overall_killed"
    echo "survived=$overall_survived"
    echo "errored=$overall_errored"
    echo "total=$overall_total"
    echo "score_pct=$overall_pct"
  } > "$OUTDIR_BASE/mutation_score.txt"
}

main
