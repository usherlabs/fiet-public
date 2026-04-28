#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-v1.4.2}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"

case "$arch" in
    x86_64|amd64)
        arch="amd64"
        ;;
    aarch64|arm64)
        arch="arm64"
        ;;
    *)
        echo "unsupported architecture: $arch" >&2
        exit 1
        ;;
esac

asset="foundry_${VERSION}_${os}_${arch}.tar.gz"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

asset_api_url="$(
python3 - "$VERSION" "$asset" <<'PY'
import json
import sys
import urllib.request

version = sys.argv[1]
asset_name = sys.argv[2]
url = f"https://api.github.com/repos/foundry-rs/foundry/releases/tags/{version}"

with urllib.request.urlopen(url) as response:
    payload = json.load(response)

for asset in payload.get("assets", []):
    if asset.get("name") == asset_name:
        print(asset["url"])
        break
else:
    raise SystemExit(f"missing asset: {asset_name}")
PY
)"

curl -fsSL \
    -H "Accept: application/octet-stream" \
    "$asset_api_url" \
    -o "$tmpdir/foundry.tar.gz"

tar -xzf "$tmpdir/foundry.tar.gz" -C "$tmpdir"

install_bin() {
    local src="$1"
    if [ -w "$INSTALL_DIR" ]; then
        install -m 0755 "$src" "$INSTALL_DIR/$(basename "$src")"
    else
        sudo install -m 0755 "$src" "$INSTALL_DIR/$(basename "$src")"
    fi
}

for bin in forge cast anvil chisel; do
    if [ ! -f "$tmpdir/$bin" ]; then
        echo "missing binary in archive: $bin" >&2
        find "$tmpdir" -maxdepth 2 -type f | sort >&2
        exit 1
    fi
    install_bin "$tmpdir/$bin"
done

forge --version
