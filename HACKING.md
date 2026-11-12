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

[upstream.lock.json](upstream.lock.json) pins the official `vt-1.0.1` tag's
commit and compiler version. The upstream application version and libghostty-vt
version are separate; the linked library is explicitly versioned **1.0.1**.
The build targets `x86_64-macos.10.6`, Core 2, ReleaseFast, scalar parsing, and
disabled Kitty graphics. The local TinyIo compatibility and frontend prompt-redraw
policy patches are pinned with checksums in the same manifest and applied by the
fetcher. Prompt reflow comes from upstream 1.0.1. The frontend uses the real 10.6
SDK and the stable OSXCross linker. Preserve **LC_UNIXTHREAD** and a 10.6 deployment target:
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

Build `make build/menus-probe` to exercise the real frontend's native menus,
About panel, tab controls, independent PTYs, selection and fullscreen lifecycle.
For an isolated test, duplicate the app bundle into a test directory and replace
only that copy's `Contents/MacOS/snow-ghostty` with `build/menus-probe`. Invoke
the copied executable with `CAPTURE.png tabs` (or `close-terminal` / `shell-exit`).
The probe uses fixture output and its own shells; it closes its test windows.
The `switch` and `switch-fullscreen` modes sample a small region of that probe's
window while switching between two dark fixture tabs. They write RGB samples
to `CAPTURE.png.csv` and save the first unexpected frame, if any. Use them on the
physical GPU when changing tab presentation; final screenshots alone miss
transient flashes.
The `confirm-window` and `confirm-quit` modes exercise native confirmation dialogs,
automatically clicking Cancel or Close in their own test windows. They check idle
shells, foreground/background/stopped jobs, inactive tabs, and fullscreen cancel.
The `windows` mode verifies same-PID native windows from Command-N and the Dock
menu, bidirectional window cycling, cross-window close protection, resident-app
reopen and desktop script routing. The lifecycle probe expects the app to remain
resident after its final shell exits, then quits that isolated test app.
The `controls` mode checks font shortcuts and PTY geometry, navigation encoding
and scrollback, reset/clear semantics, transactional configuration reload, the
loaded Settings path and native secure-input focus/ownership transitions.
The `prompt` mode opens the account's actual login shell, requires OSC 133
markers, and checks cursor/history stability through twenty native window
resizes. It sends Ctrl-L and clears only its own scrollback for a clean starting
screen, then enters no commands. `prompt-live` retains the normal startup
screen/history, `prompt-axes` changes height then width independently, and
`prompt-tab` exercises a narrow new tab. The `prompt-mouse` and
`prompt-mouse-continuous` modes use the native resize handle with separate or
uninterrupted axis changes; they briefly move the pointer in their own window.
`startup-size` checks the first command's PTY geometry and cancellation of an
unattached child.

## Source layout

| Module | Responsibility |
| --- | --- |
| `main.m` | CLI validation and startup |
| `application.m`, `window.m` | App/Dock/menu routing and native window ownership |
| `session.m` | PTYs, process metadata, job checks and child reaping |
| `terminal.m` | Terminal lifetime, PTY I/O and title updates |
| `renderer.m`, `fonts.m`, `input.m` | OpenGL drawing, CoreText font sizing and Cocoa input/selection |
| `commands.m`, `settings.m` | Terminal actions, configuration reload and native secure input |
| `diagnostics.m` | Existing render, selection and PTY/tmux diagnostics |

Renderer, input and diagnostic methods are categories of the same `TerminalView`;
they share that view's state without creating another renderer or terminal core.
The native probe links these production modules directly instead of including
the CLI implementation.

See [RESEARCH.md](RESEARCH.md) for platform compatibility and validation notes,
and [resources/README.md](resources/README.md) for bundled resource attribution.

Release preparation is described in [RELEASING.md](RELEASING.md).
