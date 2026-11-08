# Snow Ghostty development

Read `README.md` and `RESEARCH.md` before changing the build or assuming modern
macOS compatibility. Follow any applicable workspace instructions as well.

- One app owns multiple native terminal windows. Each window owns its tabs;
  each tab owns its PTY, terminal state, scrollback, timer, and GPU context.
  Use tmux for panes. Keep CLI startup in main.m, app routing in application.m,
  window ownership in window.m, PTYs/processes in session.m, and the terminal,
  renderer, input and diagnostic methods in their corresponding modules.
- Snow Leopard predates NSWindow tabbing. Use the Cocoa NSTabView session host
  and compact Terminal-style strip; do not restore the generic Aqua tab bezel.
  Close/reap only the affected session. The final tab closes its window; the
  app stays in the Dock until Quit, including when it has no windows.
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
- Keep the prompt-reflow backport and C frontend prompt-redraw policy together.
  The C library otherwise disables the behavior. Preserve OSC 133 redraw=0 and
  redraw=last, and run the repeated-width public C API regression.
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
- Shell exit closes its tab through its window controller. Final-tab exit
  must leave the tab host's fullscreen mode before cleanup. Closing Cocoa's
  temporary fullscreen window leaves the original window white. Preserve
  retained output for scripts and SSH links, without affecting sibling tabs.
- User-initiated tab/window closing and Quit must confirm when their sessions
  contain running or stopped jobs, including jobs in inactive tabs. Idle shells
  and exited sessions need no prompt. Natural shell exit must not open a dialog.
  Keep automatic tab removal deferred while a close confirmation is visible.
- Command-N, Dock New Window and desktop requests create windows in the running
  app, preserving active sessions and the loaded config. Never spawn another
  frontend instance for these actions or inherit startup commands/diagnostics.
- Close Window checks only its own tabs. Quit checks every window in one
  confirmation. Window cycling uses Command-grave / Command-Shift-grave.
- Execute only executable .command files, using their parent working directory.
  SSH URLs become direct system-client argv; reject passwords and commands.
- AppKit on 10.6 may treat CLI values as startup documents. Suppress those
  startup callbacks after parsing CLI arguments; retain later Apple Events.

- Configuration reload is transactional: parse defaults/theme/user file into a
  candidate before replacing live state. Apply valid reloads to all tabs without
  restarting sessions. Font zoom stays local to a tab and never rewrites config.
- Balance each successful EnableSecureEventInput with DisableSecureEventInput.
  Release our ownership on loss of terminal focus, app deactivation and Quit;
  never use the global IsSecureEventInputEnabled result as our ownership flag.

- Newly forked sessions wait on a private startup gate. Attach/layout the view,
  apply final PTY geometry, then call snow_session_start. Closing an unattached
  session must cancel and reap it without executing the requested command.
