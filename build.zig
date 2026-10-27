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
    // wasm32-wasi is a Tier 2 target for the engine, render and I/O only,
    // single-threaded (TRD §14): no executable, and tests stop below the
    // command core, which needs a full file system and process model.
    const core_only = target.result.cpu.arch.isWasm();
    // Coverage tools read LLVM's debug info; Zig's own x86-64 backend, the
    // Debug default there, gives kcov nothing to map.
    const use_llvm = b.option(bool, "use-llvm", "Compile tests with the LLVM backend");

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption(bool, "debug_allocator", b.option(bool, "debug-allocator", "Use the leak-checking DebugAllocator in release builds too") orelse false);

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
    // Booleans (FR-GEO-4) use Manifold, a C++ library fetched as a lazy
    // package and compiled here; wasm32 and -Dboolean=none build without it.
    const Boolean = enum { manifold, none };
    const boolean = b.option(Boolean, "boolean", "Boolean backend: manifold (default) or none") orelse
        if (core_only) Boolean.none else Boolean.manifold;
    const engine_options = b.addOptions();
    engine_options.addOption(bool, "boolean", boolean == .manifold);
    modules[4].addImport("engine_options", engine_options.createModule());
    if (boolean == .manifold) {
        if (b.lazyDependency("manifold", .{})) |dep| modules[4].linkLibrary(manifoldLibrary(b, dep, target, optimize));
    }

    const cmd_mod = modules[5];
    // One module, shared by the command core and the CLI.
    const options_mod = options.createModule();
    cmd_mod.addImport("build_options", options_mod);
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
    exe.root_module.addImport("build_options", options_mod);
    if (!core_only) {
        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        if (b.args) |args| run.addArgs(args);
        b.step("run", "Run zender").dependOn(&run.step);
    }

    // Unit tests: every module's `test` blocks. test-compile only builds
    // them, so CI can check foreign targets it cannot run.
    const test_step = b.step("test", "Run unit tests");
    const test_compile = b.step("test-compile", "Build unit tests without running them");
    for (modules, layers) |m, l| {
        if (core_only and l.level > 3) continue;
        const t = b.addTest(.{ .name = b.fmt("test-{s}", .{l.name}), .root_module = m, .use_llvm = use_llvm });
        const run_t = if (core_only) blk: {
            // Node's built-in WASI runs them, so no wasm runtime is needed.
            const r = b.addSystemCommand(&.{ "node", "--no-warnings" });
            r.setName(b.fmt("run test-{s} (node wasi)", .{l.name}));
            r.addFileArg(b.path("scripts/run-wasi.mjs"));
            r.addArtifactArg(t);
            break :blk r;
        } else b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
        test_compile.dependOn(&b.addInstallArtifact(t, .{}).step);
    }

    // Golden suites (TRD §15) sit above the command core: they replay
    // command logs and compare with the files in tests/golden.
    if (!core_only) {
        const golden_opts = b.addOptions();
        golden_opts.addOption([]const u8, "dir", b.pathFromRoot("tests/golden"));
        golden_opts.addOption([]const u8, "examples", b.pathFromRoot("examples"));
        golden_opts.addOption(bool, "update", b.option(bool, "update-golden", "Rewrite tests/golden from the current output") orelse false);
        const t = b.addTest(.{
            .name = "test-golden",
            .use_llvm = use_llvm,
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/golden/root.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "math", .module = modules[0] },
                    .{ .name = "io", .module = modules[3] },
                    .{ .name = "engine", .module = modules[4] },
                    .{ .name = "cmd", .module = cmd_mod },
                    .{ .name = "golden_options", .module = golden_opts.createModule() },
                },
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
        test_compile.dependOn(&b.addInstallArtifact(t, .{}).step);
    }
}

const manifold_sources = [_][]const u8{
    "boolean3.cpp",    "boolean_result.cpp", "constructors.cpp", "csg_tree.cpp",
    "edge_op.cpp",     "execution_impl.cpp", "face_op.cpp",      "impl.cpp",
    "manifold.cpp",    "minkowski.cpp",      "polygon.cpp",      "properties.cpp",
    "quickhull.cpp",   "sdf.cpp",            "smoothing.cpp",    "sort.cpp",
    "subdivision.cpp", "tree2d.cpp",
};

/// Manifold v3.5.4 plus Zender's C shim, as a static library: serial (no
/// TBB), no CrossSection, and no FMA contraction, so results do not depend
/// on the target's instruction set.
fn manifoldLibrary(b: *std.Build, dep: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "manifold",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
            // Third-party code: no UBSan traps, and no debug info (it
            // would more than double the binary).
            .sanitize_c = .off,
            .strip = true,
        }),
    });
    const flags = [_][]const u8{ "-std=c++17", "-ffp-contract=off" };
    const m = lib.root_module;
    m.addCMacro("MANIFOLD_PAR", "-1");
    m.addCMacro("MANIFOLD_NO_IOSTREAM", "1");
    m.addCMacro("MANIFOLD_NO_FILESYSTEM", "1");
    m.addIncludePath(dep.path("include"));
    m.addIncludePath(dep.path("src"));
    m.addCSourceFiles(.{ .root = dep.path("src"), .files = &manifold_sources, .flags = &flags });
    m.addCSourceFile(.{ .file = b.path("src/geom/manifold/shim.cpp"), .flags = &flags });
    return lib;
}
