#!/usr/bin/env bash
# Format lint, build, unit tests, sign. Must pass before every commit.
set -euo pipefail
cd "$(dirname "$0")/.."

swift format lint --strict --recursive Sources Tests Package.swift
swift build
swift test --skip IntegrationTests
if [ -x scripts/sign.sh ]; then scripts/sign.sh debug; fi
