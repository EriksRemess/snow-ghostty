# Using Snow Ghostty

## Features

- Truecolor, bold/italic, faint/inverse, underline and strikethrough.
- Unicode combining characters, wide cells, font fallback, scrollback,
  selection, copy/paste, mouse reporting, and application cursor modes.
- Cached full-cell Unicode blocks and shades for gap-free ANSI art.
- Bundled FiraCode Nerd Font Mono regular/bold and Catppuccin Mocha.
- Native About and menus, Terminal-style tabs, fullscreen, independent windows, login-shell selection,
  executable `.command` files, SSH URLs, and Finder Services.

The measured graphics baseline is OpenGL 2.0 / GLSL 1.20. Glyph coverage uses
an A8 atlas bounded to 2048 by 2048 pixels; backgrounds, text, and decorations
use batched VBO draws. An accelerated context is required.

## Controls

| Action | Shortcut |
| --- | --- |
| New window | Command-N or Dock → New Window |
| Next / previous window | Command-&#96; / Command-Shift-&#96; |
| New tab | Command-T |
| Close current tab (or About panel) | Command-W |
| Close window and all its tabs | Command-Shift-W |
| Previous / next tab | Command-Shift-[ / Command-Shift-] |
| Toggle fullscreen | Command-Enter |
| Copy / paste | Command-C / Command-V |
| Select all terminal content | Command-A |
| Increase / decrease font size | Command-Plus (or Command-=) / Command-Minus |
| Reset font size to configured value | Command-0 |
| Clear scrollback, keeping visible output | Command-K |
| Reset terminal state, keeping the running process | Command-R |
| Open settings in default text editor | Command-, |
| Reload configuration | Command-Shift-, |
| Page Up / Page Down / Home / End | Sent to the running program |
| Scroll history by page / to beginning or end | Shift with the navigation keys |
| Minimize / hide application | Command-M / Command-H |
| Select text / word / line | Drag / double-click / triple-click |
| Rectangular selection | Option-drag |
| Local selection/scrolling when an app captures the mouse | Hold Shift |
| Scroll history | Mouse wheel |
| Quit application | Command-Q |

Windows belong to one app. Each tab has its own login shell,
scrollback and GPU context. Click a tab to select it or its close button to close
that session. The compact tab strip appears when more than one tab is open.
New tabs start in the home directory using the window's current configuration.
Tab names follow application-supplied terminal titles, with the current directory
and foreground command as a fallback. The selected tab and window share a title.

Fullscreen retains all tabs and restores the previous window geometry. Shell
exit closes that tab; closing the last tab closes its window, including in
fullscreen. The app remains in the Dock with no windows; use the Dock's **New
Window** action, click its icon or press Command-N to start another session.
Executable scripts and SSH links retain their exit output until their tab is
closed. Window closing ends only that window's sessions; Quit ends every window.
Opening or cycling windows restores legacy fullscreen first so the next window
can be shown.

Closing a tab asks for confirmation if it has foreground, background or stopped
jobs. Window closing checks its tabs; Quit checks every tab in every window.
Each action asks once if it affects running work.
Cancel preserves the sessions; an idle shell or an already exited session closes
without a prompt. Detached processes are outside these terminal sessions.

**Snow Ghostty → About Snow Ghostty** opens the native Cocoa About panel with
the app version, linked libghostty-vt version, icon and project link. Opening
About from fullscreen restores the window first. Closing About leaves sessions
running. **Window** provides tab switching, Minimize, Zoom and Bring All to Front;
**Help** opens the project documentation in the default browser.

**Snow Ghostty → Secure Keyboard Entry** toggles native secure keyboard input.
The checkmark remembers your choice for this app run. Protection applies while a
terminal window has focus; it is released when another app or a nonterminal panel
takes focus, and on Quit.

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
into system font directories. **Settings…** opens the loaded configuration in
the default text editor, including a file supplied with `--config`. After saving,
use **Reload Configuration** to apply it to every window and tab. Invalid changes
show an error and preserve the current settings. Reloading resets temporary font
zoom to the configured size; font shortcuts otherwise affect only the active tab
and do not write the file.

Blank lines, whole-line comments, and quoted values are supported. Unknown keys
and invalid settings are rejected with a file/line diagnostic. This is a small
configuration format, not the full upstream Ghostty configuration language.

For Powerlevel10k, enable terminal prompt marks in its `~/.p10k.zsh` file:

```zsh
typeset -g POWERLEVEL9K_TERM_SHELL_INTEGRATION=true
```

Start a fresh shell after changing it. These OSC 133 marks let the terminal
recognize prompt rows and avoid duplicating multiline prompts on resize.

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
- Customizable keybindings are not implemented.
