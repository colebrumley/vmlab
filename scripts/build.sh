#!/usr/bin/env bash
# swift build, then sign the VZ runner. Arguments go to swift build (for example -c release).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build "$@"
config=debug
for arg in "$@"; do
  case "$arg" in
    release | -c=release | --configuration=release) config=release ;;
  esac
done
scripts/sign.sh "$config"
