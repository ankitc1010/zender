const std = @import("std");

/// Module graph (FR-ARCH-1). A module is given imports only for modules in
/// lower layers, so an upward or sideways import fails to compile.
///
///   5 front ends   mcp, cli, capi          (src/mcp, src/cli, src/capi)
///   4 command core cmd                     (src/cmd)
///   3 engine       engine = core+geom+eval (src/engine.zig)
///   2 render, I/O  render, io              (src/render, src/io)
///   1 interchange  ir                      (src/ir)
///   0 platform     math                    (src/math)
const Layer = struct {
    name: []const u8,
    root: []const u8,
    level: u8,
    deps: []const []const u8,
};

const layers = [_]Layer{
    .{ .name = "math", .root = "src/math/root.zig", .level = 0, .deps = &.{} },
    .{ .name = "ir", .root = "src/ir/root.zig", .level = 1, .deps = &.{"math"} },
    .{ .name = "render", .root = "src/render/root.zig", .level = 2, .deps = &.{ "math", "ir" } },
    .{ .name = "io", .root = "src/io/root.zig", .level = 2, .deps = &.{ "math", "ir" } },
    .{ .name = "engine", .root = "src/engine.zig", .level = 3, .deps = &.{ "math", "ir" } },
    .{ .name = "cmd", .root = "src/cmd/root.zig", .level = 4, .deps = &.{ "math", "ir", "render", "io", "engine" } },
    .{ .name = "mcp", .root = "src/mcp/root.zig", .level = 5, .deps = &.{ "math", "cmd" } },
};

fn levelOf(name: []const u8) u8 {
    for (layers) |l| if (std.mem.eql(u8, l.name, name)) return l.level;
    @panic("unknown module");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Non-kernel code builds ReleaseSafe by default (NFR-8).
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimize mode (default ReleaseSafe)") orelse .ReleaseSafe;
    const version = b.option([]const u8, "version", "Version string") orelse "0.1.0-dev";

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    var modules: [layers.len]*std.Build.Module = undefined;
    for (layers, 0..) |l, i| {
        modules[i] = b.createModule(.{
            .root_source_file = b.path(l.root),
            .target = target,
            .optimize = optimize,
        });
        for (l.deps) |d| {
            if (levelOf(d) >= l.level) @panic("module may only import lower layers");
            for (layers, 0..) |dl, j| {
                if (std.mem.eql(u8, dl.name, d)) modules[i].addImport(d, modules[j]);
            }
        }
    }
    const cmd_mod = modules[5];
    cmd_mod.addOptions("build_options", options);
    const mcp_mod = modules[6];

    // The zender executable: CLI front end, which also hosts the MCP server.
    const exe = b.addExecutable(.{
        .name = "zender",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cmd", .module = cmd_mod },
                .{ .name = "mcp", .module = mcp_mod },
                .{ .name = "math", .module = modules[0] },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run zender").dependOn(&run.step);

    // Unit tests: every module's `test` blocks. test-compile only builds
    // them, so CI can check foreign targets it cannot run.
    const test_step = b.step("test", "Run unit tests");
    const test_compile = b.step("test-compile", "Build unit tests without running them");
    for (modules, layers) |m, l| {
        const t = b.addTest(.{ .name = b.fmt("test-{s}", .{l.name}), .root_module = m });
        test_step.dependOn(&b.addRunArtifact(t).step);
        test_compile.dependOn(&b.addInstallArtifact(t, .{}).step);
    }
}
