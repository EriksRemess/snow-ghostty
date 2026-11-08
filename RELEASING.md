# Preparing a release

Keep [README.md](README.md) brief. Put user-facing changes in
[CHANGELOG.md](CHANGELOG.md) and detailed controls in [USAGE.md](USAGE.md).

1. Update both bundle versions in `Info.plist`, the CLI version in `src/main.m`,
   the package version in `core/build.zig.zon` and the About probe's expectation.
   The app version is separate from the pinned libghostty-vt version.
2. Review all tracked and new source files. Exclude toolchains, build output,
   local settings, logs, captures and credentials; check source and artifacts
   for private paths, account details and target addresses.
3. Build a fresh app with `CFLAGS=-O2`. Stage a copy and strip its executable
   with the compatible OSXCross `strip -S -x`. Preserve LC_UNIXTHREAD and the
   10.6 deployment target. Include the bundled fonts, theme, icon and licenses.
4. Create a ZIP from the staged app. On Snow Leopard, add an Applications
   symlink to a separate staging folder and create an HFS+ UDZO disk image:

   ```sh
   hdiutil create -srcfolder /path/to/payload -volname "Snow Ghostty VERSION" \
     -fs HFS+ -format UDZO /path/to/Snow-Ghostty-VERSION-macos-x86_64.dmg
   ```

5. Verify the image, attach it read-only and test the packaged app on target:
   CLI/About versions, rendering, PTY/tmux, tabs/windows, controls, startup
   geometry, both resize directions, fullscreen exit and procedural blocks.
   Check ZIP extraction too. Reuse prior checks only when their tested code
   and executable are unchanged.
6. Record checksums, build information and the exact source snapshot. A build
   prepared from uncommitted changes must say so; do not label HEAD as its source
   commit. Keep validation captures and local reports out of public artifacts.

Have the source changes and release notes reviewed before committing. Publish
and push only when explicitly requested. Finalize source provenance after the
release commit, regenerating artifacts/checksums if packaged metadata changes.
