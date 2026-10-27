const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const sqlite = b.dependency("sqlite", .{});
    const bzip2 = b.dependency("bzip2", .{});

    const c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    c.addIncludePath(sqlite.path(""));
    c.addIncludePath(bzip2.path(""));

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = c.createModule() }},
    });
    mod.addIncludePath(sqlite.path(""));
    mod.addIncludePath(bzip2.path(""));
    mod.addCSourceFile(.{
        .file = sqlite.path("sqlite3.c"),
        .flags = &.{ "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_THREADSAFE=0", "-DSQLITE_DEFAULT_MEMSTATUS=0" },
    });
    mod.addCSourceFiles(.{
        .root = bzip2.path(""),
        .files = &.{ "blocksort.c", "huffman.c", "crctable.c", "randtable.c", "compress.c", "decompress.c", "bzlib.c" },
        .flags = &.{"-DBZ_NO_STDIO"},
    });

    const exe = b.addExecutable(.{ .name = "postilla-content", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    run.setCwd(b.path("."));
    b.step("run", "Roda o pipeline: zig build run -- <fetch|dict|stories|pack>").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path("."));
    b.step("test", "Roda os testes").dependOn(&run_tests.step);
}
