# Bundled resources

- `fonts/` contains FiraCode Nerd Font Mono regular and bold, based on
  [Fira Code](https://github.com/tonsky/FiraCode) and patched by
  [Nerd Fonts](https://github.com/ryanoasis/nerd-fonts). Fonts register with
  CoreText at process scope. Italic text uses a synthesized oblique face.
- `themes/catppuccin-mocha.theme` supplies the
  [Catppuccin Mocha](https://github.com/catppuccin/ghostty) palette and defaults.
  No other color scheme is bundled.
- `default.config` selects FiraCode Nerd Font Mono at size 12 and Mocha.
- `icons/ghostty-gtk-512.png` is Ghostty's GTK artwork. `AppIcon-gtk.icns` packages
  it at 16, 32, 48, 128, 256, and 512 pixels for Snow Leopard. Smaller entries
  use legacy RGB/alpha ICNS representations; larger entries use PNG.

Upstream notices and license texts are in `licenses/`. Public upstream author
credits in these notices and font metadata are retained.

Regenerate the icon using Pillow:

```sh
python3 scripts/package-icon.py resources/icons/ghostty-gtk-512.png resources/AppIcon-gtk.icns
```

Normal builds use the checked-in ICNS and do not require Pillow.
