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

The current pin is official tag **vt-1.0.0**, commit
`0fa3d577a5614150ff8e2c152de5fb9d5c6d2dec`. Its immutable archive SHA-256 is
`a315e13ecfbde6ee00ffdc66525bc95e6b9b5e25f54866d75eb69c6df7b8809b`.
The manifest requires **Zig 0.17.0**. libghostty-vt is independently versioned
**1.0.0**, with a stable C ABI; the upstream app's version is different.
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
from making an unpatched file appear patched.

## Validation

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

Run the native probes described in README. For lifecycle checks:

```sh
./lifecycle-probe "/path/to/Snow Ghostty.app/Contents/MacOS/snow-ghostty" fullscreen exit-fullscreen
```

Other modes are `windowed`, `restored`, `held`, and `login`. Each probe addresses
its own process and windows. For procedural-block checks, emit the fixture in a
test app using `probes/check-blocks.py`, capture its framebuffer, then validate
locally with `--capture PNG`; pass the measured cell dimensions for other fonts.

## Desktop behavior

The frontend keeps the same PTY across Snow Leopard view-fullscreen transitions.
In fullscreen, the view's window is temporary: shell exit must terminate the
application through its delegate, rather than close that temporary window.

AppKit may treat option values as startup documents when document types are
declared. CLI handling suppresses only those initial callbacks; later file/URL
requests still launch independent processes. Finder Services use the selected
directory, or a file's parent. Explicit application routing was tested; default
handler selection is exposed as a user action rather than changed on install.

## Primary references

- [Ghostty library documentation](https://ghostty.org/docs/libghostty)
- [Release source and C headers](https://github.com/ghostty-org/ghostty/tree/vt-1.0.0)
- [Pinned TinyIo](https://github.com/ghostty-org/ghostty/blob/0fa3d577a5614150ff8e2c152de5fb9d5c6d2dec/src/lib/TinyIo.zig)
- [Pinned Darwin runtime override](https://github.com/ghostty-org/ghostty/blob/0fa3d577a5614150ff8e2c152de5fb9d5c6d2dec/src/build/libsystem_override.sh)
- [Apple Services implementation](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/providing.html)
