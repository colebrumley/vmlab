#!/usr/bin/env bash
# Install the host tools vmlab needs (qemu, tart) with Homebrew if missing, then print versions.
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
  echo "bootstrap: Homebrew is required (https://brew.sh)" >&2
  exit 1
fi

if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
  echo "bootstrap: installing qemu"
  brew install qemu
fi

if ! command -v tart >/dev/null 2>&1; then
  echo "bootstrap: installing tart"
  brew install cirruslabs/cli/tart
fi

echo "swift:  $(swift --version 2>&1 | head -1)"
echo "qemu:   $(qemu-system-aarch64 --version | head -1)"
echo "tart:   $(tart --version)"
