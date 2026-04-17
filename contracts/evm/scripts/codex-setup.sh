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

persist_path() {
  local dir="$1"
  local profile_file="${HOME}/.profile"
  mkdir -p "$dir"
  touch "$profile_file"
  if ! grep -Fqs "export PATH=\"$dir:\$PATH\"" "$profile_file"; then
    printf '\nexport PATH="%s:$PATH"\n' "$dir" >> "$profile_file"
  fi
}

run_root() {
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}

ensure_apt_prereqs() {
  if ! command -v apt-get >/dev/null 2>&1; then
    return
  fi

  run_root apt-get update
  run_root apt-get install -y \
    bc \
    ca-certificates \
    curl \
    git \
    jq \
    python3 \
    python3-pip \
    tar \
    unzip \
    xz-utils
}

ensure_node() {
  if command -v node >/dev/null 2>&1; then
    return
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "Node.js is required but was not found, and apt-get is unavailable." >&2
    exit 1
  fi

  curl -fsSL https://deb.nodesource.com/setup_20.x | run_root bash
  run_root apt-get install -y nodejs
}

ensure_yarn() {
  if ! command -v corepack >/dev/null 2>&1; then
    npm install -g corepack
  fi
  corepack enable
  corepack prepare "yarn@${YARN_VERSION}" --activate
}

ensure_foundry() {
  add_path_now "$FOUNDRY_BIN"
  persist_path "$FOUNDRY_BIN"

  if command -v forge >/dev/null 2>&1 && forge --version | grep -q "${FOUNDRY_VERSION#v}"; then
    return
  fi

  curl -L https://foundry.paradigm.xyz | bash
  add_path_now "$FOUNDRY_BIN"
  foundryup -i "$FOUNDRY_VERSION"
}

ensure_just() {
  add_path_now "$LOCAL_BIN"
  persist_path "$LOCAL_BIN"

  if command -v just >/dev/null 2>&1; then
    return
  fi

  if command -v apt-get >/dev/null 2>&1 && run_root apt-get install -y just; then
    return
  fi

  curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to "$LOCAL_BIN"
}

ensure_python_tools() {
  add_path_now "$LOCAL_BIN"
  persist_path "$LOCAL_BIN"

  python3 -m pip install --user --upgrade pip
  python3 -m pip install --user crytic-compile
}

ensure_medusa() {
  local archive="medusa-linux-x64.tar.gz"
  local url="https://github.com/crytic/medusa/releases/download/${MEDUSA_VERSION}/${archive}"

  add_path_now "$LOCAL_BIN"
  persist_path "$LOCAL_BIN"

  if command -v medusa >/dev/null 2>&1 && medusa --version 2>/dev/null | grep -q "${MEDUSA_VERSION#v}"; then
    return
  fi

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

install_js_deps() {
  cd "$EVM_DIR"
  yarn install --immutable
}

warm_build_cache() {
  cd "$EVM_DIR"
  FOUNDRY_PROFILE=ci forge build
}

show_versions() {
  cd "$EVM_DIR"
  forge --version
  just --version
  python3 -m pip --version
  crytic-compile --version
  medusa --version
  yarn --version
}

ensure_apt_prereqs
ensure_node
ensure_yarn
ensure_foundry
ensure_just
ensure_python_tools
ensure_medusa
sync_repo
install_js_deps
warm_build_cache
show_versions
