//! zender command line (TRD §11). Every subcommand goes through the same
//! command core as MCP, so a CLI run and an agent session produce the same
//! command-log entries and outputs.
//!
//! Exit codes (FR-CLI-3): 0 success, 1 user error, 2 I/O error, 3 internal.

const std = @import("std");
const cmd = @import("cmd");
const mcp = @import("mcp");
const math = @import("math");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const usage =
    \\zender — headless 3D scene engine driven over MCP
    \\
    \\usage:
    \\  zender serve --stdio [options]      MCP server on stdin/stdout (MCP 2026-07-28; 2025-11-25 initialize accepted)
    \\  zender run <ops.jsonl> -o <out>     replay a command log; write .glb, .gltf or .png
    \\  zender tools [--json]               list the tools
    \\  zender version
    \\
    \\options:
    \\  --allow-root <dir>   directory tools may read and write (repeatable; default: current directory)
    \\  --threads <n>        worker threads for rendering (default: CPU count)
    \\  --content <mode>     MCP tool result content: full (summary + JSON, default) or summary
    \\  --json               machine-readable output (run, tools)
    \\  --width/--height <px>  size of a .png written by run
    \\  --log-format <f>     stderr log lines: json (serve default), text, or off (default otherwise)
    \\  --trace-file <path>  append one OpenTelemetry span per tool call, as OTLP/JSON lines
    \\
    \\budgets per call (SEC-3; set by the operator, never by the agent):
    \\  --max-triangles <n>        triangles one call may create (default 20000000)
    \\  --max-scene-mb <n>         scene memory (default 4096)
    \\  --max-wall-ms <n>          wall time of one call (default 60000)
    \\  --max-render-edge <px>     longest render side (default 8192)
    \\  --max-spp <n>              samples per pixel (default 4096)
    \\  --confirm-delete-over <n>  deleting more objects than this needs confirmation (default 10)
    \\
;

const Exit = enum(u8) { ok = 0, user = 1, io = 2, internal = 3 };

const Options = struct {
    command: []const u8 = "",
    positional: std.ArrayList([]const u8) = .empty,
    roots: std.ArrayList([]const u8) = .empty,
    output: ?[]const u8 = null,
    threads: ?usize = null,
    json: bool = false,
    stdio: bool = false,
    content: mcp.protocol.ContentMode = .full,
    width: ?u32 = null,
    height: ?u32 = null,
    budgets: cmd.server.Budgets = .{},
    log_format: ?cmd.telemetry.LogFormat = null,
    trace_file: ?[]const u8 = null,
};

/// Parses the value after a numeric option, within 1..max.
fn number(it: anytype, arg: []const u8, max: u64) error{Usage}!u64 {
    const v = it.next() orelse {
        _ = fail("{s} needs a number", .{arg});
        return error.Usage;
    };
    const n = std.fmt.parseInt(u64, v, 10) catch {
        _ = fail("{s}: '{s}' is not a number", .{ arg, v });
        return error.Usage;
    };
    if (n == 0 or n > max) {
        _ = fail("{s} must be 1..{d}", .{ arg, max });
        return error.Usage;
    }
    return n;
}

pub fn main(init: std.process.Init) u8 {
    const code = run(init) catch |e| {
        std.debug.print("zender: internal error: {t}\n", .{e});
        return @intFromEnum(Exit.internal);
    };
    return @intFromEnum(code);
}

fn fail(comptime fmt: []const u8, args: anytype) Exit {
    std.debug.print("zender: " ++ fmt ++ "\n", args);
    return .user;
}

fn run(init: std.process.Init) !Exit {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var opts: Options = .{};
    // The allocating iterator also works on Windows.
    var it = try init.minimal.args.iterateAllocator(arena);
    _ = it.next(); // program name
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--allow-root")) {
            try opts.roots.append(arena, it.next() orelse return fail("--allow-root needs a directory", .{}));
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            opts.output = it.next() orelse return fail("-o needs a path", .{});
        } else if (std.mem.eql(u8, arg, "--threads")) {
            const v = it.next() orelse return fail("--threads needs a number", .{});
            opts.threads = std.fmt.parseInt(usize, v, 10) catch return fail("--threads: '{s}' is not a number", .{v});
            if (opts.threads.? == 0 or opts.threads.? > 1024) return fail("--threads must be 1..1024", .{});
        } else if (std.mem.eql(u8, arg, "--width") or std.mem.eql(u8, arg, "--height")) {
            const v = it.next() orelse return fail("{s} needs a number", .{arg});
            const n = std.fmt.parseInt(u32, v, 10) catch return fail("{s}: '{s}' is not a number", .{ arg, v });
            if (arg[2] == 'w') opts.width = n else opts.height = n;
        } else if (std.mem.eql(u8, arg, "--content")) {
            const v = it.next() orelse return fail("--content needs full or summary", .{});
            opts.content = std.meta.stringToEnum(mcp.protocol.ContentMode, v) orelse return fail("--content must be full or summary", .{});
        } else if (std.mem.eql(u8, arg, "--log-format")) {
            const v = it.next() orelse return fail("--log-format needs json, text or off", .{});
            opts.log_format = std.meta.stringToEnum(cmd.telemetry.LogFormat, v) orelse return fail("--log-format must be json, text or off", .{});
        } else if (std.mem.eql(u8, arg, "--trace-file")) {
            opts.trace_file = it.next() orelse return fail("--trace-file needs a path", .{});
        } else if (std.mem.eql(u8, arg, "--max-triangles")) {
            opts.budgets.max_triangles = number(&it, arg, 1 << 40) catch return .user;
        } else if (std.mem.eql(u8, arg, "--max-scene-mb")) {
            opts.budgets.max_scene_bytes = (number(&it, arg, 1 << 30) catch return .user) << 20;
        } else if (std.mem.eql(u8, arg, "--max-wall-ms")) {
            opts.budgets.max_wall_ms = number(&it, arg, 1 << 40) catch return .user;
        } else if (std.mem.eql(u8, arg, "--max-render-edge")) {
            opts.budgets.max_render_edge = @intCast(number(&it, arg, 65536) catch return .user);
        } else if (std.mem.eql(u8, arg, "--max-spp")) {
            opts.budgets.max_spp = @intCast(number(&it, arg, 1 << 20) catch return .user);
        } else if (std.mem.eql(u8, arg, "--confirm-delete-over")) {
            opts.budgets.delete_confirm_over = @intCast(number(&it, arg, 1 << 30) catch return .user);
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
        } else if (std.mem.eql(u8, arg, "--stdio")) {
            opts.stdio = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try writeStdout(io, usage);
            return .ok;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return fail("unknown option '{s}' (see zender --help)", .{arg});
        } else if (opts.command.len == 0) {
            opts.command = arg;
        } else {
            try opts.positional.append(arena, arg);
        }
    }

    if (opts.command.len == 0) {
        try writeStdout(io, usage);
        return .user;
    }
    if (std.mem.eql(u8, opts.command, "version")) {
        try writeStdout(io, "zender " ++ cmd.version ++ "\n");
        return .ok;
    }

    if (opts.roots.items.len == 0) try opts.roots.append(arena, ".");
    const roots = cmd.paths.Roots.init(io, arena, opts.roots.items) catch |e| {
        return fail("cannot use --allow-root: {t}", .{e});
    };
    var pool = math.Pool.init(io);
    if (opts.threads) |t| pool.threads = t;
    const serving = std.mem.eql(u8, opts.command, "serve");
    var tel: cmd.telemetry.Telemetry = .{ .io = io, .version = cmd.version, .log_format = opts.log_format orelse if (serving) .json else .off };
    defer tel.deinit();
    if (opts.trace_file) |path| tel.openTraceFile(path) catch |e| {
        std.debug.print("zender: cannot open trace file '{s}': {t}\n", .{ path, e });
        return .io;
    };
    const record = tel.log_format != .off or tel.trace_file != null;
    var server = cmd.Server.init(gpa, io, pool, .{ .roots = roots, .budgets = opts.budgets, .telemetry = if (record) &tel else null }, cmd.catalog.tools);
    defer server.deinit();

    if (serving) {
        if (!opts.stdio) return fail("serve needs --stdio (Streamable HTTP arrives in P3)", .{});
        const b = opts.budgets;
        tel.event(arena, "info", "server started", .{
            .version = cmd.version,
            .transport = "stdio",
            .roots = roots.list,
            .threads = pool.threads,
            .max_triangles = b.max_triangles,
            .max_scene_bytes = b.max_scene_bytes,
            .max_wall_ms = b.max_wall_ms,
            .max_render_edge = b.max_render_edge,
            .max_spp = b.max_spp,
        });
        var session: mcp.Session = .{ .server = &server, .content = opts.content };
        try mcp.stdio.serve(io, gpa, &session);
        return .ok;
    }
    if (std.mem.eql(u8, opts.command, "tools")) return listTools(io, arena, &server, opts.json);
    if (std.mem.eql(u8, opts.command, "run")) return replayLog(io, arena, &server, &opts);
    if (std.mem.eql(u8, opts.command, "convert") or std.mem.eql(u8, opts.command, "inspect") or
        std.mem.eql(u8, opts.command, "render") or std.mem.eql(u8, opts.command, "validate"))
    {
        return fail("'{s}' needs file importers, which arrive with .blend and glTF reading (P1/P2)", .{opts.command});
    }
    return fail("unknown command '{s}' (see zender --help)", .{opts.command});
}

fn writeStdout(io: Io, bytes: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writerStreaming(io, &buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

fn listTools(io: Io, arena: Allocator, server: *cmd.Server, json: bool) !Exit {
    var out: std.Io.Writer.Allocating = .init(arena);
    if (json) {
        var w: std.json.Stringify = .{ .writer = &out.writer };
        try w.beginArray();
        for (server.tools) |t| {
            try w.beginObject();
            try w.objectField("name");
            try w.write(t.name);
            try w.objectField("description");
            try w.write(t.description);
            try w.objectField("inputSchema");
            try cmd.schema.writeInputSchema(t.params, &w);
            try w.endObject();
        }
        try w.endArray();
        try out.writer.writeByte('\n');
    } else {
        for (server.tools) |t| try out.writer.print("{s:<24} {s}\n", .{ t.name, t.title });
    }
    try writeStdout(io, out.written());
    return .ok;
}

fn replayLog(io: Io, arena: Allocator, server: *cmd.Server, opts: *const Options) !Exit {
    if (opts.positional.items.len != 1) return fail("run needs exactly one command log (ops.jsonl)", .{});
    const path = opts.positional.items[0];
    const log = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 30)) catch |e| {
        std.debug.print("zender: cannot read '{s}': {t}\n", .{ path, e });
        return .io;
    };
    const r = try cmd.replay.run(server, arena, log);
    if (r.failed_line != 0) {
        std.debug.print("zender: {s}:{d}: {s}\n", .{ path, r.failed_line, r.message });
        return .user;
    }

    var output_json: []const u8 = "null";
    if (opts.output) |out_path| {
        const ext = std.fs.path.extension(out_path);
        var args: std.json.ObjectMap = .empty;
        try args.put(arena, "scene_id", .{ .string = r.scene_id });
        try args.put(arena, "path", .{ .string = out_path });
        try args.put(arena, "overwrite", .{ .bool = true });
        const tool = if (std.ascii.eqlIgnoreCase(ext, ".png")) blk: {
            if (opts.width) |w| try args.put(arena, "width", .{ .integer = w });
            if (opts.height) |h| try args.put(arena, "height", .{ .integer = h });
            break :blk "render.preview";
        } else "io.export";
        const outcome = try server.call(arena, tool, .{ .object = args });
        switch (outcome) {
            .ok => |ok| {
                output_json = ok.structured;
                if (!opts.json) std.debug.print("{s}\n", .{ok.summary});
            },
            .tool_error => |te| {
                std.debug.print("zender: {s}: {s}\n", .{ @tagName(te.code), te.message });
                return if (te.code == .io_error or te.code == .permission_denied or te.code == .not_found) .io else .user;
            },
            .unknown_tool => unreachable,
        }
    }
    if (opts.json) {
        var out: std.Io.Writer.Allocating = .init(arena);
        try out.writer.print("{{\"ok\":true,\"steps\":{d},\"scene_id\":\"{s}\",\"output\":{s}}}\n", .{ r.steps, r.scene_id, output_json });
        try writeStdout(io, out.written());
    } else {
        std.debug.print("Replayed {d} step(s).\n", .{r.steps});
    }
    return .ok;
}
