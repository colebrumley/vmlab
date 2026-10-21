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
  if ! brew install cirruslabs/cli/tart; then
    cat >&2 <<'EOF'
bootstrap: `brew install cirruslabs/cli/tart` failed.

Known issue: since Homebrew 7.0.0 the cirruslabs tap's tart formula is rejected, because it uses
the disabled `depends_on :macos => :ventura` form outside an `on_macos` block, and its `softnet`
dependency needs `brew trust` of the tap. Until the tap is fixed upstream, install tart by hand:
  1. brew tap-new local/tart
  2. copy $(brew --repo cirruslabs/cli)/Formula/tart.rb into the new tap's Formula/ directory,
     delete the `depends_on :macos` line and the `depends_on "softnet"` line (softnet only serves
     tart's optional --net-softnet, which vmlab does not use)
  3. brew install local/tart/tart
  4. rerun scripts/bootstrap.sh
Tart is needed only for macOS guests; Linux guests on QEMU work without it. REQUIREMENTS.md R-000
has the details.
EOF
    exit 1
  fi
fi

echo "swift:  $(swift --version 2>&1 | head -1)"
echo "qemu:   $(qemu-system-aarch64 --version | head -1)"
echo "tart:   $(tart --version)"
