#!/usr/bin/env bash
set -euo pipefail

FOUNDRY_VERSION="${FOUNDRY_VERSION:-v1.4.2}"
MEDUSA_VERSION="${MEDUSA_VERSION:-v1.5.1}"
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

repair_medusa_if_needed() {
  local archive="medusa-linux-x64.tar.gz"
  local url="https://github.com/crytic/medusa/releases/download/${MEDUSA_VERSION}/${archive}"

  if command -v medusa >/dev/null 2>&1 && medusa --version 2>/dev/null | grep -q "${MEDUSA_VERSION#v}"; then
    return
  fi

  mkdir -p "$LOCAL_BIN"
  (
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' EXIT

    curl -fsSL "$url" -o "$tmp_dir/medusa.tar.gz"
    tar -xzf "$tmp_dir/medusa.tar.gz" -C "$tmp_dir"

    if [ -x "$tmp_dir/medusa" ]; then
      install -m 0755 "$tmp_dir/medusa" "$LOCAL_BIN/medusa"
    elif [ -x "$tmp_dir/bin/medusa" ]; then
      install -m 0755 "$tmp_dir/bin/medusa" "$LOCAL_BIN/medusa"
    else
      echo "medusa binary not found in release archive" >&2
      exit 1
    fi
  )
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
  medusa --version
  yarn --version
}

ensure_paths
ensure_yarn
repair_foundry_if_needed
repair_just_if_needed
repair_python_tools_if_needed
repair_medusa_if_needed
sync_repo
refresh_deps
refresh_build_outputs
show_versions
