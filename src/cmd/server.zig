//! The command core: open scenes, the tool table, and `call`, the one code
//! path every front end goes through (TRD §5, FR-ARCH-2). A call is
//! validated against its schema, run inside a transaction when it mutates,
//! checked against budgets, logged, and turned into a structured result.

const std = @import("std");
const math = @import("math");
const engine = @import("engine");
const schema = @import("schema.zig");
const paths = @import("paths.zig");
const telemetry = @import("telemetry.zig");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Stringify = std.json.Stringify;
const Value = std.json.Value;
const core = engine.core;
const Document = core.Document;
const IdHandle = core.IdHandle;

pub const version = build_options.version;

pub const Budgets = struct {
    /// Output triangles one call may create (SEC-3).
    max_triangles: u64 = 20_000_000,
    max_scene_bytes: u64 = 4 << 30,
    /// Wall time for synchronous tools, in milliseconds.
    max_wall_ms: u64 = 60_000,
    max_render_edge: u32 = 8192,
    max_spp: u32 = 4096,
    /// Deleting more objects than this needs confirmation (FR-MCP-7).
    delete_confirm_over: usize = 10,
};

pub const Config = struct {
    roots: paths.Roots,
    budgets: Budgets = .{},
    /// Renders kept per scene for resource reads.
    max_renders: usize = 8,
    /// Spans and log lines per call; null records nothing.
    telemetry: ?*telemetry.Telemetry = null,
};

pub const Image = struct { mime: []const u8, bytes: []const u8 };
pub const Link = struct { uri: []const u8, name: []const u8, mime: []const u8 };

pub const Render = struct {
    job: u64,
    png: []u8,
    width: u32,
    height: u32,
};

pub const SceneEntry = struct {
    id: []const u8,
    doc: Document,
    seed: u64,
    /// One JSON record per mutation (FR-CLI-1).
    log: std.ArrayList([]u8) = .empty,
    renders: std.ArrayList(Render) = .empty,
    eval_cache: engine.eval.Cache,

    fn deinit(e: *SceneEntry, gpa: Allocator) void {
        e.eval_cache.deinit();
        for (e.log.items) |l| gpa.free(l);
        e.log.deinit(gpa);
        for (e.renders.items) |r| gpa.free(r.png);
        e.renders.deinit(gpa);
        e.doc.deinit();
        gpa.free(e.id);
    }
};

pub const Kind = enum {
    /// Reads nothing scene-specific (schema.describe, ops.list).
    global,
    /// Reads a scene; never changes it.
    read_only,
    /// Changes a scene inside a transaction.
    mutating,
    /// Changes the set of open scenes or walks history (create, close, undo).
    lifecycle,
};

pub const HandlerError = error{ ToolFailed, OutOfMemory, WriteFailed };

pub const Tool = struct {
    name: []const u8,
    title: []const u8,
    description: []const u8,
    params: []const schema.Param,
    kind: Kind,
    destructive: bool = false,
    idempotent: bool = false,
    /// Touches files outside the scene (io.*).
    open_world: bool = false,
    handler: *const fn (*Call) HandlerError!void,
};

pub const ErrorCode = enum {
    invalid_argument,
    not_found,
    stale_handle,
    rev_mismatch,
    budget_exceeded,
    io_error,
    permission_denied,
    unsupported,
    confirmation_required,
    invalid_operation,
    internal,
};

pub const ToolError = struct {
    code: ErrorCode,
    message: []const u8,
    path: []const u8 = "",
    hint: []const u8 = "",
    valid_values: []const []const u8 = &.{},
};

pub const Ref = struct { handle: IdHandle, name: []const u8 };

pub const Success = struct {
    /// structuredContent, a JSON object.
    structured: []const u8,
    summary: []const u8,
    image: ?Image = null,
    links: []const Link = &.{},
};

pub const Outcome = union(enum) {
    ok: Success,
    tool_error: ToolError,
    unknown_tool,
};

/// Per-call context handed to tool handlers.
pub const Call = struct {
    server: *Server,
    arena: Allocator,
    tool: *const Tool,
    args: schema.Args,
    entry: ?*SceneEntry = null,
    /// Tool-specific result fields; an open JSON object.
    out: Stringify,
    out_buf: *std.Io.Writer.Allocating,
    changed: *std.ArrayList(Ref),
    created: *std.ArrayList(Ref),
    warnings: *std.ArrayList([]const u8),
    summary: []const u8 = "",
    image: ?Image = null,
    links: std.ArrayList(Link) = .empty,
    err: ?ToolError = null,
    /// Triangles created so far in this call (budget accounting).
    triangles: u64 = 0,
    /// Set while running inside scene.apply.
    in_batch: bool = false,
    /// Replaces the resolved arguments in the command log (scene.apply).
    log_params: ?Value = null,

    pub fn doc(c: *Call) *Document {
        return &c.entry.?.doc;
    }

    /// The scene evaluated to interchange form, reusing cached results.
    pub fn evaluate(c: *Call) HandlerError!engine.ir.Scene {
        const e = c.entry.?;
        return engine.eval.flatten.flatten(c.arena, &e.doc, .{ .pool = c.server.pool, .cache = &e.eval_cache }) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            // Past the wall-time budget; callInner reports it.
            error.DeadlineExceeded => error.ToolFailed,
        };
    }

    pub fn fail(c: *Call, code: ErrorCode, comptime fmt: []const u8, args: anytype) HandlerError {
        c.err = .{ .code = code, .message = try std.fmt.allocPrint(c.arena, fmt, args) };
        return error.ToolFailed;
    }

    pub fn failAt(c: *Call, code: ErrorCode, path: []const u8, hint: []const u8, valid: []const []const u8, comptime fmt: []const u8, args: anytype) HandlerError {
        c.err = .{ .code = code, .message = try std.fmt.allocPrint(c.arena, fmt, args), .path = path, .hint = hint, .valid_values = valid };
        return error.ToolFailed;
    }

    pub fn say(c: *Call, comptime fmt: []const u8, args: anytype) HandlerError!void {
        c.summary = try std.fmt.allocPrint(c.arena, fmt, args);
    }

    pub fn warn(c: *Call, comptime fmt: []const u8, args: anytype) HandlerError!void {
        try c.warnings.append(c.arena, try std.fmt.allocPrint(c.arena, fmt, args));
    }

    pub fn markChanged(c: *Call, h: IdHandle, name: []const u8) HandlerError!void {
        for (c.changed.items) |r| if (r.handle.eql(h)) return;
        for (c.created.items) |r| if (r.handle.eql(h)) return;
        try c.changed.append(c.arena, .{ .handle = h, .name = try c.arena.dupe(u8, name) });
    }

    pub fn markCreated(c: *Call, h: IdHandle, name: []const u8) HandlerError!void {
        try c.created.append(c.arena, .{ .handle = h, .name = try c.arena.dupe(u8, name) });
    }

    /// Counts triangles against the per-call budget before creating them.
    pub fn spendTriangles(c: *Call, n: u64) HandlerError!void {
        c.triangles += n;
        const max = c.server.config.budgets.max_triangles;
        if (c.triangles > max) {
            return c.failAt(.budget_exceeded, "", "lower segments/subdivisions, or ask the operator to raise the budget", &.{}, "this call would create {d} triangles; the budget is {d}", .{ c.triangles, max });
        }
    }

    fn names(c: *Call, comptime t: core.IdType) HandlerError![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        var it = c.doc().db.pool(t).iterator();
        while (it.next()) |e| {
            if (list.items.len == 50) break;
            try list.append(c.arena, try c.arena.dupe(u8, e.value.name.slice()));
        }
        return list.items;
    }

    /// Looks a datablock up by name (or handle string such as "OB3.1").
    pub fn lookup(c: *Call, comptime t: core.IdType, name: []const u8, arg_path: []const u8) HandlerError!IdHandle {
        const db = &c.doc().db;
        if (IdHandle.parse(name)) |h| {
            if (h.type == t) {
                if (db.get(t, h) != null) return h;
                return c.failAt(.stale_handle, arg_path, "the datablock was deleted or replaced; look it up again by name", &.{}, "handle '{s}' is stale", .{name});
            }
        }
        if (db.findByName(t, name)) |h| return h;
        return c.failAt(.not_found, arg_path, "names are case-sensitive; valid_values lists existing names", try c.names(t), "no {s} named '{s}'", .{ @tagName(t), name });
    }

    pub fn object(c: *Call, arg: []const u8) HandlerError!IdHandle {
        const name = c.args.str(arg) orelse return c.fail(.invalid_argument, "missing '{s}'", .{arg});
        return c.lookup(.object, name, try std.fmt.allocPrint(c.arena, "/{s}", .{arg}));
    }

    pub fn field(c: *Call, name: []const u8) HandlerError!void {
        try c.out.objectField(name);
    }

    pub fn link(c: *Call, uri: []const u8, name: []const u8, mime: []const u8) HandlerError!void {
        try c.links.append(c.arena, .{ .uri = uri, .name = name, .mime = mime });
    }
};

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    pool: math.Pool,
    config: Config,
    tools: []const Tool,
    scenes: std.StringArrayHashMapUnmanaged(*SceneEntry) = .empty,
    next_job: u64 = 1,
    tools_json: ?[]u8 = null,

    pub fn init(gpa: Allocator, io: Io, pool: math.Pool, config: Config, tools: []const Tool) Server {
        return .{ .gpa = gpa, .io = io, .pool = pool, .config = config, .tools = tools };
    }

    pub fn deinit(s: *Server) void {
        for (s.scenes.values()) |e| {
            e.deinit(s.gpa);
            s.gpa.destroy(e);
        }
        s.scenes.deinit(s.gpa);
        if (s.tools_json) |j| s.gpa.free(j);
    }

    pub fn findTool(s: *const Server, name: []const u8) ?*const Tool {
        for (s.tools) |*t| if (std.mem.eql(u8, t.name, name)) return t;
        return null;
    }

    /// Opens a new scene entry around `doc`, minting its id.
    pub fn addScene(s: *Server, doc: Document, seed: u64) Allocator.Error!*SceneEntry {
        var bytes: [4]u8 = undefined;
        while (true) {
            s.io.random(&bytes);
            var buf: [16]u8 = undefined;
            const id = std.fmt.bufPrint(&buf, "scn_{x}", .{std.mem.readInt(u32, &bytes, .little)}) catch unreachable;
            if (s.scenes.contains(id)) continue;
            const e = try s.gpa.create(SceneEntry);
            errdefer s.gpa.destroy(e);
            e.* = .{ .id = try s.gpa.dupe(u8, id), .doc = doc, .seed = seed, .eval_cache = .init(s.gpa) };
            try s.scenes.put(s.gpa, e.id, e);
            return e;
        }
    }

    pub fn closeScene(s: *Server, id: []const u8) bool {
        const kv = s.scenes.fetchOrderedRemove(id) orelse return false;
        kv.value.deinit(s.gpa);
        s.gpa.destroy(kv.value);
        return true;
    }

    pub fn storeRender(s: *Server, e: *SceneEntry, png: []u8, width: u32, height: u32) Allocator.Error!u64 {
        const job = s.next_job;
        s.next_job += 1;
        if (e.renders.items.len >= s.config.max_renders) {
            const old = e.renders.orderedRemove(0);
            s.gpa.free(old.png);
        }
        try e.renders.append(s.gpa, .{ .job = job, .png = png, .width = width, .height = height });
        return job;
    }

    /// Runs one tool call. `arena` owns everything in the outcome.
    pub fn call(s: *Server, arena: Allocator, name: []const u8, raw_args: ?Value) Allocator.Error!Outcome {
        return s.callTraced(arena, name, raw_args, null);
    }

    /// `call`, continuing the caller's trace (FR-MCP-3).
    pub fn callTraced(s: *Server, arena: Allocator, name: []const u8, raw_args: ?Value, parent: ?telemetry.TraceContext) Allocator.Error!Outcome {
        const tool = s.findTool(name) orelse return .unknown_tool;
        var changed: std.ArrayList(Ref) = .empty;
        var created: std.ArrayList(Ref) = .empty;
        var warnings: std.ArrayList([]const u8) = .empty;
        const t = s.config.telemetry orelse return s.callInner(arena, tool, raw_args, &changed, &created, &warnings, null);

        const span = t.startSpan(parent);
        const start_ns = t.now();
        const out = try s.callInner(arena, tool, raw_args, &changed, &created, &warnings, null);
        var rec: telemetry.CallRecord = .{ .tool = tool.name, .start_ns = start_ns, .end_ns = t.now(), .parent = parent };
        switch (out) {
            .ok => |ok| if (std.mem.eql(u8, tool.name, "scene.create")) {
                // The new scene's id exists only in the result.
                const v = std.json.parseFromSliceLeaky(Value, arena, ok.structured, .{}) catch null;
                if (v) |x| if (x.object.get("scene_id")) |id| if (id == .string) {
                    rec.scene_id = id.string;
                };
            },
            .tool_error => |te| {
                rec.error_code = @tagName(te.code);
                rec.error_message = te.message;
            },
            .unknown_tool => {},
        }
        if (rec.scene_id == null) if (raw_args) |a| if (a == .object) if (a.object.get("scene_id")) |id| if (id == .string) {
            rec.scene_id = id.string;
        };
        if (rec.scene_id) |id| if (s.scenes.get(id)) |e| {
            rec.scene_rev = e.doc.rev;
        };
        t.recordCall(arena, span, rec);
        return out;
    }

    fn callInner(
        s: *Server,
        arena: Allocator,
        tool: *const Tool,
        raw_args: ?Value,
        changed: *std.ArrayList(Ref),
        created: *std.ArrayList(Ref),
        warnings: *std.ArrayList([]const u8),
        batch_entry: ?*SceneEntry,
    ) Allocator.Error!Outcome {
        const start = Io.Clock.awake.now(s.io);
        var failure: schema.Failure = undefined;
        const resolved = (try schema.resolve(arena, tool.params, raw_args, &failure)) orelse {
            return .{ .tool_error = .{ .code = .invalid_argument, .message = failure.message, .path = failure.path, .hint = failure.hint, .valid_values = failure.valid_values } };
        };
        const args: schema.Args = .{ .map = resolved };

        var entry: ?*SceneEntry = batch_entry;
        if (entry == null and tool.kind != .global and !std.mem.eql(u8, tool.name, "scene.create")) {
            const id = args.str("scene_id") orelse return .{ .tool_error = .{ .code = .invalid_argument, .message = "missing scene_id", .path = "/scene_id" } };
            entry = s.scenes.get(id) orelse {
                return .{ .tool_error = .{
                    .code = .not_found,
                    .message = try std.fmt.allocPrint(arena, "no open scene '{s}'", .{id}),
                    .path = "/scene_id",
                    .hint = "call scene.create first and use the scene_id it returns",
                    .valid_values = s.scenes.keys(),
                } };
            };
        }

        if (entry) |e| if (args.int("if_rev")) |want| {
            if (batch_entry == null and @as(u64, @intCast(@max(0, want))) != e.doc.rev) {
                return .{ .tool_error = .{
                    .code = .rev_mismatch,
                    .message = try std.fmt.allocPrint(arena, "scene is at rev {d}, not {d}", .{ e.doc.rev, want }),
                    .path = "/if_rev",
                    .hint = "re-read the scene with scene.inspect, then retry with the current scene_rev",
                } };
            }
        };

        // The wall-time budget (SEC-3) covers the whole call, batch included:
        // parallel loops stop at the deadline and scene.apply checks it
        // between ops.
        var deadline = math.Deadline.after(s.io, s.config.budgets.max_wall_ms);
        const top_level = batch_entry == null;
        if (top_level) s.pool.deadline = &deadline;
        defer if (top_level) {
            s.pool.deadline = null;
        };

        var out_buf: std.Io.Writer.Allocating = .init(arena);
        var c: Call = .{
            .server = s,
            .arena = arena,
            .tool = tool,
            .args = args,
            .entry = entry,
            .out = .{ .writer = &out_buf.writer },
            .out_buf = &out_buf,
            .changed = changed,
            .created = created,
            .warnings = warnings,
            .in_batch = batch_entry != null,
        };
        c.out.beginObject() catch return error.OutOfMemory;

        const transact = tool.kind == .mutating and batch_entry == null;
        var tx: ?core.Transaction = if (transact) try core.Transaction.begin(&entry.?.doc) else null;
        defer if (tx) |*t| t.end();

        const handled = tool.handler(&c);
        if (top_level and deadline.expired()) {
            // Some loop stopped early: its output, and anything cached from
            // it, is incomplete. The transaction rolls back on return.
            if (c.entry) |e| e.eval_cache.clear();
            return .{ .tool_error = .{
                .code = .budget_exceeded,
                .message = try std.fmt.allocPrint(arena, "the call ran past the {d} ms wall-time budget and was stopped; nothing changed", .{s.config.budgets.max_wall_ms}),
                .hint = "ask for less work (a smaller render, fewer segments, fewer ops), or ask the operator to raise --max-wall-ms",
            } };
        }
        handled catch |e| switch (e) {
            error.ToolFailed => return .{ .tool_error = c.err orelse .{ .code = .internal, .message = "tool failed" } },
            error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
        };

        if (tool.kind == .mutating) {
            const e = entry.?;
            if (sceneBytes(&e.doc) > s.config.budgets.max_scene_bytes) {
                return .{ .tool_error = .{ .code = .budget_exceeded, .message = "scene memory budget exceeded; the change was rolled back", .hint = "use fewer or lighter objects" } };
            }
        }
        const elapsed: u64 = @intCast(@max(0, @divTrunc(start.durationTo(Io.Clock.awake.now(s.io)).nanoseconds, std.time.ns_per_ms)));
        if (tool.kind == .mutating and batch_entry == null and elapsed > s.config.budgets.max_wall_ms) {
            return .{ .tool_error = .{ .code = .budget_exceeded, .message = try std.fmt.allocPrint(arena, "call took {d} ms, over the {d} ms budget; rolled back", .{ elapsed, s.config.budgets.max_wall_ms }) } };
        }
        if (tx) |*t| try t.commit(tool.name);

        if (batch_entry != null) {
            c.out.endObject() catch return error.OutOfMemory;
            return .{ .ok = .{ .structured = out_buf.written(), .summary = c.summary } };
        }

        // c.entry, not entry: scene.create sets it and scene.close clears it.
        if (c.entry) |e| if (tool.kind == .mutating or tool.kind == .lifecycle) {
            try s.appendLog(e, tool, c.log_params orelse .{ .object = resolved });
        };

        c.out.endObject() catch return error.OutOfMemory;
        const structured = try buildStructured(arena, &c, out_buf.written());
        return .{ .ok = .{
            .structured = structured,
            .summary = c.summary,
            .image = c.image,
            .links = c.links.items,
        } };
    }

    /// Runs `ops` in the caller's transaction (scene.apply, FR-MCP-6).
    pub fn runBatch(s: *Server, c: *Call, ops: []const Value) HandlerError!void {
        const e = c.entry.?;
        var logged = std.json.Array.init(c.arena);
        try c.field("results");
        try c.out.beginArray();
        for (ops, 0..) |op, i| {
            if (s.pool.deadline) |d| if (d.passed(s.io)) return error.ToolFailed; // callInner reports it
            const name = op.object.get("tool").?.string;
            const tool = s.findTool(name) orelse {
                return c.failAt(.invalid_argument, try std.fmt.allocPrint(c.arena, "/ops/{d}/tool", .{i}), "only mutating tools may appear in scene.apply", try s.mutatingToolNames(c.arena), "op {d}: unknown tool '{s}'", .{ i, name });
            };
            if (tool.kind != .mutating or std.mem.eql(u8, tool.name, "scene.apply")) {
                return c.failAt(.invalid_argument, try std.fmt.allocPrint(c.arena, "/ops/{d}/tool", .{i}), "only mutating tools may appear in scene.apply", try s.mutatingToolNames(c.arena), "op {d}: '{s}' cannot run inside scene.apply", .{ i, name });
            }
            var sub_args: Value = op.object.get("arguments") orelse .{ .object = .empty };
            if (sub_args != .object) return c.failAt(.invalid_argument, try std.fmt.allocPrint(c.arena, "/ops/{d}/arguments", .{i}), "", &.{}, "op {d}: arguments must be an object", .{i});
            // The batch's scene applies to every op.
            var copy = try sub_args.object.clone(c.arena);
            try copy.put(c.arena, "scene_id", .{ .string = e.id });
            _ = copy.orderedRemove("if_rev");
            sub_args = .{ .object = copy };
            const res = try s.callInner(c.arena, tool, sub_args, c.changed, c.created, c.warnings, e);
            switch (res) {
                .ok => |ok| {
                    try c.out.beginWriteRaw();
                    try c.out.writer.writeAll(ok.structured);
                    c.out.endWriteRaw();
                    // Log the resolved form of each op.
                    var failure: schema.Failure = undefined;
                    var resolved = (try schema.resolve(c.arena, tool.params, sub_args, &failure)).?;
                    _ = resolved.orderedRemove("scene_id");
                    var rec: std.json.ObjectMap = .empty;
                    try rec.put(c.arena, "tool", .{ .string = tool.name });
                    try rec.put(c.arena, "arguments", .{ .object = resolved });
                    try logged.append(.{ .object = rec });
                },
                .tool_error => |te| {
                    c.err = te;
                    c.err.?.message = try std.fmt.allocPrint(c.arena, "op {d} ({s}) failed, nothing was applied: {s}", .{ i, name, te.message });
                    c.err.?.path = try std.fmt.allocPrint(c.arena, "/ops/{d}/arguments{s}", .{ i, te.path });
                    return error.ToolFailed;
                },
                .unknown_tool => unreachable,
            }
        }
        try c.out.endArray();
        var params: std.json.ObjectMap = .empty;
        try params.put(c.arena, "ops", .{ .array = logged });
        c.log_params = .{ .object = params };
    }

    fn mutatingToolNames(s: *Server, arena: Allocator) Allocator.Error![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        for (s.tools) |t| if (t.kind == .mutating and !std.mem.eql(u8, t.name, "scene.apply")) try list.append(arena, t.name);
        return list.items;
    }

    fn appendLog(s: *Server, e: *SceneEntry, tool: *const Tool, params: Value) Allocator.Error!void {
        var out: std.Io.Writer.Allocating = .init(s.gpa);
        errdefer out.deinit();
        var w: Stringify = .{ .writer = &out.writer };
        writeLogRecord(&w, tool.name, params, e.seed, e.doc.rev) catch return error.OutOfMemory;
        const rec = try out.toOwnedSlice();
        errdefer s.gpa.free(rec);
        try e.log.append(s.gpa, rec);
    }

    fn buildStructured(arena: Allocator, c: *Call, extra: []const u8) Allocator.Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        var w: Stringify = .{ .writer = &out.writer };
        build(&w, c, extra) catch return error.OutOfMemory;
        return out.written();
    }

    fn build(w: *Stringify, c: *Call, extra: []const u8) Stringify.Error!void {
        try w.beginObject();
        if (c.entry) |e| {
            try w.objectField("scene_id");
            try w.write(e.id);
            try w.objectField("scene_rev");
            try w.write(e.doc.rev);
        }
        // Splice the handler's fields: `extra` is "{...}".
        const inner = std.mem.trim(u8, extra[1 .. extra.len - 1], " ");
        if (inner.len > 0) {
            try w.writer.writeAll(if (c.entry != null) "," else "");
            try w.writer.writeAll(inner);
            w.next_punctuation = .comma;
        }
        if (c.tool.kind == .mutating or c.tool.kind == .lifecycle) {
            try w.objectField("changed");
            try writeRefs(w, c.changed.items);
            try w.objectField("created");
            try writeRefs(w, c.created.items);
        }
        try w.objectField("warnings");
        try w.write(c.warnings.items);
        try w.endObject();
    }
};

pub fn writeRefs(w: *Stringify, refs: []const Ref) Stringify.Error!void {
    try w.beginArray();
    for (refs) |r| {
        try w.beginObject();
        try w.objectField("type");
        try w.write(@tagName(r.handle.type));
        try w.objectField("name");
        try w.write(r.name);
        try w.objectField("id");
        try w.print("\"{f}\"", .{r.handle});
        try w.endObject();
    }
    try w.endArray();
}

pub fn writeLogRecord(w: *Stringify, tool: []const u8, params: Value, seed: u64, rev: u64) Stringify.Error!void {
    try w.beginObject();
    try w.objectField("tool");
    try w.write(tool);
    try w.objectField("params");
    // Session-specific keys stay out of the log so it replays anywhere.
    try w.beginObject();
    if (params == .object) {
        var it = params.object.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.key_ptr.*, "scene_id") or std.mem.eql(u8, kv.key_ptr.*, "if_rev")) continue;
            try w.objectField(kv.key_ptr.*);
            try writeValue(w, kv.value_ptr.*);
        }
    }
    try w.endObject();
    try w.objectField("seed");
    try w.write(seed);
    try w.objectField("scene_rev");
    try w.write(rev);
    try w.endObject();
}

/// Writes a JSON value; floats use their shortest round-trip form so log
/// records are byte-stable.
pub fn writeValue(w: *Stringify, v: Value) Stringify.Error!void {
    switch (v) {
        .float => |f| {
            if (!std.math.isFinite(f)) return w.write(null);
            try w.beginWriteRaw();
            try w.writer.print("{d}", .{f});
            w.endWriteRaw();
        },
        .array => |a| {
            try w.beginArray();
            for (a.items) |x| try writeValue(w, x);
            try w.endArray();
        },
        .object => |o| {
            try w.beginObject();
            var it = o.iterator();
            while (it.next()) |kv| {
                try w.objectField(kv.key_ptr.*);
                try writeValue(w, kv.value_ptr.*);
            }
            try w.endObject();
        },
        else => try w.write(v),
    }
}

/// Bytes held by mesh buffers in the live database.
/// The scene as canonical scene.json, mesh arrays as digests (FR-DM-8).
pub fn canonicalJson(arena: Allocator, e: *SceneEntry) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var w: Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_1 } };
    core.canonical.write(arena, &e.doc, &w, .{}) catch return error.OutOfMemory;
    return out.written();
}

/// Bytes in the scene's array buffers (meshes, collection lists); a buffer
/// shared by two datablocks counts twice. Undo history is not included.
pub fn sceneBytes(doc: *Document) u64 {
    var total: u64 = 0;
    const Ctx = struct {
        fn add(t: *u64, _: usize, size: usize) void {
            t.* += size;
        }
    };
    doc.db.eachBuffer(&total, Ctx.add);
    return total;
}
