# Using Snow Ghostty

## Features

- Truecolor, bold/italic, faint/inverse, underline and strikethrough.
- Unicode combining characters, wide cells, font fallback, scrollback,
  selection, copy/paste, mouse reporting, and application cursor modes.
- Cached full-cell Unicode blocks and shades for gap-free ANSI art.
- Bundled FiraCode Nerd Font Mono regular/bold and Catppuccin Mocha.
- Native fullscreen, independent terminal windows, login-shell selection,
  executable `.command` files, SSH URLs, and Finder Services.

The measured graphics baseline is OpenGL 2.0 / GLSL 1.20. Glyph coverage uses
an A8 atlas bounded to 2048 by 2048 pixels; backgrounds, text, and decorations
use batched VBO draws. An accelerated context is required.

## Controls

| Action | Shortcut |
| --- | --- |
| New independent window | Command-N |
| Toggle fullscreen | Command-Enter |
| Copy / paste | Command-C / Command-V |
| Select text / word / line | Drag / double-click / triple-click |
| Rectangular selection | Option-drag |
| Local selection/scrolling when an app captures the mouse | Hold Shift |
| Scroll history | Mouse wheel |
| Quit | Command-Q or close the window |

Each new window starts a separate process and login shell. Fullscreen retains
that session and restores its previous window geometry. Shell exit closes its
process, including in fullscreen. Executable scripts and SSH links retain their
exit output until the window is closed.

## Configuration

Settings live in `~/.config/snow-ghostty/config`, or
`$XDG_CONFIG_HOME/snow-ghostty/config` when XDG_CONFIG_HOME is an absolute path.
The file is created from bundled defaults if absent:

```ini
font-family = FiraCode Nerd Font Mono
font-size = 12
theme = Catppuccin Mocha
```

An installed font can be selected; an unavailable family falls back to the
bundled font. Font size accepts 6 through 72. Catppuccin Mocha is the only
bundled scheme. Fonts are registered for the app process, without installation
into system font directories. Settings apply to new processes.

Blank lines, whole-line comments, and quoted values are supported. Unknown keys
and invalid settings are rejected with a file/line diagnostic. This is a small
configuration format, not the full upstream Ghostty configuration language.

## Desktop integration

Finder can open executable `.command` files; scripts run from their parent
directory. Finder's **Open in Snow Ghostty** service opens a selected folder or
a file's parent. `ssh://[user@]host[:port]` links launch the system SSH client;
embedded passwords, remote commands, query strings, and fragments are rejected.

**Snow Ghostty → Set as Default Terminal** selects this app as the `.command`
and `ssh://` handler. It does not override applications that explicitly launch
another terminal. Config is preserved across upgrades, including migration from
the older `ghostty-imac` config directory.

## Limitations

- Shaping is per grapheme cell; cross-cell ligatures, complex-script shaping,
  and bidirectional text need a dedicated shaping pass.
- Committed IME input is wired through Cocoa; marked preedit text is not drawn.
- Underline variants use a single line; Kitty image graphics are disabled.
- Visible geometry is rebuilt per redraw; there is no dirty-row mesh cache.
- Config reload and customizable keybindings are not implemented.
