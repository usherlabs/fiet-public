#!/usr/bin/env bash
set -euo pipefail

FOUNDRY_VERSION="${FOUNDRY_VERSION:-v1.4.2}"
ECHIDNA_VERSION="${ECHIDNA_VERSION:-v2.2.7}"
YARN_VERSION="${YARN_VERSION:-3.2.0}"

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
EVM_DIR="$REPO_ROOT/contracts/evm"
LOCAL_BIN="$HOME/.local/bin"
FOUNDRY_BIN="$HOME/.foundry/bin"

add_path_now() {
  case ":$PATH:" in
    *":$1:"*) ;;
    *) export PATH="$1:$PATH" ;;
  esac
}

ensure_paths() {
  add_path_now "$LOCAL_BIN"
  add_path_now "$FOUNDRY_BIN"
}

ensure_yarn() {
  if ! command -v corepack >/dev/null 2>&1; then
    npm install -g corepack
  fi
  corepack enable
  corepack prepare "yarn@${YARN_VERSION}" --activate
}

repair_foundry_if_needed() {
  if command -v forge >/dev/null 2>&1 && forge --version | grep -q "${FOUNDRY_VERSION#v}"; then
    return
  fi

  curl -L https://foundry.paradigm.xyz | bash
  add_path_now "$FOUNDRY_BIN"
  foundryup -i "$FOUNDRY_VERSION"
}

repair_just_if_needed() {
  if command -v just >/dev/null 2>&1; then
    return
  fi

  mkdir -p "$LOCAL_BIN"
  curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to "$LOCAL_BIN"
}

repair_python_tools_if_needed() {
  if command -v crytic-compile >/dev/null 2>&1; then
    return
  fi

  python3 -m pip install --user --upgrade pip
  python3 -m pip install --user crytic-compile
}

repair_echidna_if_needed() {
  local archive="echidna-${ECHIDNA_VERSION#v}-x86_64-linux.tar.gz"
  local url="https://github.com/crytic/echidna/releases/download/${ECHIDNA_VERSION}/${archive}"
  local tmp_dir

  if command -v echidna >/dev/null 2>&1 && echidna --version 2>/dev/null | grep -q "${ECHIDNA_VERSION}"; then
    return
  fi

  mkdir -p "$LOCAL_BIN"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  curl -fsSL "$url" -o "$tmp_dir/echidna.tar.gz"
  tar -xzf "$tmp_dir/echidna.tar.gz" -C "$tmp_dir"

  if [ -x "$tmp_dir/echidna" ]; then
    install -m 0755 "$tmp_dir/echidna" "$LOCAL_BIN/echidna"
  elif [ -x "$tmp_dir/bin/echidna" ]; then
    install -m 0755 "$tmp_dir/bin/echidna" "$LOCAL_BIN/echidna"
  else
    echo "echidna binary not found in release archive" >&2
    exit 1
  fi

  if [ -x "$tmp_dir/echidna-test" ]; then
    install -m 0755 "$tmp_dir/echidna-test" "$LOCAL_BIN/echidna-test"
  elif [ -x "$tmp_dir/bin/echidna-test" ]; then
    install -m 0755 "$tmp_dir/bin/echidna-test" "$LOCAL_BIN/echidna-test"
  else
    ln -sf "$LOCAL_BIN/echidna" "$LOCAL_BIN/echidna-test"
  fi
}

sync_repo() {
  git -C "$REPO_ROOT" submodule sync --recursive
  git -C "$REPO_ROOT" submodule update --init --recursive --jobs 8
}

refresh_deps() {
  cd "$EVM_DIR"
  yarn install --immutable
}

refresh_build_outputs() {
  cd "$EVM_DIR"
  forge clean
  FOUNDRY_PROFILE=ci forge build
}

show_versions() {
  cd "$EVM_DIR"
  forge --version
  just --version
  crytic-compile --version
  echidna --version
  echidna-test --version || true
  yarn --version
}

ensure_paths
ensure_yarn
repair_foundry_if_needed
repair_just_if_needed
repair_python_tools_if_needed
repair_echidna_if_needed
sync_repo
refresh_deps
refresh_build_outputs
show_versions
