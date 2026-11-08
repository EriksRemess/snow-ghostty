# Developing Snow Ghostty

## Build on Linux

Requirements:

- Zig **0.17.0**, Clang, Python 3.12+, GNU Make, `patch`, and `llvm-nm`.
- A locally supplied **MacOSX10.6.sdk** and a compatible OSXCross toolchain
  providing `x86_64-apple-darwin10-ld`, `ar`, `nmedit`, and `ranlib`.
- GitHub CLI (`gh`) for the pinned upstream source download.

SDKs and toolchains are not included. Set their locations in an ignored
`config.mk`, using your own paths:

```make
SDK := /path/to/MacOSX10.6.sdk
OSXCROSS_BIN := /path/to/osxcross/target/bin
```

Then run:

```sh
python3 scripts/fetch-core.py
make
```

Alternatively pass `SDK` and `OSXCROSS_BIN` on the Make command line. `ZIG`,
`CLANG`, `LINKER`, and `CFLAGS` are also overridable. `make core` rebuilds just
the terminal engine. The fetcher requires network access; it uses read-only
GitHub API calls and verifies the immutable archive's SHA-256 before extraction.

[upstream.lock.json](upstream.lock.json) pins the official `vt-1.0.0` tag's
commit and compiler version. The upstream application version and libghostty-vt
version are separate; the linked library is explicitly versioned **1.0.0**.
The build targets `x86_64-macos.10.6`, Core 2, ReleaseFast, scalar parsing, and
disabled Kitty graphics. The frontend uses the real 10.6 SDK and the stable
OSXCross linker. Preserve **LC_UNIXTHREAD** and a 10.6 deployment target:
a successful link with modern `ld64.lld` is not proof of Snow Leopard support.

Outputs are under `build/`:

- `Snow Ghostty.app`
- `gpu-probe`
- `vt-probe`

## Install and test

Copy `build/Snow Ghostty.app` to an Applications folder on the target Mac.
Back up an existing installation first and preserve the user's configuration.
For a full bundle replacement, close its sessions before copying. Executable
updates may instead use atomic replacement so existing sessions can finish.

The app supports `--version`, `--help`, `--config PATH`, `--working-directory
DIR`, `--command COMMAND`, `--execute-file FILE`, and `--ssh URL`. A supplied
shell command is shell text; file paths and SSH arguments are passed directly.
The account's configured login shell is selected with `getpwuid`.

Run these from a test directory containing the copied bundle and probes:

```sh
./gpu-probe
./vt-probe
"./Snow Ghostty.app/Contents/MacOS/snow-ghostty" --version
"./Snow Ghostty.app/Contents/MacOS/snow-ghostty" --self-test --capture render.png
"./Snow Ghostty.app/Contents/MacOS/snow-ghostty" --integration-test --capture tmux.png
```

Tests open their own windows. Integration uses an isolated tmux server and
cleans it up. Captures contain only the test app's framebuffer. Build
`make build/lifecycle-probe` for native windowed/fullscreen/restored/retained-
output/login shell-exit regression checks; see [RESEARCH.md](RESEARCH.md).

See [RESEARCH.md](RESEARCH.md) for platform compatibility and validation notes,
and [resources/README.md](resources/README.md) for bundled resource attribution.
