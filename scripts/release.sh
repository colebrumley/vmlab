#!/usr/bin/env bash
# Release build: dist/vmlab-<version>-arm64.tar.gz (vmlab, vmlab-vz, vmlab-switch) and its .sha256.
#   scripts/release.sh                     version from `git describe --tags` (a leading v dropped)
#   VMLAB_VERSION=0.0.0-dry scripts/release.sh   a dry-run version; no tag needed
# The version is baked into Sources/VMLabMCP/VMLabMCP.swift for the build only, then restored.
# Afterwards the tarball is unpacked into a temp directory and its vmlab is checked there:
# `--version` prints the version and `doctor` finds the signed vmlab-vz next to itself.
# Never creates or pushes a tag.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${VMLAB_VERSION:-}"
if [ -z "$version" ]; then
  if ! version="$(git describe --tags --dirty 2>/dev/null)"; then
    echo "release: no git tag to name the version; tag the commit or set VMLAB_VERSION" >&2
    exit 1
  fi
fi
version="${version#v}"
if ! [[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z.+-]*$ ]]; then
  echo "release: '$version' is not a version" >&2
  exit 1
fi

source_file=Sources/VMLabMCP/VMLabMCP.swift
pattern='^\(  public static let version = \)".*"$'
if [ "$(grep -c '^  public static let version = ".*"$' "$source_file")" != 1 ]; then
  echo "release: no single version line in $source_file" >&2
  exit 1
fi
backup="$(mktemp)"
cp "$source_file" "$backup"
restore() { cp "$backup" "$source_file" && rm -f "$backup"; }
trap restore EXIT
sed -i '' "s/$pattern/\\1\"$version\"/" "$source_file"

swift build -c release --product vmlab
swift build -c release --product vmlab-vz
swift build -c release --product vmlab-switch
restore
trap - EXIT
scripts/sign.sh release

name="vmlab-$version-arm64"
bin="$(swift build -c release --show-bin-path)"
rm -rf "dist/$name" "dist/$name.tar.gz" "dist/$name.tar.gz.sha256"
mkdir -p "dist/$name"
cp "$bin/vmlab" "$bin/vmlab-vz" "$bin/vmlab-switch" "dist/$name/"
cp README.md "dist/$name/"
tar -czf "dist/$name.tar.gz" -C dist "$name"
rm -rf "dist/$name"
(cd dist && shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256")

# Check the tarball as a user would get it.
check="$(mktemp -d)"
trap 'rm -rf "$check"' EXIT
(cd dist && shasum -a 256 -c "$name.tar.gz.sha256" >/dev/null)
tar -xzf "dist/$name.tar.gz" -C "$check"
unpacked="$(cd "$check/$name" && pwd -P)"
got="$("$unpacked/vmlab" --version)"
if [ "$got" != "$version" ]; then
  echo "release: unpacked vmlab --version printed '$got', expected '$version'" >&2
  exit 1
fi
VMLAB_HOME="$check/home" "$unpacked/vmlab" doctor --json > "$check/doctor.json"
node -e '
  const [file, dir] = process.argv.slice(1);
  const report = JSON.parse(require("fs").readFileSync(file, "utf8"));
  const runner = (report.checks || []).find((c) => c.check === "runner_entitlement");
  if (!runner || runner.status !== "ok" || !String(runner.detail).includes(dir + "/vmlab-vz")) {
    console.error("release: doctor did not find the signed vmlab-vz next to vmlab:",
      JSON.stringify(runner));
    process.exit(1);
  }
' "$check/doctor.json" "$unpacked"
echo "release: dist/$name.tar.gz ($(cut -d' ' -f1 "dist/$name.tar.gz.sha256"))"
echo "release: unpacked vmlab $version runs doctor and finds its signed vmlab-vz"
