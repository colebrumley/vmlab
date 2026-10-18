#!/usr/bin/env bash
# Regenerate docs/FEATURES.md (from the matrix) and docs/TOOLS.md (from the tool schemas).
#   scripts/gen-docs.sh                        write them
#   scripts/gen-docs.sh --check                fail if the committed files are stale (check.sh runs this)
#   scripts/gen-docs.sh --refresh-host-facts   copy this host's slow probes (VMLAB_HOME, default
#                                              ~/.vmlab/host-facts.json) into docs/dev-host-facts.json,
#                                              then write the docs; commit both
# FEATURES.md's "verified on dev host" column reads the committed docs/dev-host-facts.json, never
# ~/.vmlab, so running a slow probe does not make the docs stale in every other worktree.
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-}"
case "$mode" in
  "" | --check | --refresh-host-facts) ;;
  *) echo "usage: scripts/gen-docs.sh [--check | --refresh-host-facts]" >&2; exit 2 ;;
esac

swift build --product vmlab >/dev/null
bin="$(swift build --show-bin-path)/vmlab"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

snapshot=docs/dev-host-facts.json
if [ "$mode" = "--refresh-host-facts" ]; then
  "$bin" gen-docs host-facts > "$tmp/host-facts.json"
  cp "$tmp/host-facts.json" "$snapshot"
  echo "gen-docs: $snapshot refreshed from this host's slow probes" >&2
fi

stale=0
for doc in FEATURES TOOLS; do
  args=("$(echo "$doc" | tr '[:upper:]' '[:lower:]')")
  if [ "$doc" = FEATURES ]; then args+=(--probes "$snapshot"); fi
  "$bin" gen-docs "${args[@]}" > "$tmp/$doc.md"
  if [ "$mode" = "--check" ]; then
    if ! cmp -s "$tmp/$doc.md" "docs/$doc.md"; then
      echo "gen-docs: docs/$doc.md is stale; run scripts/gen-docs.sh" >&2
      stale=1
    fi
  else
    cp "$tmp/$doc.md" "docs/$doc.md"
  fi
done
exit "$stale"
