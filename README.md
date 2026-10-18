# vmlab

Virtual machines for a language model, on an Apple Silicon Mac, over MCP.

A model asks for a guest and the features it needs: a screen to click on, a shell, a serial
console, a GDB stub on the guest CPU, checkpoints, a private network for a fleet. vmlab picks the
engine that can provide them, Apple's Virtualization.framework or QEMU, or says exactly why none
can. macOS guests come from prebuilt images and clone in a second; Linux guests boot from cloud
images or straight from a kernel you just built.

It is built for two kinds of work: low-level development (drivers, bootloaders, kernels, where you
need serial, GDB and an undo button) and macOS setup testing (run a script against a clean Mac and
diff what it changed).

The requirements are in [REQUIREMENTS.md](REQUIREMENTS.md); the build process in
[CLAUDE.md](CLAUDE.md). The MCP tool reference is generated into `docs/TOOLS.md` and the verified
capability matrix into `docs/FEATURES.md`.

## Install

```bash
scripts/bootstrap.sh          # Homebrew: qemu, tart
scripts/build.sh              # swift build + sign the VZ runner
.build/debug/vmlab doctor     # what works on this host
.build/debug/vmlab install-mcp --client claude-code
```

### Connect a client

`vmlab install-mcp` prints the MCP configuration that runs `vmlab serve` (the executable you ran
it from, unless `--command` names another) with `VMLAB_HOME` (from the environment, else
`~/.vmlab`, or `--vmlab-home`). It changes nothing unless you pass `--write`.

```bash
vmlab install-mcp --client claude-code             # JSON for ~/.claude.json and the `claude mcp add` line
vmlab install-mcp --client claude-code --write     # merge it into ~/.claude.json (user scope)
vmlab install-mcp --client claude-desktop --write  # ~/Library/Application Support/Claude/claude_desktop_config.json
claude mcp list                                    # vmlab: ... serve - Connected
```

`--write` keeps every other key and server in the file and replaces only `mcpServers.vmlab`
(`--name` picks another key). Restart Claude Desktop after writing its file.

### Without Homebrew

QEMU (and Tart, for macOS guests) still come from Homebrew; vmlab itself needs only the Xcode
toolchain:

```bash
swift build -c release
scripts/sign.sh release                     # the VZ runner's virtualization entitlement
mkdir -p ~/.local/bin
cp .build/release/vmlab .build/release/vmlab-vz .build/release/vmlab-switch ~/.local/bin/
~/.local/bin/vmlab doctor
~/.local/bin/vmlab install-mcp --client claude-code --write
```

Keep the three binaries in one directory: `vmlab` looks for `vmlab-vz` next to itself.
