//! Command-core integration tests: tool calls end to end, without a
//! transport.

const std = @import("std");
const math = @import("math");
const server_mod = @import("server.zig");
const catalog = @import("catalog.zig");
const paths = @import("paths.zig");
const replay = @import("replay.zig");

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
