#!/usr/bin/env bash
# Regenerate docs/FEATURES.md (from the matrix) and docs/TOOLS.md (from the tool schemas).
#   scripts/gen-docs.sh            write them
#   scripts/gen-docs.sh --check    fail if the committed files are stale (check.sh runs this)
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product vmlab >/dev/null
bin="$(swift build --show-bin-path)/vmlab"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

stale=0
for doc in FEATURES TOOLS; do
  "$bin" gen-docs "$(echo "$doc" | tr '[:upper:]' '[:lower:]')" > "$tmp/$doc.md"
  if [ "${1:-}" = "--check" ]; then
    if ! cmp -s "$tmp/$doc.md" "docs/$doc.md"; then
      echo "gen-docs: docs/$doc.md is stale; run scripts/gen-docs.sh" >&2
      stale=1
    fi
  else
    cp "$tmp/$doc.md" "docs/$doc.md"
  fi
done
exit "$stale"
