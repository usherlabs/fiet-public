#!/usr/bin/env bash
set -euo pipefail

rm -f .github/workflows/codex-scope-verify.yml
rm -f .github/codex/active-scope.json

rmdir .github/codex 2>/dev/null || true
rmdir .github/workflows 2>/dev/null || true

echo "Removed scoped codex workflow artifacts."
echo "Review .github/scripts/cleanup-codex-scope.sh and remove it manually if it is no longer needed."
