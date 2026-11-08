-include config.mk

CLANG ?= clang
ZIG ?= zig
ZIG_VERSION = 0.17.0
SDK ?=
OSXCROSS_BIN ?=
LINKER ?= $(OSXCROSS_BIN)/x86_64-apple-darwin10-ld
TARGET_FLAGS = --target=x86_64-apple-macosx10.6 -march=core2 -isysroot "$(SDK)"
CFLAGS ?= -O2 -g
RAW_CORE = core/zig-out/lib/libghostty-vt-static.a
CORE = build/libghostty-vt.a
INCLUDES = -Icore/zig-out/include -Isrc -DGHOSTTY_STATIC
FRONTEND_SOURCES = src/application.m src/settings.m src/window.m src/session.m src/terminal.m src/renderer.m src/fonts.m src/commands.m src/input.m src/diagnostics.m src/config.m src/desktop.m src/menus.m src/tabs.m src/platform.c
FRONTEND_HEADERS = $(wildcard src/*.h)
FRONTEND_LIBS = -lproc -framework Cocoa -framework ApplicationServices -framework OpenGL -framework Carbon
RESOURCES = $(shell find resources -type f)
BUNDLE = build/Snow Ghostty.app
APP_TARGET = build/Snow\ Ghostty.app/Contents/MacOS/snow-ghostty

.PHONY: all check-toolchain
all: $(APP_TARGET) build/gpu-probe build/vt-probe

check-toolchain:
	@test -n "$(SDK)" -a -d "$(SDK)/System/Library/Frameworks" || { echo "Set SDK to a MacOSX10.6.sdk directory (see README.md)" >&2; exit 1; }
	@test -n "$(OSXCROSS_BIN)" -a -x "$(OSXCROSS_BIN)/x86_64-apple-darwin10-ar" -a -x "$(LINKER)" || { echo "Set OSXCROSS_BIN to the OSXCross target/bin directory (see README.md)" >&2; exit 1; }

$(APP_TARGET): src/main.m $(FRONTEND_SOURCES) $(FRONTEND_HEADERS) Info.plist $(CORE) Makefile $(RESOURCES) | check-toolchain
	@mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources"
	$(CLANG) $(TARGET_FLAGS) $(INCLUDES) -Wall -Wextra $(CFLAGS) --ld-path="$(LINKER)" src/main.m $(FRONTEND_SOURCES) $(CORE) -Wl,-dead_strip $(FRONTEND_LIBS) -o "$@"
	cp Info.plist "$(BUNDLE)/Contents/Info.plist"
	cp vendor/ghostty/LICENSE "$(BUNDLE)/Contents/Resources/Ghostty-LICENSE.txt"
	cp upstream.lock.json "$(BUNDLE)/Contents/Resources/libghostty-build.json"
	cp -R resources/. "$(BUNDLE)/Contents/Resources/"

.PHONY: core
core:
	@test "$$($(ZIG) version)" = "$(ZIG_VERSION)" || { echo "Zig $(ZIG_VERSION) is required" >&2; exit 1; }
	cd core && ZIG_GLOBAL_CACHE_DIR="$(abspath .research/zig-cache)" $(ZIG) build -Dtarget=x86_64-macos.10.6 -Dcpu=core2 -Doptimize=ReleaseFast
	touch $(RAW_CORE)

$(RAW_CORE): core/build.zig core/build.zig.zon upstream.lock.json vendor/ghostty/build.zig vendor/ghostty/src/lib/TinyIo.zig $(wildcard patches/*.patch)
	$(MAKE) core

$(CORE): $(RAW_CORE) scripts/prepare-archive.py | check-toolchain
	python3 scripts/prepare-archive.py $(RAW_CORE) $@ --tools "$(OSXCROSS_BIN)"

build/vt-probe: probes/vt-probe.c src/platform.c src/platform.h $(CORE) Makefile | check-toolchain
	@mkdir -p build
	$(CLANG) $(TARGET_FLAGS) $(INCLUDES) -std=c99 -Wall -Wextra $(CFLAGS) --ld-path="$(LINKER)" probes/vt-probe.c src/platform.c $(CORE) -Wl,-dead_strip -o $@

build/gpu-probe: probes/gpu-probe.c Makefile | check-toolchain
	@mkdir -p build
	$(CLANG) $(TARGET_FLAGS) -std=c99 -Wall -Wextra -Wpedantic $(CFLAGS) --ld-path="$(LINKER)" $< -framework OpenGL -o $@

build/lifecycle-probe: probes/lifecycle-probe.m Makefile | check-toolchain
	@mkdir -p build
	$(CLANG) $(TARGET_FLAGS) -Wall -Wextra $(CFLAGS) --ld-path="$(LINKER)" $< -framework Cocoa -framework ApplicationServices -framework Carbon -o $@

build/menus-probe: probes/menus-probe.m $(FRONTEND_SOURCES) $(FRONTEND_HEADERS) $(CORE) Makefile | check-toolchain
	@mkdir -p build
	$(CLANG) $(TARGET_FLAGS) $(INCLUDES) -Wall -Wextra $(CFLAGS) --ld-path="$(LINKER)" probes/menus-probe.m $(FRONTEND_SOURCES) $(CORE) -Wl,-dead_strip $(FRONTEND_LIBS) -o $@
