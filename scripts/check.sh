#!/usr/bin/env bash
# Format lint, build, unit tests, sign, generated docs current. Must pass before every commit.
set -euo pipefail
cd "$(dirname "$0")/.."

swift format lint --strict --recursive Sources Tests Package.swift
swift build
swift test --skip IntegrationTests
scripts/sign.sh debug
scripts/gen-docs.sh --check
