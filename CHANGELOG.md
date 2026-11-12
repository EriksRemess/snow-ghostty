# Changelog

## 0.3.1 — 2026-11-12

- Update libghostty-vt to 1.0.1 and replace the local prompt-reflow backport
  with upstream's fix for stale prompts and prompt markers during resizing.

## 0.3.0 — 2026-11-08

- Add native tabs and multiple windows within one app, with automatic session
  titles, window cycling and a Dock New Window action.
- Add native About, application menus and Secure Keyboard Entry. Confirm tab,
  window and app closing when running or stopped jobs would be affected.
- Add font sizing/reset, Clear Scrollback, Reset Terminal, navigation keys,
  Settings in the default editor and live configuration reload (Shift-Command-,).
- Fix tab-switch flashes, multiline prompt reflow and shell startup using the
  final tab dimensions. Powerlevel10k prompt integration is documented.
- Split the frontend into application, window, session, renderer and input
  modules, with native regression probes.

Requires Intel Core 2 or newer, Mac OS X 10.6+, and accelerated OpenGL 2.0 /
GLSL 1.20. The engine remains libghostty-vt 1.0.0 with pinned local backports.
