# Snow Leopard compatibility notes

## Hardware and architecture

The tested baseline is an iMac5,1 with an Intel Core 2 Duo and an ATI Radeon
X1600 with 128 MiB VRAM, running Mac OS X 10.6.8. A 32-bit Darwin kernel can
run this app as a 64-bit user process.

An actual accelerated CGL context reports:

| Capability | Result |
| --- | --- |
| OpenGL / GLSL | 2.0 / 1.20 |
| Maximum texture size | 4096 |
| Fragment texture units / vertex attributes | 16 / 16 |
| Framebuffer objects | GL_EXT_framebuffer_object |
| Non-power-of-two textures | GL_ARB_texture_non_power_of_two |
| Pixel buffers | GL_ARB_pixel_buffer_object |
| Vertex array objects | GL_APPLE_vertex_array_object |
| sRGB texture / framebuffer extension | yes / no |

The renderer uses linear A8 coverage and ordinary framebuffer blending, with a
bounded 2048-square atlas and batched VBO geometry. It does not require Metal,
Vulkan, or a newer OpenGL context. CoreText provides grapheme rasterization and
font fallback. Block elements are rasterized procedurally across full cells.

## Library choice and pin

libghostty-vt supplies terminal state, render-state data, selection, input
encoders, formatting, and terminal replies. It does not supply this frontend's
window system, graphics backend, fonts, or PTY management. Full Ghostty's
application stack is outside this port's scope.

The current pin is official tag **vt-1.0.1**, commit
`108cacb17ed8990840cd14abfce43d8ed8503ca1`. Its immutable archive SHA-256 is
`616c40b98bc94b0f2548d4599c3451bae6c4253d5a452fc47866f0c966bb75a8`.
The manifest requires **Zig 0.17.0**. libghostty-vt is independently versioned
**1.0.1**, with a stable C ABI; the upstream app's version is different.
The build explicitly sets the library version instead of inferring it from Git.

The 1.0 migration uses fixed-layout style/selection structures, style flags,
updated cursor and mode enums, GhosttyString keyboard text, renamed encoder
setters, and formatter selection options for copying text.

SIMD and Kitty graphics remain disabled. Future CPU optimizations should be
measured on the baseline hardware before changing those defaults.

## Toolchain and unavailable APIs

Zig emits a static Mach-O archive. Clang compiles the frontend against a locally
supplied 10.6 SDK; the stable OSXCross linker performs the final link. Verify
**LC_VERSION_MIN_MACOSX 10.6**, **LC_UNIXTHREAD**, and absence of **LC_MAIN**.
A modern ld64.lld build previously emitted LC_MAIN despite a 10.6 target and
failed on the target with an illegal instruction.

Current Zig/Ghostty I/O uses APIs absent from Snow Leopard, including openat,
preadv, and modern ulock operations. `patches/snow-leopard-tinyio.patch` selects
failing TinyIo below 10.7. The frontend owns PTY I/O and installs a secure random
callback using the system random device. The library links libc to use the
older system allocator rather than Zig's modern Darwin allocator.

`prepare-archive.py` follows upstream's Darwin override list and localizes
compiler-runtime memory/math definitions with OSXCross nmedit, preferring
libSystem and avoiding duplicate definitions. The executable ships no added
runtime dylibs or emulated modern syscalls.

The fetcher checks its immutable archive hash and verifies patch state in both
directions. GNU patch may silently ignore --reverse; --forward prevents that
from making an unpatched file appear patched. Local patch hashes are pinned in
`upstream.lock.json`; patches apply with zero context fuzz.

libghostty-vt 1.0.1 includes [upstream PR #15199](https://github.com/ghostty-org/ghostty/pull/15199),
which supersedes PR #14707. The local prompt-reflow backport has been removed.
Upstream now tracks the prompt start before resizing, preserves its row count
during reflow, and fixes prompt-start marks on split/joined rows. The source
screen remains intact if resizing fails. `vt-probe` exercises alternating width
changes, independent-axis shrinking and resize bursts through the public C API
while checking cursor position, prompt count and retained command output.

The C library normally disables prompt redraw, unlike Ghostty's terminal
frontend. `patches/snow-ghostty-prompt-redraw.patch` keeps the core's enabled
default for this app. It only affects OSC 133-marked prompt/input content;
unmarked output still reflows normally. Shells retain the standard `redraw=0`
opt-out and `redraw=last` behavior. Without this frontend policy, the upstream
fix would remain inactive for ordinary Powerlevel10k prompt marks.

## Validation

On 2026-11-12, app 0.3.1 with libghostty-vt 1.0.1 passed on the physical target:

- GPU and public C API probes, including repeated prompt reflow, independent-axis
  shrinking and resize bursts; rendering, selection and PTY/tmux integration.
- Native tabs/About, terminal controls, configuration reload and startup geometry.
- The configured Powerlevel10k prompt through normal startup, twenty resizes,
  rapid resize bursts, independent-axis changes and narrow new-tab startup.
- Windowed/fullscreen tab switching and all five shell-exit lifecycle modes.

Actual GPU captures of the rendering fixture and resized prompts were inspected.
Only the version header changed in the public C headers; the existing frontend
API calls and Darwin runtime-symbol localization remain compatible.

The 1.0.0 update passed on the physical target:

- Accelerated GLSL 1.20, A8 sampling, blending, and FBO pixel readback.
- Library version/features, Unicode formatting, resizing, key modes, terminal
  replies, bracketed paste, mouse encoding, and combined style flags.
- Actual app rendering, word selection, PTY input, Ctrl-C, scrollback, tmux,
  resize, fullscreen transitions, and restored window geometry.
- Windowed/fullscreen/restored shell exit, login-shell exit, and retained script
  output, with no leftover test windows or sessions.
- Pixel checks for contiguous full blocks, oriented half blocks, and shade
  coverage at both the bundled font's default size and Menlo 18.

Run the native probes described in [HACKING.md](HACKING.md). For lifecycle checks:

```sh
./lifecycle-probe "/path/to/Snow Ghostty.app/Contents/MacOS/snow-ghostty" fullscreen exit-fullscreen
```

Other modes are `windowed`, `restored`, `held`, and `login`. Each probe addresses
its own process and windows. For procedural-block checks, emit the fixture in a
test app using `probes/check-blocks.py`, capture its framebuffer, then validate
locally with `--capture PNG`; pass the measured cell dimensions for other fonts.

## Desktop behavior

The frontend keeps each tab's PTY across Snow Leopard view-fullscreen
transitions. The entire tab host enters fullscreen, including the tab strip.
Its window is temporary: final-tab exit must leave fullscreen through its window
controller before closing the original window. Exiting another tab removes only
its session, with deferred child reaping while sibling tabs/windows stay alive.

Snow Leopard lacks the later NSWindow tabbing API. The tab host uses NSTabView
for content/selection and a compact Cocoa-control strip styled after the target's
Terminal.app, with left-aligned labels and close buttons. No private APIs or
Terminal.app artwork are used. The About panel is AppKit's standard native panel;
the Window, Services and Help menus are registered with NSApplication.

Tab and window titles prefer OSC titles from terminal applications. Without an
explicit title, the frontend queries its own session's foreground process and
working directory through Snow Leopard's libproc once per second. Background
titles update independently; selecting a tab applies its label to the window.
OSC titles belong to the foreground process that emitted them. A prompt title
from a shell must not hide a subsequent foreground job such as `top`; the shell
title becomes eligible again when that job exits.
The system `top` is setuid and denies libproc metadata queries on 10.6. Fall back
to the kernel's short process name and the shell's directory when the foreground
job's directory cannot be read; no protected arguments or elevated access are
needed.

User-initiated close checks query only the session's controlling TTY. Idle shells
and orphaned background helper groups (including prompt workers) need no warning;
foreground jobs and shell-controlled background/stopped jobs do. Window closing
and Quit inspect every tab and show a single native confirmation. Automatic tab
removal is deferred during that modal panel, and Cancel sends no termination
signals. Natural shell exit does not prompt.
The textured native window frame and unflipped tab buttons let the selected
tab meet the title bar without a separator across its top edge.

Switching between OpenGL pages temporarily exposes the Cocoa backing store on
10.6. Hold screen updates until the window flush, attach/layout the incoming
page, and draw its hardware surface before presenting the changed tab. Keep the
flush disable/enable balanced even when selection raises an exception.

AppKit may treat option values as startup documents when document types are
declared. CLI handling suppresses only those initial callbacks; later file/URL
requests create independent sessions/windows in the running app. Finder Services use the selected
directory, or a file's parent. Explicit application routing was tested; default
handler selection is exposed as a user action rather than changed on install.

The application owns native window controllers, shared menus and its Dock menu.
Command-N and Dock New Window fork only a shell/PTY, never another frontend.
Window cycling uses Command-grave and Command-Shift-grave. The app stays resident
after its last window closes; Dock reopen creates a fresh window. CLI diagnostic
flags and initial commands are confined to the initial session.

## Terminal controls and secure input

Font actions rebuild the active tab's CoreText faces and glyph cache, recalculate
cell metrics and send the changed terminal geometry to its PTY. Reset Font Size
uses the loaded configuration. Reload parses into a candidate first, then applies
valid settings to every tab without replacing its terminal or session.

Clear Scrollback temporarily disables then restores the core's history budget,
which erases history while retaining the visible grid. Reset Terminal uses the
core's reset API, reapplies the bundled palette and signals the foreground group
with SIGWINCH so programs can redraw. Plain navigation keys use the core encoder;
Shift with those keys moves the local viewport. Fn-arrow navigation also follows
the logical Cocoa function key, instead of assuming the physical arrow code.

Secure Keyboard Entry uses Carbon's EnableSecureEventInput/DisableSecureEventInput
on the main thread. Keep our requested choice separate from our own enable count:
IsSecureEventInputEnabled reports global state, including other applications.
Release our count on terminal focus loss, app deactivation and termination.
The native controls probe verifies API state and the checked menu through these
transitions, as well as terminal resets, retained output and reload rollback.

## Session startup geometry

The former fixed 100×30 PTY size could be observed by a shell before AppKit
finished laying out its tab. The first-command native regression reproduced
100 columns in a 73-column tab. Each child now waits on a private local socket
until the tab is attached, resized and its final TIOCSWINSZ has been applied.
The view releases the child before shell execution. Cancelling an unattached
session closes the gate and reaps the child. Both socket ends are close-on-exec;
new children close inherited gates for other pending sessions.

The renderer applies initial pixel metrics even if its row/column count matches
the core's placeholder dimensions. Font metric changes also update PTY/core
geometry when the character grid size happens to stay constant.

## Primary references

- [Ghostty library documentation](https://ghostty.org/docs/libghostty)
- [Release source and C headers](https://github.com/ghostty-org/ghostty/tree/vt-1.0.1)
- [Pinned TinyIo](https://github.com/ghostty-org/ghostty/blob/108cacb17ed8990840cd14abfce43d8ed8503ca1/src/lib/TinyIo.zig)
- [Pinned Darwin runtime override](https://github.com/ghostty-org/ghostty/blob/108cacb17ed8990840cd14abfce43d8ed8503ca1/src/build/libsystem_override.sh)
- [Apple Services implementation](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/providing.html)
