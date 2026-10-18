#!/usr/bin/env bash
# Ad-hoc sign the VZ runner with the virtualization entitlement (constraint C2: the only one).
#   scripts/sign.sh [debug|release]      default debug
set -euo pipefail
cd "$(dirname "$0")/.."

config="${1:-debug}"
binary=".build/$config/vmlab-vz"
if [ ! -f "$binary" ]; then
  echo "sign: $binary not found; build first" >&2
  exit 1
fi
codesign --force --sign - --entitlements Sources/vmlab-vz/vmlab-vz.entitlements "$binary"
echo "sign: $binary signed with com.apple.security.virtualization"
