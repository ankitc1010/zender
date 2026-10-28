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
    tel.openTraceFile(path) catch |e| {
        std.debug.print("cannot open {s}: {t}\n", .{ path, e });
        return e;
    };
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

test "the wall-time budget stops a mesh operator part-way" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.createScene();
    _ = try f.ok("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"grid\",\"name\":\"G\",\"grid_subdivisions\":64}}", .{id}));
    f.server.config.budgets.max_wall_ms = 0;
    const stopped = try f.call("mesh.extrude", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"G\",\"selector\":{{}},\"distance\":0.1,\"mode\":\"individual\"}}", .{id}));
    try testing.expectEqual(server_mod.ErrorCode.budget_exceeded, stopped.tool_error.code);
    f.server.config.budgets.max_wall_ms = 60_000;
    const after = try f.ok("mesh.select_preview", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"G\"}}", .{id}));
    try testing.expectEqual(@as(i64, 64 * 64), after.object.get("count").?.integer);
    try testing.expectEqual(@as(i64, 1), (try f.ok("scene.inspect", try f.fmt("{{\"scene_id\":\"{s}\"}}", .{id}))).object.get("scene_rev").?.integer);
}

fn countsOf(v: Value) [4]i64 {
    const c = v.object.get("counts").?.object;
    return .{ c.get("verts").?.integer, c.get("edges").?.integer, c.get("faces").?.integer, c.get("triangles").?.integer };
}

test "mesh tools: select, extrude, inset, triangulate, merge, transform" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.createScene();
    _ = try f.ok("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"cube\",\"name\":\"Box\",\"location\":[0,0,1],\"scale\":[2,1,0.5]}}", .{id}));

    // World space: the top face's centre is at z = 1 + 0.5.
    const top = try f.ok("mesh.select_preview", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"selector\":{{\"normal\":[0,0,1],\"within\":10}}}}", .{id}));
    try testing.expectEqual(@as(i64, 1), top.object.get("count").?.integer);
    try testing.expectEqual(@as(f64, 1.5), schemaNumber(top.object.get("center").?.array.items[2]));
    try testing.expectEqual(@as(f64, 1), schemaNumber(top.object.get("normal").?.array.items[2]));

    const ex = try f.ok("mesh.extrude", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"selector\":{{\"normal\":[0,0,1]}},\"distance\":0.5}}", .{id}));
    try testing.expectEqual([4]i64{ 12, 20, 10, 20 }, countsOf(ex));
    const cap = ex.object.get("result").?;
    try testing.expectEqualStrings("face", cap.object.get("domain").?.string);
    const raised = try f.ok("mesh.select_preview", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"selector\":{{\"domain\":\"vert\",\"where\":\"z > 1.99\"}}}}", .{id}));
    try testing.expectEqual(@as(i64, 4), raised.object.get("count").?.integer);

    // The result selector feeds the next call as is.
    var cap_json: std.Io.Writer.Allocating = .init(f.arena_state.allocator());
    try std.json.Stringify.value(cap, .{}, &cap_json.writer);
    const in = try f.ok("mesh.inset", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"selector\":{s},\"thickness\":0.1,\"depth\":-0.2}}", .{ id, cap_json.written() }));
    try testing.expectEqual(@as(i64, 14), countsOf(in)[2]);
    try testing.expectEqual(@as(usize, 0), in.object.get("warnings").?.array.items.len);
    const sunk = try f.ok("mesh.select_preview", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"selector\":{{\"domain\":\"vert\",\"where\":[\"z > 1.79\",\"z < 1.81\"]}}}}", .{id}));
    try testing.expectEqual(@as(i64, 4), sunk.object.get("count").?.integer);

    const moved = try f.ok("mesh.transform_elements", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"selector\":{{\"domain\":\"vert\",\"where\":\"z > 1.99\"}},\"scale\":[0.5,0.5,1],\"translate\":[0,0,0.25]}}", .{id}));
    try testing.expectEqual(@as(usize, 1), moved.object.get("result").?.object.get("index").?.array.items.len);
    const lifted = try f.ok("mesh.select_preview", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"selector\":{{\"domain\":\"vert\",\"where\":\"z > 2.2\"}}}}", .{id}));
    try testing.expectEqual(@as(i64, 4), lifted.object.get("count").?.integer);
    try testing.expectEqual(@as(f64, 1), schemaNumber(lifted.object.get("bounds").?.object.get("max").?.array.items[0]));

    const tri = try f.ok("mesh.triangulate", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\"}}", .{id}));
    const tc = countsOf(tri);
    try testing.expectEqual(tc[2], tc[3]);
    try testing.expectEqual(@as(i64, 28), tc[2]);

    const none_merged = try f.ok("mesh.merge", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"selector\":{{}},\"mode\":\"distance\"}}", .{id}));
    try testing.expectEqual(@as(i64, 0), none_merged.object.get("merged").?.integer);
    const apex = try f.ok("mesh.merge", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"selector\":{{\"domain\":\"vert\",\"where\":\"z > 2.2\"}}}}", .{id}));
    try testing.expectEqual(@as(i64, 3), apex.object.get("merged").?.integer);
    try testing.expect(apex.object.get("warnings").?.array.items.len > 0);

    // Errors name the argument and suggest a fix.
    const unknown = try f.call("mesh.extrude", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"selector\":{{\"where\":\"weight > 0\"}},\"distance\":1}}", .{id}));
    try testing.expectEqual(server_mod.ErrorCode.not_found, unknown.tool_error.code);
    try testing.expect(unknown.tool_error.valid_values.len > 0);
    const stale = try f.call("mesh.extrude", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"selector\":{{\"index\":[999]}},\"distance\":1}}", .{id}));
    try testing.expectEqual(server_mod.ErrorCode.invalid_argument, stale.tool_error.code);
    const empty = try f.call("mesh.inset", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"selector\":{{\"where\":\"z > 100\"}}}}", .{id}));
    try testing.expectEqualStrings("/selector", empty.tool_error.path);
    const bad = try f.call("mesh.extrude", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"selector\":{{\"box\":{{\"min\":[0,0]}}}},\"distance\":1}}", .{id}));
    try testing.expectEqualStrings("/selector/box/min", bad.tool_error.path);
    const area_on_edges = try f.call("mesh.extrude", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"selector\":{{\"domain\":\"edge\",\"where\":\"area > 1\"}},\"distance\":1}}", .{id}));
    try testing.expectEqualStrings("/selector/where", area_on_edges.tool_error.path);
    const corner_normals = try f.call("mesh.merge", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"selector\":{{\"normal\":[0,0,-1],\"within\":5}}}}", .{id}));
    try testing.expect(std.mem.indexOf(u8, corner_normals.tool_error.hint, "domain face") != null);
    const no_dist = try f.call("mesh.extrude", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"selector\":{{}}}}", .{id}));
    try testing.expectEqualStrings("/distance", no_dist.tool_error.path);
    _ = try f.ok("camera.add", try f.fmt("{{\"scene_id\":\"{s}\"}}", .{id}));
    const cam = try f.call("mesh.triangulate", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Camera\"}}", .{id}));
    try testing.expectEqualStrings("/object", cam.tool_error.path);

    // Undo walks back through camera.add, both merges, triangulate and
    // the transform to the inset mesh.
    for (0..5) |_| _ = try f.ok("scene.undo", try f.fmt("{{\"scene_id\":\"{s}\"}}", .{id}));
    const back = try f.ok("mesh.select_preview", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\"}}", .{id}));
    try testing.expectEqual([4]i64{ 16, 28, 14, 28 }, countsOf(back));
}

test "mesh.loop_cut cuts rings and explains empty ones" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.createScene();
    _ = try f.ok("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"cube\",\"name\":\"Box\"}}", .{id}));
    // All four vertical edges lie on one ring: one loop around the middle.
    const cut = try f.ok("mesh.loop_cut", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"selector\":{{\"domain\":\"edge\",\"direction\":[0,0,1],\"within\":5}}}}", .{id}));
    try testing.expectEqual([4]i64{ 12, 20, 10, 20 }, countsOf(cut));
    var loop_json: std.Io.Writer.Allocating = .init(f.arena_state.allocator());
    try std.json.Stringify.value(cut.object.get("result").?, .{}, &loop_json.writer);
    const loop = try f.ok("mesh.select_preview", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"selector\":{s}}}", .{ id, loop_json.written() }));
    try testing.expectEqual(@as(i64, 4), loop.object.get("count").?.integer);
    try testing.expectEqual(@as(f64, 0), schemaNumber(loop.object.get("bounds").?.object.get("max").?.array.items[2]));

    _ = try f.ok("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"cone\",\"name\":\"Cone\"}}", .{id}));
    const no_quads = try f.call("mesh.loop_cut", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Cone\",\"selector\":{{}}}}", .{id}));
    try testing.expectEqualStrings("/selector", no_quads.tool_error.path);
    const faces_dir = try f.call("mesh.loop_cut", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"selector\":{{\"domain\":\"face\",\"direction\":[0,0,1]}}}}", .{id}));
    try testing.expectEqualStrings("/selector/direction", faces_dir.tool_error.path);
}

test "OBJ, STL and PLY round trips through io.export and io.import" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = try f.createScene();
    _ = try f.ok("material.create", try f.fmt("{{\"scene_id\":\"{s}\",\"name\":\"Red\",\"properties\":{{\"base_color\":[1,0,0,1],\"roughness\":0.25}}}}", .{a}));
    _ = try f.ok("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"cube\",\"name\":\"Box\",\"material\":\"Red\",\"location\":[0,0,1]}}", .{a}));
    _ = try f.ok("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"cylinder\",\"name\":\"Can\",\"segments\":8,\"location\":[3,0,1]}}", .{a}));
    _ = try f.ok("camera.add", try f.fmt("{{\"scene_id\":\"{s}\"}}", .{a}));

    const obj = try f.ok("io.export", try f.fmt("{{\"scene_id\":\"{s}\",\"path\":\"scene.obj\"}}", .{a}));
    try testing.expectEqual(@as(i64, 2), obj.object.get("objects").?.integer);
    try testing.expect(obj.object.get("mtl_path") != null);
    // The camera is reported, not written.
    try testing.expectEqual(@as(usize, 1), obj.object.get("dropped").?.array.items.len);
    const again = try f.call("io.export", try f.fmt("{{\"scene_id\":\"{s}\",\"path\":\"scene.obj\"}}", .{a}));
    try testing.expectEqual(server_mod.ErrorCode.io_error, again.tool_error.code);
    _ = try f.ok("io.export", try f.fmt("{{\"scene_id\":\"{s}\",\"path\":\"scene.stl\"}}", .{a}));
    _ = try f.ok("io.export", try f.fmt("{{\"scene_id\":\"{s}\",\"path\":\"scene.ply\"}}", .{a}));

    const b = try f.createScene();
    const back = try f.ok("io.import", try f.fmt("{{\"scene_id\":\"{s}\",\"path\":\"scene.obj\"}}", .{b}));
    const objs = back.object.get("objects").?.array.items;
    try testing.expectEqual(@as(usize, 2), objs.len);
    try testing.expectEqualStrings("Box", objs[0].object.get("name").?.string);
    try testing.expectEqual(@as(i64, 6), objs[0].object.get("faces").?.integer);
    try testing.expectEqual(@as(i64, 10), objs[1].object.get("faces").?.integer);
    // World positions come back exactly, through Y-up and back.
    const box = try f.ok("mesh.select_preview", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\"}}", .{b}));
    try testing.expectEqual(@as(f64, 2), schemaNumber(box.object.get("bounds").?.object.get("max").?.array.items[2]));
    try testing.expectEqualStrings("Red", objs[0].object.get("materials").?.array.items[0].string);

    const stl = try f.ok("io.import", try f.fmt("{{\"scene_id\":\"{s}\",\"path\":\"scene.stl\",\"scale\":0.5}}", .{b}));
    const st = stl.object.get("objects").?.array.items[0].object;
    // 12 + 28 triangles, welded back to 8 + 16 vertices.
    try testing.expectEqual(@as(i64, 40), st.get("faces").?.integer);
    const welded = try f.ok("mesh.select_preview", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"{s}\",\"selector\":{{\"domain\":\"vert\"}}}}", .{ b, st.get("name").?.string }));
    try testing.expectEqual(@as(i64, 24), welded.object.get("total").?.integer);
    try testing.expectEqual(@as(f64, 1), schemaNumber(welded.object.get("bounds").?.object.get("max").?.array.items[2]));
    const ply = try f.ok("io.import", try f.fmt("{{\"scene_id\":\"{s}\",\"path\":\"scene.ply\"}}", .{b}));
    try testing.expectEqual(@as(i64, 16), ply.object.get("objects").?.array.items[0].object.get("faces").?.integer);

    const missing = try f.call("io.import", try f.fmt("{{\"scene_id\":\"{s}\",\"path\":\"nope.obj\"}}", .{b}));
    try testing.expectEqual(server_mod.ErrorCode.not_found, missing.tool_error.code);
    const unknown = try f.call("io.import", try f.fmt("{{\"scene_id\":\"{s}\",\"path\":\"scene.mtl\"}}", .{b}));
    try testing.expectEqualStrings("/path", unknown.tool_error.path);
}

test "mesh.boolean cuts, hides or deletes the operand, and explains failures" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.createScene();
    _ = try f.ok("material.create", try f.fmt("{{\"scene_id\":\"{s}\",\"name\":\"Dark\"}}", .{id}));
    _ = try f.ok("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"cube\",\"name\":\"Box\"}}", .{id}));
    _ = try f.ok("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"cylinder\",\"name\":\"Drill\",\"radius\":0.5,\"depth\":4,\"material\":\"Dark\"}}", .{id}));
    _ = try f.ok("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"plane\",\"name\":\"Sheet\"}}", .{id}));
    _ = try f.ok("camera.add", try f.fmt("{{\"scene_id\":\"{s}\"}}", .{id}));

    const self = try f.call("mesh.boolean", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"operand\":\"Box\"}}", .{id}));
    try testing.expectEqualStrings("/operand", self.tool_error.path);
    const cam = try f.call("mesh.boolean", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"operand\":\"Camera\"}}", .{id}));
    try testing.expectEqualStrings("/operand", cam.tool_error.path);
    const open = try f.call("mesh.boolean", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"operand\":\"Sheet\"}}", .{id}));
    try testing.expectEqualStrings("/operand", open.tool_error.path);
    try testing.expect(std.mem.indexOf(u8, open.tool_error.hint, "closed") != null);
    const open_target = try f.call("mesh.boolean", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Sheet\",\"operand\":\"Box\"}}", .{id}));
    try testing.expectEqualStrings("/object", open_target.tool_error.path);

    // A hole through the box: the drill's material joins the box, the
    // drill is hidden, and the result is the hole's wall.
    const cut = try f.ok("mesh.boolean", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"operand\":\"Drill\"}}", .{id}));
    var res_json: std.Io.Writer.Allocating = .init(f.arena_state.allocator());
    try std.json.Stringify.value(cut.object.get("result").?, .{}, &res_json.writer);
    const wall = try f.ok("mesh.select_preview", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"selector\":{s}}}", .{ id, res_json.written() }));
    try testing.expectEqual(@as(f64, 0.5), schemaNumber(wall.object.get("bounds").?.object.get("max").?.array.items[0]));
    try testing.expectEqual(@as(f64, 1), schemaNumber(wall.object.get("bounds").?.object.get("max").?.array.items[2]));
    const insp = try f.ok("scene.inspect", try f.fmt("{{\"scene_id\":\"{s}\"}}", .{id}));
    var insp_json: std.Io.Writer.Allocating = .init(f.arena_state.allocator());
    try std.json.Stringify.value(insp, .{}, &insp_json.writer);
    try testing.expect(std.mem.indexOf(u8, insp_json.written(), "\"Dark\"") != null);

    // One undo brings the box back.
    _ = try f.ok("scene.undo", try f.fmt("{{\"scene_id\":\"{s}\"}}", .{id}));
    const back = try f.ok("mesh.select_preview", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\"}}", .{id}));
    try testing.expectEqual(@as(i64, 6), back.object.get("count").?.integer);
    const gone = try f.ok("mesh.boolean", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"operand\":\"Drill\",\"operation\":\"intersect\",\"operand_action\":\"delete\"}}", .{id}));
    _ = gone;
    const deleted = try f.call("mesh.select_preview", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Drill\"}}", .{id}));
    try testing.expectEqual(server_mod.ErrorCode.not_found, deleted.tool_error.code);
}

test "soft selection and smoothing" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.createScene();
    _ = try f.ok("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"grid\",\"name\":\"G\",\"grid_subdivisions\":4}}", .{id}));
    // The centre vertex rises 1 m; with a linear 1 m falloff its four
    // neighbours 0.5 m away rise exactly halfway.
    const up = try f.ok("mesh.transform_elements", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"G\",\"selector\":{{\"domain\":\"vert\",\"where\":[\"abs(x) < 0.01\",\"abs(y) < 0.01\"]}},\"translate\":[0,0,1],\"falloff\":1,\"falloff_curve\":\"linear\"}}", .{id}));
    try testing.expectEqual(@as(i64, 9), up.object.get("affected").?.integer);
    const half = try f.ok("mesh.select_preview", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"G\",\"selector\":{{\"domain\":\"vert\",\"where\":[\"z > 0.499\",\"z < 0.501\"]}}}}", .{id}));
    try testing.expectEqual(@as(i64, 4), half.object.get("count").?.integer);

    // Smoothing pulls the peak down; the open border stays pinned.
    const sm = try f.ok("mesh.smooth", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"G\",\"iterations\":10}}", .{id}));
    try testing.expect(sm.object.get("affected").?.integer == 25);
    const peak = try f.ok("mesh.select_preview", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"G\",\"selector\":{{\"domain\":\"vert\"}}}}", .{id}));
    const top = schemaNumber(peak.object.get("bounds").?.object.get("max").?.array.items[2]);
    try testing.expect(top < 0.9 and top > 0.1);
    const border = try f.ok("mesh.select_preview", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"G\",\"selector\":{{\"domain\":\"vert\",\"where\":[\"abs(x) > 0.99\",\"abs(z) < 0.000001\"]}}}}", .{id}));
    try testing.expectEqual(@as(i64, 10), border.object.get("count").?.integer);
}

test "modifier stack: add, validate, cycles, evaluate, export, apply, undo" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.createScene();
    _ = try f.ok("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"cube\",\"name\":\"Box\"}}", .{id}));
    _ = try f.ok("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"cube\",\"name\":\"Cutter\",\"location\":[1,1,1],\"size\":1}}", .{id}));

    // Render levels (2) set the evaluated counts; the mesh stays 6 faces.
    const sub = try f.ok("modifier.add", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"type\":\"subdivision\"}}", .{id}));
    try testing.expectEqual(@as(i64, 96), sub.object.get("evaluated").?.object.get("faces").?.integer);
    const mir = try f.ok("modifier.add", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"type\":\"mirror\",\"properties\":{{\"count\":3}}}}", .{id}));
    try testing.expect(std.mem.indexOf(u8, mir.object.get("warnings").?.array.items[0].string, "no effect") != null);

    const no_target = try f.call("modifier.add", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"type\":\"boolean\"}}", .{id}));
    try testing.expectEqualStrings("/target", no_target.tool_error.path);
    const bad_prop = try f.call("modifier.add", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"type\":\"array\",\"properties\":{{\"count\":0}}}}", .{id}));
    try testing.expectEqualStrings("/properties/count", bad_prop.tool_error.path);
    _ = try f.ok("modifier.add", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"type\":\"boolean\",\"target\":\"Cutter\"}}", .{id}));
    const cycle = try f.call("modifier.add", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Cutter\",\"type\":\"array\",\"target\":\"Box\"}}", .{id}));
    try testing.expect(std.mem.indexOf(u8, cycle.tool_error.message, "Cutter -> Box -> Cutter") != null);

    const upd = try f.ok("modifier.update", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"modifier\":\"Subdivision\",\"properties\":{{\"levels\":0,\"render_levels\":0}},\"index\":2}}", .{id}));
    try testing.expectEqualStrings("Subdivision", upd.object.get("stack").?.array.items[2].object.get("name").?.string);
    _ = try f.ok("modifier.remove", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"modifier\":\"Mirror\"}}", .{id}));
    const missing = try f.call("modifier.remove", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"modifier\":\"Mirror\"}}", .{id}));
    try testing.expectEqual(server_mod.ErrorCode.not_found, missing.tool_error.code);

    // Previews and exports see the stack: the boolean notch adds faces.
    _ = try f.ok("camera.add", try f.fmt("{{\"scene_id\":\"{s}\",\"location\":[5,-5,4],\"look_at\":[0,0,0]}}", .{id}));
    _ = try f.ok("render.preview", try f.fmt("{{\"scene_id\":\"{s}\",\"width\":64,\"height\":48}}", .{id}));
    const exp = try f.ok("io.export", try f.fmt("{{\"scene_id\":\"{s}\",\"path\":\"box.glb\"}}", .{id}));
    try testing.expect(exp.object.get("triangles").?.integer > 24);

    const desc = try f.ok("schema.describe", "{\"type\":\"modifier\"}");
    try testing.expect(desc.object.get("properties").?.array.items.len > 20);

    const applied = try f.ok("modifier.apply", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\"}}", .{id}));
    try testing.expectEqual(@as(usize, 0), applied.object.get("stack").?.array.items.len);
    try testing.expectEqual(@as(i64, 9), applied.object.get("counts").?.object.get("faces").?.integer);
    _ = try f.ok("scene.undo", try f.fmt("{{\"scene_id\":\"{s}\"}}", .{id}));
    const back = try f.ok("mesh.select_preview", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\"}}", .{id}));
    try testing.expectEqual(@as(i64, 6), back.object.get("count").?.integer);
}

test "mesh.sculpt strokes and their argument checks" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.createScene();
    _ = try f.ok("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"grid\",\"name\":\"G\",\"grid_subdivisions\":40}}", .{id}));
    const drawn = try f.ok("mesh.sculpt", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"G\",\"stroke\":[[0.4,-0.5,0],[0.4,0.5,0]],\"radius\":0.15,\"symmetry\":\"x\"}}", .{id}));
    try testing.expect(drawn.object.get("dabs").?.integer > 20);
    const ridge = try f.ok("mesh.select_preview", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"G\",\"selector\":{{\"domain\":\"vert\",\"where\":\"z > 0.05\"}}}}", .{id}));
    // Both ridges, at x = 0.4 and its mirror.
    const b = ridge.object.get("bounds").?.object;
    try testing.expect(schemaNumber(b.get("min").?.array.items[0]) < -0.3 and schemaNumber(b.get("max").?.array.items[0]) > 0.3);
    const bad = try f.call("mesh.sculpt", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"G\",\"stroke\":[[0,0,0],[1,1]]}}", .{id}));
    try testing.expectEqualStrings("/stroke/1", bad.tool_error.path);
    const far = try f.ok("mesh.sculpt", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"G\",\"brush\":\"grab\",\"stroke\":[[0,0,0],[0,0,0.4]],\"radius\":0.3}}", .{id}));
    try testing.expect(far.object.get("moved").?.integer > 0);
}

fn schemaNumber(v: Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |x| @round(x * 1e5) / 1e5,
        else => std.math.nan(f64),
    };
}

test "mesh edits replay byte-identically and do not depend on threads" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const arena = f.arena_state.allocator();
    var hash: ?u64 = null;
    for ([_]usize{ 1, 8 }) |threads| {
        f.server.pool.threads = threads;
        const id = try f.createScene();
        _ = try f.ok("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"cylinder\",\"segments\":12,\"rotation\":[0,30,0]}}", .{id}));
        _ = try f.ok("mesh.inset", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Cylinder\",\"selector\":{{\"where\":\"abs(nz) < 0.5\"}},\"thickness\":0.05,\"depth\":-0.05,\"mode\":\"individual\"}}", .{id}));
        _ = try f.ok("mesh.extrude", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Cylinder\",\"selector\":{{\"normal\":[0,0,1],\"within\":45}},\"distance\":0.3}}", .{id}));
        _ = try f.ok("mesh.triangulate", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Cylinder\",\"selector\":{{\"where\":\"area > 0.5\"}}}}", .{id}));
        _ = try f.ok("mesh.transform_elements", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Cylinder\",\"selector\":{{\"domain\":\"vert\",\"box\":{{\"min\":[-2,-2,0.5],\"max\":[2,2,3]}}}},\"rotate\":[0,0,15]}}", .{id}));
        _ = try f.ok("mesh.merge", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Cylinder\",\"selector\":{{\"domain\":\"face\",\"index\":[3]}},\"mode\":\"collapse\"}}", .{id}));
        const path = try f.fmt("m{d}.json", .{threads});
        _ = try f.ok("io.export", try f.fmt("{{\"scene_id\":\"{s}\",\"path\":\"{s}\"}}", .{ id, path }));
        const bytes = try f.tmp.dir.readFileAlloc(testing.io, path, arena, .limited(1 << 22));
        const h = std.hash.Wyhash.hash(0, bytes);
        if (hash) |want| try testing.expectEqual(want, h) else hash = h;

        const entry = f.server.scenes.get(id).?;
        var log: std.ArrayList(u8) = .empty;
        for (entry.log.items) |rec| {
            try log.appendSlice(arena, rec);
            try log.append(arena, '\n');
        }
        const r = try replay.run(&f.server, arena, log.items);
        try testing.expectEqual(@as(usize, 0), r.failed_line);
        const again = try f.fmt("r{d}.json", .{threads});
        _ = try f.ok("io.export", try f.fmt("{{\"scene_id\":\"{s}\",\"path\":\"{s}\"}}", .{ r.scene_id, again }));
        try testing.expectEqualSlices(u8, bytes, try f.tmp.dir.readFileAlloc(testing.io, again, arena, .limited(1 << 22)));
    }
}

test "coat, sheen and per-face material slots reach glTF" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.createScene();
    _ = try f.ok("material.create", try f.fmt("{{\"scene_id\":\"{s}\",\"name\":\"Blue Metal\",\"properties\":{{\"base_color\":[0.025,0.07,0.34],\"metallic\":1,\"coat_weight\":0.6,\"coat_roughness\":0.04,\"coat_tint\":[0.75,0.85,1]}}}}", .{id}));
    _ = try f.ok("material.create", try f.fmt("{{\"scene_id\":\"{s}\",\"name\":\"Velvet\",\"properties\":{{\"sheen_weight\":0.5,\"specular_ior_level\":0.25}}}}", .{id}));
    _ = try f.ok("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"cube\",\"name\":\"Box\",\"material\":\"Blue Metal\"}}", .{id}));
    _ = try f.ok("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"cube\",\"name\":\"Other\",\"location\":[3,0,0]}}", .{id}));
    // A selector picks faces of one object only.
    const two = try f.call("material.assign", try f.fmt("{{\"scene_id\":\"{s}\",\"objects\":[\"Box\",\"Other\"],\"material\":\"Velvet\",\"selector\":{{}}}}", .{id}));
    try testing.expectEqualStrings("/objects", two.tool_error.path);
    _ = try f.ok("material.assign", try f.fmt("{{\"scene_id\":\"{s}\",\"objects\":[\"Box\"],\"material\":\"Velvet\",\"slot\":1,\"selector\":{{\"normal\":[0,0,1]}}}}", .{id}));
    const top = try f.ok("mesh.select_preview", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Box\",\"selector\":{{\"where\":\"material_index == 1\"}}}}", .{id}));
    try testing.expectEqual(@as(i64, 1), top.object.get("count").?.integer);

    const out = try f.ok("io.export", try f.fmt("{{\"scene_id\":\"{s}\",\"path\":\"box.gltf\"}}", .{id}));
    // The coat tint has no glTF home and is reported.
    const dropped = out.object.get("dropped").?.array.items;
    try testing.expectEqual(@as(usize, 1), dropped.len);
    try testing.expect(std.mem.indexOf(u8, dropped[0].string, "coat tint") != null);
    const text = try f.tmp.dir.readFileAlloc(testing.io, "box.gltf", f.arena_state.allocator(), .limited(1 << 22));
    for ([_][]const u8{ "\"KHR_materials_clearcoat\"", "\"clearcoatFactor\":0.6", "\"KHR_materials_sheen\"", "\"specularFactor\":0.5" }) |needle| {
        if (std.mem.indexOf(u8, text, needle) == null) {
            std.debug.print("missing {s}\n", .{needle});
            return error.TestUnexpectedResult;
        }
    }
    // Both slots of Box are used, so it splits into two primitives.
    const gltf = try std.json.parseFromSliceLeaky(Value, f.arena_state.allocator(), text, .{});
    const meshes = gltf.object.get("meshes").?.array.items;
    var prims: usize = 0;
    for (meshes) |m| prims += m.object.get("primitives").?.array.items.len;
    try testing.expectEqual(@as(usize, 3), prims);
}

test "mesh.from_data and mesh.revolve build objects and reject bad input" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.createScene();
    const wedge = try f.ok("mesh.from_data", try f.fmt("{{\"scene_id\":\"{s}\",\"name\":\"Wedge\",\"vertices\":[[0,0,0],[1,0,0],[0,1,0],[0,0,1]],\"faces\":[[0,2,1],[0,1,3],[1,2,3],[0,3,2]],\"material_index\":[0,1,1,0],\"location\":[2,0,0]}}", .{id}));
    try testing.expectEqualStrings("Wedge", wedge.object.get("object").?.object.get("name").?.string);
    const slot1 = try f.ok("mesh.select_preview", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Wedge\",\"selector\":{{\"where\":\"material_index == 1\"}}}}", .{id}));
    try testing.expectEqual(@as(i64, 2), slot1.object.get("count").?.integer);

    const bad_index = try f.call("mesh.from_data", try f.fmt("{{\"scene_id\":\"{s}\",\"vertices\":[[0,0,0],[1,0,0],[0,1,0]],\"faces\":[[0,1,3]]}}", .{id}));
    try testing.expectEqualStrings("/faces/0/2", bad_index.tool_error.path);
    const repeated = try f.call("mesh.from_data", try f.fmt("{{\"scene_id\":\"{s}\",\"vertices\":[[0,0,0],[1,0,0],[0,1,0]],\"faces\":[[0,1,0]]}}", .{id}));
    try testing.expectEqualStrings("/faces/0", repeated.tool_error.path);
    const short_uvs = try f.call("mesh.from_data", try f.fmt("{{\"scene_id\":\"{s}\",\"vertices\":[[0,0,0],[1,0,0],[0,1,0]],\"faces\":[[0,1,2]],\"uvs\":[[0,0],[1,0]]}}", .{id}));
    try testing.expectEqualStrings("/uvs", short_uvs.tool_error.path);
    const not_int = try f.call("mesh.from_data", try f.fmt("{{\"scene_id\":\"{s}\",\"vertices\":[[0,0,0],[1,0,0],[0,1,0]],\"faces\":[[0,1,2.5]]}}", .{id}));
    try testing.expectEqualStrings("/faces/0/2", not_int.tool_error.path);

    // A capped can: 2 rings of 16, 16 sides + 2 caps.
    _ = try f.ok("mesh.revolve", try f.fmt("{{\"scene_id\":\"{s}\",\"name\":\"Can\",\"profile\":[[0,0.5],[1,0.5]],\"segments\":16,\"cap_start\":true,\"cap_end\":true}}", .{id}));
    const can = try f.ok("mesh.select_preview", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Can\"}}", .{id}));
    try testing.expectEqual(@as(i64, 18), can.object.get("count").?.integer);
    // Fluted half shell, tilted; too few segments per strip warns.
    const shell = try f.ok("mesh.revolve", try f.fmt("{{\"scene_id\":\"{s}\",\"name\":\"Guard\",\"profile\":[[0,0.9],[1,1.0]],\"angle_end\":180,\"segments\":20,\"relief_count\":22,\"relief_depth\":0.035,\"relief_groove\":0.012,\"rotation\":[0,20,0]}}", .{id}));
    try testing.expectEqual(@as(usize, 1), shell.object.get("warnings").?.array.items.len);
    const inner_pole = try f.call("mesh.revolve", try f.fmt("{{\"scene_id\":\"{s}\",\"profile\":[[0,1],[1,0],[2,1]]}}", .{id}));
    try testing.expectEqualStrings("/profile/1/1", inner_pole.tool_error.path);
}

test "mesh.from_sdf models blended shapes with slots and precise errors" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.createScene();
    const pebble = try f.ok("mesh.from_sdf", try f.fmt("{{\"scene_id\":\"{s}\",\"name\":\"Pebble\",\"voxel_size\":0.02,\"steps\":[{{\"shape\":{{\"type\":\"ellipsoid\",\"radii\":[0.3,0.2,0.12]}}}},{{\"blend\":0.05,\"slot\":1,\"shape\":{{\"type\":\"capsule\",\"a\":[0,0,0.1],\"b\":[0,0,0.3],\"radius\":0.04}}}},{{\"op\":\"subtract\",\"blend\":0.02,\"shape\":{{\"type\":\"sphere\",\"radius\":0.08,\"location\":[0.2,0,0.1]}}}},{{\"steps\":[{{\"shape\":{{\"type\":\"chain\",\"points\":[[0.2,0.1,0],[0.3,0.2,0.05],[0.35,0.2,0.15]],\"radius\":0.02,\"mirror_x\":true}}}}]}}],\"location\":[0,0,1]}}", .{id}));
    try testing.expectEqualStrings("Pebble", pebble.object.get("object").?.object.get("name").?.string);
    // The handle's faces carry slot 1, the body slot 0.
    const handle = try f.ok("mesh.select_preview", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Pebble\",\"selector\":{{\"where\":\"material_index == 1\"}}}}", .{id}));
    try testing.expect(handle.object.get("count").?.integer > 10);
    const top = handle.object.get("bounds").?.object.get("max").?.array.items[2];
    try testing.expect(schemaNumber(top) > 1.3);

    const typo = try f.call("mesh.from_sdf", try f.fmt("{{\"scene_id\":\"{s}\",\"steps\":[{{\"shape\":{{\"type\":\"sphere\",\"radious\":1}}}}]}}", .{id}));
    try testing.expectEqualStrings("/steps/0/shape/radious", typo.tool_error.path);
    const no_type = try f.call("mesh.from_sdf", try f.fmt("{{\"scene_id\":\"{s}\",\"steps\":[{{\"steps\":[{{\"shape\":{{\"radius\":1}}}}]}}]}}", .{id}));
    try testing.expectEqualStrings("/steps/0/steps/0/shape/type", no_type.tool_error.path);
    const unbounded = try f.call("mesh.from_sdf", try f.fmt("{{\"scene_id\":\"{s}\",\"steps\":[{{\"shape\":{{\"type\":\"half_space\",\"normal\":[0,0,1]}}}}]}}", .{id}));
    try testing.expectEqualStrings("/steps", unbounded.tool_error.path);
    // With bounds a half-space is fine: a 1 m slab.
    _ = try f.ok("mesh.from_sdf", try f.fmt("{{\"scene_id\":\"{s}\",\"name\":\"Slab\",\"voxel_size\":0.1,\"bounds_min\":[-1,-1,-1],\"bounds_max\":[1,1,1],\"steps\":[{{\"shape\":{{\"type\":\"half_space\",\"normal\":[0,0,1]}}}},{{\"op\":\"intersect\",\"shape\":{{\"type\":\"box\",\"size\":[1,1,1]}}}}]}}", .{id}));
    const huge = try f.call("mesh.from_sdf", try f.fmt("{{\"scene_id\":\"{s}\",\"voxel_size\":0.001,\"steps\":[{{\"shape\":{{\"type\":\"sphere\",\"radius\":1}}}}]}}", .{id}));
    try testing.expectEqualStrings("/voxel_size", huge.tool_error.path);
}

test "curve.add sweeps tubes, edits settings, exports and converts" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.createScene();
    _ = try f.ok("material.create", try f.fmt("{{\"scene_id\":\"{s}\",\"name\":\"Crust\",\"properties\":{{\"base_color\":[0.42,0.15,0.03]}}}}", .{id}));
    const stick = try f.ok("curve.add", try f.fmt("{{\"scene_id\":\"{s}\",\"name\":\"Stick\",\"bevel_depth\":0.034,\"bevel_resolution\":2,\"fill_caps\":true,\"taper_end\":0.8,\"material\":\"Crust\",\"splines\":[{{\"points\":[[0.2,-1.07,-0.27],[1.42,-1.38,-0.2]]}},{{\"type\":\"nurbs\",\"points\":[[0,0,0],[0.3,0,0.2],[0.3,0.3,0.4],[0,0.3,0.6]],\"radii\":[1,1,0.8,0.5],\"tilt\":10}}]}}", .{id}));
    try testing.expectEqual(@as(i64, 2), stick.object.get("object").?.object.get("splines").?.integer);
    // No bevel: no surface, with a warning.
    const bare = try f.ok("curve.add", try f.fmt("{{\"scene_id\":\"{s}\",\"name\":\"Path\",\"splines\":[{{\"points\":[[0,0,0],[1,0,0]]}}]}}", .{id}));
    try testing.expectEqual(@as(usize, 1), bare.object.get("warnings").?.array.items.len);
    _ = try f.ok("object.set_properties", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Path\",\"data\":{{\"bevel_depth\":0.05}}}}", .{id}));
    const bad = try f.call("curve.add", try f.fmt("{{\"scene_id\":\"{s}\",\"splines\":[{{\"points\":[[0,0,0],[1,0,0]],\"radii\":[1]}}]}}", .{id}));
    try testing.expectEqualStrings("/splines/0/radii", bad.tool_error.path);

    // glTF sees the tubes as meshes.
    const out = try f.ok("io.export", try f.fmt("{{\"scene_id\":\"{s}\",\"path\":\"sticks.glb\"}}", .{id}));
    try testing.expectEqual(@as(usize, 0), out.object.get("dropped").?.array.items.len);
    // Straight spline: 2 rings of 8 (8 quads + 2 caps); NURBS: 37 rings (36 x 8 quads + 2 caps).
    const conv = try f.ok("curve.to_mesh", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Stick\"}}", .{id}));
    try testing.expectEqual(@as(i64, 10 + 290), conv.object.get("object").?.object.get("faces").?.integer);
    try testing.expectEqualStrings("Crust", conv.object.get("object").?.object.get("materials").?.array.items[0].string);
    _ = try f.ok("mesh.select_preview", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Stick\"}}", .{id}));
    const again = try f.call("curve.to_mesh", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Stick\"}}", .{id}));
    try testing.expectEqualStrings("/object", again.tool_error.path);
}

test "procedural textures on materials, displacement and relief" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.createScene();
    const camo = try f.ok("material.create", try f.fmt("{{\"scene_id\":\"{s}\",\"name\":\"Camo\",\"properties\":{{\"roughness\":0.85,\"base_color\":{{\"texture\":\"noise\",\"scale\":2.6,\"detail\":2,\"roughness\":0.55,\"distortion\":0.6,\"ramp\":{{\"mode\":\"constant\",\"stops\":[[0,[0.02,0.03,0.01]],[0.45,[0.1,0.06,0.02]],[0.64,[0.19,0.035,0.026]]]}}}},\"normal\":{{\"bump\":{{\"texture\":\"wave\",\"wave_type\":\"rings\",\"direction\":\"spherical\",\"distortion\":6}},\"strength\":0.5}}}}}}", .{id}));
    const tex = camo.object.get("textures").?.object;
    try testing.expectEqualStrings("constant", tex.get("base_color").?.object.get("ramp").?.object.get("mode").?.string);
    try testing.expect(schemaNumber(tex.get("normal").?.object.get("strength").?) == 0.5);
    const typo = try f.call("material.create", try f.fmt("{{\"scene_id\":\"{s}\",\"properties\":{{\"base_color\":{{\"texture\":\"noise\",\"scal\":2}}}}}}", .{id}));
    try testing.expectEqualStrings("/properties/base_color/scal", typo.tool_error.path);
    // A plain value replaces the texture.
    _ = try f.ok("material.create", try f.fmt("{{\"scene_id\":\"{s}\",\"name\":\"Rough\",\"properties\":{{\"roughness\":{{\"texture\":\"voronoi\"}}}}}}", .{id}));
    const plain = try f.ok("material.update", try f.fmt("{{\"scene_id\":\"{s}\",\"material\":\"Rough\",\"properties\":{{\"roughness\":0.3}}}}", .{id}));
    try testing.expect(plain.object.get("textures") == null);

    _ = try f.ok("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"grid\",\"name\":\"Band\",\"grid_subdivisions\":40,\"material\":\"Camo\"}}", .{id}));
    const out = try f.ok("io.export", try f.fmt("{{\"scene_id\":\"{s}\",\"path\":\"camo.glb\"}}", .{id}));
    const dropped = out.object.get("dropped").?.array.items;
    try testing.expectEqual(@as(usize, 1), dropped.len);
    try testing.expect(std.mem.indexOf(u8, dropped[0].string, "procedural base_color, normal") != null);

    // Displace with a recipe: the flat grid gains height.
    _ = try f.ok("modifier.add", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Band\",\"type\":\"displace\",\"properties\":{{\"strength\":0.2,\"texture_recipe\":{{\"texture\":\"noise\",\"scale\":3}}}}}}", .{id}));
    const band = try f.ok("scene.inspect", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Band\"}}", .{id}));
    _ = band;
    const preview = try f.ok("mesh.select_preview", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Band\"}}", .{id}));
    _ = preview;
    // SDF step displacement and revolve relief by texture.
    _ = try f.ok("mesh.from_sdf", try f.fmt("{{\"scene_id\":\"{s}\",\"name\":\"Rock\",\"voxel_size\":0.03,\"steps\":[{{\"shape\":{{\"type\":\"sphere\",\"radius\":0.5}},\"displace\":{{\"amount\":0.1,\"texture\":{{\"texture\":\"voronoi\",\"scale\":4}}}}}}]}}", .{id}));
    const bad_disp = try f.call("mesh.from_sdf", try f.fmt("{{\"scene_id\":\"{s}\",\"steps\":[{{\"shape\":{{\"type\":\"sphere\",\"radius\":0.5}},\"displace\":{{\"amount\":0.1}}}}]}}", .{id}));
    try testing.expectEqualStrings("/steps/0/displace/texture", bad_disp.tool_error.path);
    _ = try f.ok("mesh.revolve", try f.fmt("{{\"scene_id\":\"{s}\",\"name\":\"Bark\",\"profile\":[[0,0.3],[2,0.25]],\"segments\":48,\"relief_depth\":0.05,\"relief_texture\":{{\"texture\":\"wave\",\"direction\":\"z\",\"scale\":4}}}}", .{id}));
}

test "material.bake turns recipes into images that glTF carries as textures" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.createScene();
    _ = try f.ok("material.create", try f.fmt("{{\"scene_id\":\"{s}\",\"name\":\"Camo\",\"properties\":{{\"base_color\":{{\"texture\":\"noise\",\"scale\":2.6,\"ramp\":{{\"mode\":\"constant\",\"stops\":[[0,[0.02,0.03,0.01]],[0.5,[0.19,0.035,0.026]]]}}}},\"roughness\":{{\"texture\":\"voronoi\",\"scale\":4}},\"normal\":{{\"bump\":{{\"texture\":\"wave\",\"scale\":3}},\"strength\":0.4}}}}}}", .{id}));
    _ = try f.ok("object.add_primitive", try f.fmt("{{\"scene_id\":\"{s}\",\"kind\":\"cylinder\",\"name\":\"Band\",\"material\":\"Camo\"}}", .{id}));
    // An SDF mesh has no UVs yet.
    _ = try f.ok("mesh.from_sdf", try f.fmt("{{\"scene_id\":\"{s}\",\"name\":\"Blob\",\"voxel_size\":0.1,\"steps\":[{{\"shape\":{{\"type\":\"sphere\",\"radius\":0.5}}}}]}}", .{id}));
    _ = try f.ok("material.assign", try f.fmt("{{\"scene_id\":\"{s}\",\"objects\":[\"Blob\"],\"material\":\"Camo\"}}", .{id}));
    const no_uv = try f.call("material.bake", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Blob\",\"size\":32}}", .{id}));
    try testing.expectEqualStrings("/object", no_uv.tool_error.path);

    const baked = try f.ok("material.bake", try f.fmt("{{\"scene_id\":\"{s}\",\"object\":\"Band\",\"size\":64}}", .{id}));
    const images = baked.object.get("images").?.array.items;
    try testing.expectEqual(@as(usize, 3), images.len);
    try testing.expectEqualStrings("Camo_base_color", images[0].object.get("image").?.string);
    try testing.expect(schemaNumber(images[0].object.get("coverage").?) > 0.3);
    const mat = try f.ok("material.update", try f.fmt("{{\"scene_id\":\"{s}\",\"material\":\"Camo\",\"properties\":{{}}}}", .{id}));
    try testing.expectEqualStrings("Camo_normal", mat.object.get("images").?.object.get("normal").?.string);

    _ = try f.ok("object.delete", try f.fmt("{{\"scene_id\":\"{s}\",\"objects\":[\"Blob\"]}}", .{id}));
    const out = try f.ok("io.export", try f.fmt("{{\"scene_id\":\"{s}\",\"path\":\"band.gltf\"}}", .{id}));
    // Baked inputs no longer count as procedural.
    try testing.expectEqual(@as(usize, 0), out.object.get("dropped").?.array.items.len);
    const text = try f.tmp.dir.readFileAlloc(testing.io, "band.gltf", f.arena_state.allocator(), .limited(1 << 24));
    const gltf = try std.json.parseFromSliceLeaky(Value, f.arena_state.allocator(), text, .{});
    try testing.expectEqual(@as(usize, 3), gltf.object.get("textures").?.array.items.len);
    const pbr = gltf.object.get("materials").?.array.items[0].object.get("pbrMetallicRoughness").?.object;
    try testing.expect(pbr.get("baseColorTexture") != null and pbr.get("metallicRoughnessTexture") != null);
    try testing.expectEqual(@as(f64, 1), schemaNumber(pbr.get("roughnessFactor").?));
    try testing.expect(gltf.object.get("materials").?.array.items[0].object.get("normalTexture") != null);
}
