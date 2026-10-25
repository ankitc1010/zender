//! Command-core integration tests: tool calls end to end, without a
//! transport.

const std = @import("std");
const math = @import("math");
const server_mod = @import("server.zig");
const catalog = @import("catalog.zig");
const paths = @import("paths.zig");
const replay = @import("replay.zig");
const telemetry = @import("telemetry.zig");

const testing = std.testing;
const Value = std.json.Value;
const Server = server_mod.Server;

const Fixture = struct {
    tmp: testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    server: Server,

    fn init(f: *Fixture) !void {
        f.tmp = testing.tmpDir(.{});
        f.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        const arena = f.arena_state.allocator();
        const root = try f.tmp.dir.realPathFileAlloc(testing.io, ".", arena);
        const roots_list = try arena.alloc([]const u8, 1);
        roots_list[0] = root;
        f.server = Server.init(testing.allocator, testing.io, .{ .io = testing.io, .threads = 4 }, .{ .roots = .{ .list = roots_list } }, catalog.tools);
    }

    fn deinit(f: *Fixture) void {
        f.server.deinit();
        f.arena_state.deinit();
        f.tmp.cleanup();
    }

    fn call(f: *Fixture, name: []const u8, json: []const u8) !server_mod.Outcome {
        const arena = f.arena_state.allocator();
        const args = try std.json.parseFromSliceLeaky(Value, arena, json, .{});
        return f.server.call(arena, name, args);
    }

    fn ok(f: *Fixture, name: []const u8, json: []const u8) !Value {
        const out = try f.call(name, json);
        switch (out) {
            .ok => |s| return std.json.parseFromSliceLeaky(Value, f.arena_state.allocator(), s.structured, .{}),
            .tool_error => |e| {
                std.debug.print("{s} failed: {s} at {s}\n", .{ name, e.message, e.path });
                return error.TestUnexpectedResult;
            },
            .unknown_tool => return error.TestUnexpectedResult,
        }
    }

    fn createScene(f: *Fixture) ![]const u8 {
        const v = try f.ok("scene.create", "{}");
        return v.object.get("scene_id").?.string;
    }

    fn fmt(f: *Fixture, comptime s: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(f.arena_state.allocator(), s, args);
    }
};

test "agent loop: build a scene, preview it, export glTF" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.createScene();
    _ = try f.ok("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"cube\",\"name\":\"Table Top\",\"size\":1,\"location\":[0,0,0.75],\"scale\":[1.2,0.8,0.04]}}", .{id}));
    _ = try f.ok("material.create", try f.fmt("{{\"scene_id\":\"{s}\",\"name\":\"Oak\",\"properties\":{{\"base_color\":[0.3,0.15,0.06],\"roughness\":0.6}}}}", .{id}));
    _ = try f.ok("material.assign", try f.fmt("{{\"scene_id\":\"{s}\",\"objects\":[\"Table Top\"],\"material\":\"Oak\"}}", .{id}));
    _ = try f.ok("camera.add", try f.fmt("{{\"scene_id\":\"{s}\",\"location\":[3,-3,2],\"look_at\":[0,0,0.5]}}", .{id}));
    _ = try f.ok("light.add", try f.fmt("{{\"scene_id\":\"{s}\",\"type\":\"sun\",\"rotation\":[40,0,30]}}", .{id}));
    const framed = try f.ok("camera.frame_objects", try f.fmt("{{\"scene_id\":\"{s}\"}}", .{id}));
    try testing.expect(framed.object.get("distance").? == .float or framed.object.get("distance").? == .integer);

    const prev = try f.call("render.preview", try f.fmt("{{\"scene_id\":\"{s}\",\"width\":96,\"height\":64}}", .{id}));
    try testing.expect(prev == .ok);
    try testing.expect(prev.ok.image != null);
    try testing.expectEqualStrings("\x89PNG", prev.ok.image.?.bytes[0..4]);
    const pv = try std.json.parseFromSliceLeaky(Value, f.arena_state.allocator(), prev.ok.structured, .{});
    try testing.expectEqualStrings("Table Top", pv.object.get("visible").?.array.items[0].object.get("object").?.string);

    const ex = try f.ok("io.export", try f.fmt("{{\"scene_id\":\"{s}\",\"path\":\"table.glb\"}}", .{id}));
    try testing.expectEqual(@as(i64, 3), ex.object.get("nodes").?.integer);
    const bytes = try f.tmp.dir.readFileAlloc(testing.io, "table.glb", f.arena_state.allocator(), .limited(1 << 20));
    try testing.expectEqualStrings("glTF", bytes[0..4]);
    // A second export to the same path needs overwrite.
    const again = try f.call("io.export", try f.fmt("{{\"scene_id\":\"{s}\",\"path\":\"table.glb\"}}", .{id}));
    try testing.expectEqual(server_mod.ErrorCode.io_error, again.tool_error.code);
    const outside = try f.call("io.export", try f.fmt("{{\"scene_id\":\"{s}\",\"path\":\"../escape.glb\"}}", .{id}));
    try testing.expectEqual(server_mod.ErrorCode.permission_denied, outside.tool_error.code);
}

test "scene.apply is all-or-nothing and names the failing op" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.createScene();
    const bad = try f.call("scene.apply", try f.fmt(
        \\{{"scene_id":"{s}","ops":[{{"tool":"object.add_primitive","arguments":{{"kind":"cube"}}}},{{"tool":"object.transform","arguments":{{"object":"Nope","location":[0,0,1]}}}}]}}
    , .{id}));
    try testing.expectEqual(server_mod.ErrorCode.not_found, bad.tool_error.code);
    try testing.expectEqualStrings("/ops/1/arguments/object", bad.tool_error.path);
    const after = try f.ok("scene.inspect", try f.fmt("{{\"scene_id\":\"{s}\"}}", .{id}));
    try testing.expectEqual(@as(usize, 0), after.object.get("objects").?.array.items.len);
    try testing.expectEqual(@as(i64, 0), after.object.get("scene_rev").?.integer);

    const good = try f.ok("scene.apply", try f.fmt(
        \\{{"scene_id":"{s}","ops":[{{"tool":"object.add_primitive","arguments":{{"kind":"cube","name":"A"}}}},{{"tool":"object.transform","arguments":{{"object":"A","location":[0,0,1]}}}}]}}
    , .{id}));
    try testing.expectEqual(@as(i64, 1), good.object.get("scene_rev").?.integer);
    try testing.expectEqual(@as(usize, 2), good.object.get("results").?.array.items.len);
}

test "if_rev, undo, redo and validation errors" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.createScene();
    _ = try f.ok("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"uv_sphere\",\"if_rev\":0}}", .{id}));
    const stale = try f.call("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"cube\",\"if_rev\":0}}", .{id}));
    try testing.expectEqual(server_mod.ErrorCode.rev_mismatch, stale.tool_error.code);
    const bad_kind = try f.call("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"teapot\"}}", .{id}));
    try testing.expectEqualStrings("/kind", bad_kind.tool_error.path);
    try testing.expect(bad_kind.tool_error.valid_values.len == 8);
    f.server.config.budgets.max_triangles = 10_000;
    const huge = try f.call("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"ico_sphere\",\"subdivisions\":6}}", .{id}));
    f.server.config.budgets.max_triangles = 20_000_000;
    try testing.expectEqual(server_mod.ErrorCode.budget_exceeded, huge.tool_error.code);

    const u = try f.ok("scene.undo", try f.fmt("{{\"scene_id\":\"{s}\"}}", .{id}));
    try testing.expectEqualStrings("object.add_primitive", u.object.get("undone").?.array.items[0].string);
    const empty = try f.ok("scene.inspect", try f.fmt("{{\"scene_id\":\"{s}\"}}", .{id}));
    try testing.expectEqual(@as(usize, 0), empty.object.get("objects").?.array.items.len);
    _ = try f.ok("scene.redo", try f.fmt("{{\"scene_id\":\"{s}\"}}", .{id}));
    const back = try f.ok("scene.inspect", try f.fmt("{{\"scene_id\":\"{s}\"}}", .{id}));
    try testing.expectEqualStrings("Sphere", back.object.get("objects").?.array.items[0].object.get("name").?.string);

    const close = try f.call("scene.close", try f.fmt("{{\"scene_id\":\"{s}\"}}", .{id}));
    try testing.expectEqual(server_mod.ErrorCode.confirmation_required, close.tool_error.code);
    _ = try f.ok("scene.close", try f.fmt("{{\"scene_id\":\"{s}\",\"confirm\":true}}", .{id}));
}

test "replaying the command log reproduces a byte-identical export" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const v = try f.ok("scene.create", "{\"template\":\"default\",\"seed\":7}");
    const id = v.object.get("scene_id").?.string;
    _ = try f.ok("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"torus\",\"location\":[0,0,2],\"rotation\":[90,0,0]}}", .{id}));
    _ = try f.ok("object.duplicate", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Torus\",\"offset\":[3,0,0]}}", .{id}));
    _ = try f.ok("object.set_parent", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Torus.001\",\"parent\":\"Torus\"}}", .{id}));
    _ = try f.ok("io.export", try f.fmt("{{\"scene_id\":\"{s}\",\"path\":\"a.gltf\"}}", .{id}));

    const entry = f.server.scenes.get(id).?;
    var log: std.ArrayList(u8) = .empty;
    const arena = f.arena_state.allocator();
    for (entry.log.items) |rec| {
        try log.appendSlice(arena, rec);
        try log.append(arena, '\n');
    }
    try testing.expectEqual(@as(usize, 4), entry.log.items.len);
    const r = try replay.run(&f.server, arena, log.items);
    try testing.expectEqual(@as(usize, 0), r.failed_line);
    _ = try f.ok("io.export", try f.fmt("{{\"scene_id\":\"{s}\",\"path\":\"b.gltf\"}}", .{r.scene_id}));
    const a = try f.tmp.dir.readFileAlloc(testing.io, "a.gltf", arena, .limited(1 << 22));
    const b = try f.tmp.dir.readFileAlloc(testing.io, "b.gltf", arena, .limited(1 << 22));
    try testing.expectEqualSlices(u8, a, b);
}

test "renders and exports are identical on 1, 4 and 16 threads" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const v = try f.ok("scene.create", "{\"template\":\"default\"}");
    const id = v.object.get("scene_id").?.string;
    _ = try f.ok("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"uv_sphere\",\"segments\":96,\"rings\":64,\"smooth\":true,\"location\":[0,0,2.2]}}", .{id}));
    _ = try f.ok("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"plane\",\"size\":40}}", .{id}));
    var png_hash: ?u64 = null;
    var gltf_hash: ?u64 = null;
    for ([_]usize{ 1, 4, 16 }) |threads| {
        f.server.pool.threads = threads;
        const out = try f.call("render.preview", try f.fmt("{{\"scene_id\":\"{s}\",\"width\":200,\"height\":120,\"wireframe\":true}}", .{id}));
        const h = std.hash.Wyhash.hash(0, out.ok.image.?.bytes);
        if (png_hash) |p| try testing.expectEqual(p, h) else png_hash = h;
        const path = try f.fmt("t{d}.gltf", .{threads});
        _ = try f.ok("io.export", try f.fmt("{{\"scene_id\":\"{s}\",\"path\":\"{s}\"}}", .{ id, path }));
        const bytes = try f.tmp.dir.readFileAlloc(testing.io, path, f.arena_state.allocator(), .limited(1 << 24));
        const g = std.hash.Wyhash.hash(0, bytes);
        if (gltf_hash) |p| try testing.expectEqual(p, g) else gltf_hash = g;
    }
}

test "collections group objects, hide them and undo cleanly" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const v = try f.ok("scene.create", "{\"template\":\"default\"}");
    const id = v.object.get("scene_id").?.string;
    _ = try f.ok("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"plane\",\"name\":\"Floor\",\"size\":10}}", .{id}));
    const made = try f.ok("collection.create", try f.fmt("{{\"scene_id\":\"{s}\",\"name\":\"Props\",\"objects\":[\"Cube\"]}}", .{id}));
    const props = made.object.get("collection").?.object;
    try testing.expectEqualStrings("Scene Collection", props.get("parent").?.string);
    try testing.expectEqualStrings("Cube", props.get("objects").?.array.items[0].string);
    _ = try f.ok("collection.create", try f.fmt("{{\"scene_id\":\"{s}\",\"name\":\"Inner\",\"parent\":\"Props\"}}", .{id}));

    const cycle = try f.call("collection.update", try f.fmt("{{\"scene_id\":\"{s}\",\"collection\":\"Props\",\"parent\":\"Inner\"}}", .{id}));
    try testing.expectEqual(server_mod.ErrorCode.invalid_operation, cycle.tool_error.code);
    try testing.expectEqualStrings("/parent", cycle.tool_error.path);
    const last = try f.call("collection.update", try f.fmt("{{\"scene_id\":\"{s}\",\"collection\":\"Props\",\"unlink\":[\"Cube\"]}}", .{id}));
    try testing.expectEqualStrings("/unlink/0", last.tool_error.path);
    const root = try f.call("collection.update", try f.fmt("{{\"scene_id\":\"{s}\",\"collection\":\"Scene Collection\",\"rename\":\"Root\"}}", .{id}));
    try testing.expectEqual(server_mod.ErrorCode.invalid_operation, root.tool_error.code);

    // Hiding Props drops the cube from previews and exports.
    _ = try f.ok("collection.update", try f.fmt("{{\"scene_id\":\"{s}\",\"collection\":\"Props\",\"properties\":{{\"hide_render\":true}}}}", .{id}));
    const prev = try f.ok("render.preview", try f.fmt("{{\"scene_id\":\"{s}\",\"width\":64,\"height\":48}}", .{id}));
    for (prev.object.get("visible").?.array.items) |x| try testing.expect(!std.mem.eql(u8, "Cube", x.object.get("object").?.string));
    const hidden = try f.ok("io.export", try f.fmt("{{\"scene_id\":\"{s}\",\"path\":\"hidden.glb\"}}", .{id}));
    try testing.expectEqual(@as(i64, 3), hidden.object.get("nodes").?.integer);
    // A link into a visible collection shows it again.
    _ = try f.ok("collection.update", try f.fmt("{{\"scene_id\":\"{s}\",\"collection\":\"Scene Collection\",\"link\":[\"Cube\"]}}", .{id}));
    const shown = try f.ok("io.export", try f.fmt("{{\"scene_id\":\"{s}\",\"path\":\"shown.glb\"}}", .{id}));
    try testing.expectEqual(@as(i64, 4), shown.object.get("nodes").?.integer);

    const tree = (try f.ok("scene.inspect", try f.fmt("{{\"scene_id\":\"{s}\"}}", .{id}))).object.get("collections").?.array.items;
    try testing.expectEqual(@as(usize, 3), tree.len);
    try testing.expectEqualStrings("Inner", tree[2].object.get("name").?.string);
    try testing.expect(tree[1].object.get("hide_render").?.bool);

    // Deleting Props hands Inner and the cube to the master; undo restores it.
    _ = try f.ok("collection.delete", try f.fmt("{{\"scene_id\":\"{s}\",\"collections\":[\"Props\"]}}", .{id}));
    const flat = (try f.ok("scene.inspect", try f.fmt("{{\"scene_id\":\"{s}\"}}", .{id}))).object.get("collections").?.array.items;
    try testing.expectEqual(@as(usize, 2), flat.len);
    try testing.expectEqualStrings("Scene Collection", flat[1].object.get("parent").?.string);
    _ = try f.ok("scene.undo", try f.fmt("{{\"scene_id\":\"{s}\"}}", .{id}));
    const back = (try f.ok("scene.inspect", try f.fmt("{{\"scene_id\":\"{s}\"}}", .{id}))).object.get("collections").?.array.items;
    try testing.expectEqual(@as(usize, 3), back.len);
}

test "the wall-time budget stops a call part-way and changes nothing" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = (try f.ok("scene.create", "{\"template\":\"default\"}")).object.get("scene_id").?.string;
    const b = (try f.ok("scene.create", "{\"template\":\"default\"}")).object.get("scene_id").?.string;
    f.server.config.budgets.max_wall_ms = 0;
    const stopped = try f.call("render.preview", try f.fmt("{{\"scene_id\":\"{s}\",\"width\":64,\"height\":48}}", .{a}));
    try testing.expectEqual(server_mod.ErrorCode.budget_exceeded, stopped.tool_error.code);
    const batch = try f.call("scene.apply", try f.fmt(
        \\{{"scene_id":"{s}","ops":[{{"tool":"object.add_primitive","arguments":{{"kind":"cube"}}}}]}}
    , .{a}));
    try testing.expectEqual(server_mod.ErrorCode.budget_exceeded, batch.tool_error.code);
    f.server.config.budgets.max_wall_ms = 60_000;
    const after = try f.ok("scene.inspect", try f.fmt("{{\"scene_id\":\"{s}\"}}", .{a}));
    try testing.expectEqual(@as(i64, 0), after.object.get("scene_rev").?.integer);
    // Nothing half-computed was cached: the stopped scene renders exactly
    // like an untouched one.
    const pa = try f.call("render.preview", try f.fmt("{{\"scene_id\":\"{s}\",\"width\":64,\"height\":48}}", .{a}));
    const pb = try f.call("render.preview", try f.fmt("{{\"scene_id\":\"{s}\",\"width\":64,\"height\":48}}", .{b}));
    try testing.expectEqualSlices(u8, pb.ok.image.?.bytes, pa.ok.image.?.bytes);
}

test "tool calls become spans that continue the caller's trace" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const arena = f.arena_state.allocator();
    const root = try f.tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const path = try std.fs.path.join(arena, &.{ root, "spans.jsonl" });
    var tel: telemetry.Telemetry = .{ .io = testing.io, .version = "test" };
    try tel.openTraceFile(path);
    var tel_open = true;
    defer if (tel_open) tel.deinit();
    f.server.config.telemetry = &tel;

    const parent = telemetry.TraceContext.parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", "").?;
    const created = try f.server.callTraced(arena, "scene.create", try std.json.parseFromSliceLeaky(Value, arena, "{}", .{}), parent);
    const id = (try std.json.parseFromSliceLeaky(Value, arena, created.ok.structured, .{})).object.get("scene_id").?.string;
    const failed = try f.server.callTraced(arena, "object.delete", try std.json.parseFromSliceLeaky(Value, arena, try f.fmt("{{\"scene_id\":\"{s}\",\"objects\":[\"Nope\"]}}", .{id}), .{}), null);
    try testing.expect(failed == .tool_error);

    // Close the trace file before reading it back, and show what it held if
    // a check below fails.
    f.server.config.telemetry = null;
    tel.deinit();
    tel_open = false;
    const text = f.tmp.dir.readFileAlloc(testing.io, "spans.jsonl", arena, .limited(1 << 20)) catch |e| {
        std.debug.print("cannot read back {s}: {t}\n", .{ path, e });
        return e;
    };
    errdefer std.debug.print("{s} ({d} bytes):\n{s}\n", .{ path, text.len, text });
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    var spans: [2]std.json.ObjectMap = undefined;
    for (&spans) |*sp| {
        const v = try std.json.parseFromSliceLeaky(Value, arena, lines.next().?, .{});
        sp.* = v.object.get("resourceSpans").?.array.items[0].object.get("scopeSpans").?.array.items[0].object.get("spans").?.array.items[0].object;
    }
    try testing.expect(lines.next() == null);
    try testing.expectEqualStrings("4bf92f3577b34da6a3ce929d0e0e4736", spans[0].get("traceId").?.string);
    try testing.expectEqualStrings("00f067aa0ba902b7", spans[0].get("parentSpanId").?.string);
    try testing.expectEqual(@as(i64, 1), spans[0].get("status").?.object.get("code").?.integer);
    // Without a traceparent the call starts its own trace.
    try testing.expect(!std.mem.eql(u8, "4bf92f3577b34da6a3ce929d0e0e4736", spans[1].get("traceId").?.string));
    try testing.expect(spans[1].get("parentSpanId") == null);
    try testing.expectEqual(@as(i64, 2), spans[1].get("status").?.object.get("code").?.integer);
    var saw_scene = false;
    for (spans[1].get("attributes").?.array.items) |at| {
        if (std.mem.eql(u8, at.object.get("key").?.string, "zender.scene_id")) saw_scene = std.mem.eql(u8, id, at.object.get("value").?.object.get("stringValue").?.string);
    }
    try testing.expect(saw_scene);
}
