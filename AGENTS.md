# Snow Ghostty development

Read `README.md` and `RESEARCH.md` before changing the build or assuming modern
macOS compatibility. Follow any applicable workspace instructions as well.

- Keep one native window and one PTY per process. Use tmux for panes.
- Use libghostty-vt for terminal state, encoders, and terminal replies. Cocoa,
  font rasterization, GPU rendering, and session management belong here.
- Target the measured OpenGL 2.0 / GLSL 1.20 baseline. Preserve accelerated
  context selection, a bounded atlas, and integer cell placement.
- Pin upstream source and Zig explicitly in `upstream.lock.json`. The current
  core is libghostty-vt 1.0.0 with Zig 0.17.0. Its version is separate from the
  upstream application's version; preserve the library-version override.
- Style and selection have fixed-layout structures. Do not initialize them
  with GHOSTTY_INIT_SIZED. Use the stable C API's style flags and formatters.
- Use the 10.6 SDK, Core 2 target, and compatible OSXCross linker. Preserve
  LC_UNIXTHREAD; a Linux build alone does not prove target compatibility.
- Keep the TinyIo patch: the frontend owns PTY I/O and supplies secure random
  data, avoiding newer Darwin APIs. Keep upstream modifications in patches/.
- Public source must not contain operator identities, target addresses,
  credentials, private logs, captures, SDKs, or workstation paths. Use ignored
  config.mk for machine-specific build paths. Keep generated source, dependency
  caches, and build output ignored.
- Do not infer hardware or network access authorization from documentation.
  Use only targets and actions explicitly authorized by the operator.
- Before claiming rendering correctness, inspect actual target captures. Test
  interactions in isolated windows/tmux sessions and clean them up.
- Frame wall time from a short test is not a sustained throughput benchmark.
- Bundle FiraCode Nerd Font Mono regular/bold and Catppuccin Mocha, default size
  12. Preserve user configuration. The bundle identifier is
  `lv.apps.snow-ghostty`.
- U+2580-U+259F use procedural full-cell bitmaps in the atlas. Font ink bounds
  leave line-spacing gaps in ANSI art. Check actual GPU output with
  probes/check-blocks.py after changing glyph placement or cell metrics.
- Shell exit must terminate through the application delegate, leaving view
  fullscreen before cleanup. Closing Cocoa's temporary fullscreen window leaves
  the original window white. Preserve retained output for scripts and SSH links.
- Command-N and desktop requests spawn independent processes, preserving active
  sessions and an explicit config path without inheriting test/session commands.
- Execute only executable .command files, using their parent working directory.
  SSH URLs become direct system-client argv; reject passwords and commands.
- AppKit on 10.6 may treat CLI values as startup documents. Suppress those
  startup callbacks after parsing CLI arguments; retain later Apple Events.
