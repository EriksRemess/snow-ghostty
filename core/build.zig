const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ghostty = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .simd = false,
        .@"emit-lib-vt" = true,
        .@"vt-features" = "-kitty-graphics",
        .@"lib-version-string" = "1.0.1",
    });
    const lib = ghostty.artifact("ghostty-vt-static");
    // Use Snow Leopard's malloc rather than Zig's modern Darwin SMP allocator.
    lib.root_module.link_libc = true;
    b.installArtifact(lib);
    b.installDirectory(.{
        .source_dir = ghostty.path("include/ghostty"),
        .install_dir = .header,
        .install_subdir = "ghostty",
    });
}
