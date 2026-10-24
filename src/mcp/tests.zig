//! MCP protocol tests: a scripted session over the message handler.

const std = @import("std");
const cmd = @import("cmd");
const protocol = @import("protocol.zig");

const testing = std.testing;
const Value = std.json.Value;

const meta =
    \\"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}
;
const meta_elicit =
    \\"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{"elicitation":{}}}
;

/// The same snippets with braces doubled, for use inside format strings.
fn escape(comptime s: []const u8) []const u8 {
    comptime var out: []const u8 = "";
    inline for (s) |ch| out = out ++ if (ch == '{') "{{" else if (ch == '}') "}}" else &[_]u8{ch};
    return out;
}
const meta_f = escape(meta);
const meta_elicit_f = escape(meta_elicit);

const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    server: cmd.Server,
    session: protocol.Session,
    tmp: testing.TmpDir,

    fn init(h: *Harness) !void {
        h.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        h.tmp = testing.tmpDir(.{});
        const arena = h.arena_state.allocator();
        const root = try h.tmp.dir.realPathFileAlloc(testing.io, ".", arena);
        const roots = try arena.alloc([]const u8, 1);
        roots[0] = root;
        h.server = cmd.Server.init(testing.allocator, testing.io, .{ .io = testing.io, .threads = 2 }, .{ .roots = .{ .list = roots } }, cmd.catalog.tools);
        h.session = .{ .server = &h.server };
    }

    fn deinit(h: *Harness) void {
        h.server.deinit();
        h.arena_state.deinit();
        h.tmp.cleanup();
    }

    fn send(h: *Harness, line: []const u8) !Value {
        const arena = h.arena_state.allocator();
        const resp = (try h.session.handle(arena, line)) orelse return error.NoResponse;
        try testing.expect(std.mem.indexOfScalar(u8, resp, '\n') == null);
        return std.json.parseFromSliceLeaky(Value, arena, resp, .{});
    }

    fn fmt(h: *Harness, comptime f: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(h.arena_state.allocator(), f, args);
    }
};

fn result(v: Value) std.json.ObjectMap {
    return v.object.get("result").?.object;
}

fn errorCode(v: Value) i64 {
    return v.object.get("error").?.object.get("code").?.integer;
}

test "discover, tools/list size and version checks" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const d = try h.send("{\"jsonrpc\":\"2.0\",\"id\":\"d1\",\"method\":\"server/discover\",\"params\":{" ++ meta ++ "}}");
    try testing.expectEqualStrings("2026-07-28", result(d).get("supportedVersions").?.array.items[0].string);
    try testing.expectEqualStrings("zender", result(d).get("_meta").?.object.get("io.modelcontextprotocol/serverInfo").?.object.get("name").?.string);

    const arena = h.arena_state.allocator();
    const raw = (try h.session.handle(arena, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{" ++ meta ++ "}}")).?;
    // FR-MCP-9: the whole tool list stays under 40 KB.
    try testing.expect(raw.len <= 40 * 1024);
    const tl = try std.json.parseFromSliceLeaky(Value, arena, raw, .{});
    const tools = result(tl).get("tools").?.array.items;
    try testing.expect(tools.len >= 20);
    try testing.expectEqualStrings("scene.create", tools[0].object.get("name").?.string);
    try testing.expectEqual(@as(i64, 3600000), result(tl).get("ttlMs").?.integer);

    const missing = try h.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\",\"params\":{}}");
    try testing.expectEqual(@as(i64, -32602), errorCode(missing));
    const old = try h.send("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"1999-01-01\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}");
    try testing.expectEqual(@as(i64, -32022), errorCode(old));
    const unknown = try h.send("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"nope\",\"params\":{" ++ meta ++ "}}");
    try testing.expectEqual(@as(i64, -32601), errorCode(unknown));
    const garbage = try h.send("{not json");
    try testing.expectEqual(@as(i64, -32700), errorCode(garbage));
    try testing.expect((try h.session.handle(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{}}")) == null);
}

test "legacy initialize, then calls without _meta" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const init = try h.send("{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}");
    try testing.expectEqualStrings("2025-06-18", result(init).get("protocolVersion").?.string);
    const c = try h.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"scene.create\",\"arguments\":{}}}");
    try testing.expectEqual(false, result(c).get("isError").?.bool);
    const sid = result(c).get("structuredContent").?.object.get("scene_id").?.string;
    const bad = try h.send(try h.fmt("{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{{\"name\":\"object.add_primitive\",\"arguments\":{{\"scene_id\":\"{s}\",\"kind\":\"cube\",\"size\":-1}}}}}}", .{sid}));
    try testing.expectEqual(true, result(bad).get("isError").?.bool);
    try testing.expectEqualStrings("/size", result(bad).get("structuredContent").?.object.get("error").?.object.get("path").?.string);
    const unknown = try h.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"mesh.teleport\",\"arguments\":{}}}");
    try testing.expectEqual(@as(i64, -32602), errorCode(unknown));
}

test "preview returns an inline image and a readable resource" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const c = try h.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"scene.create\",\"arguments\":{\"template\":\"default\"}," ++ meta ++ "}}");
    const sid = result(c).get("structuredContent").?.object.get("scene_id").?.string;
    const p = try h.send(try h.fmt("{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{{\"name\":\"render.preview\",\"arguments\":{{\"scene_id\":\"{s}\",\"width\":64}}," ++ meta_f ++ "}}}}", .{sid}));
    const content = result(p).get("content").?.array.items;
    var link: []const u8 = "";
    var saw_image = false;
    for (content) |item| {
        const t = item.object.get("type").?.string;
        if (std.mem.eql(u8, t, "image")) saw_image = true;
        if (std.mem.eql(u8, t, "resource_link")) link = item.object.get("uri").?.string;
    }
    try testing.expect(saw_image);
    const r = try h.send(try h.fmt("{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"resources/read\",\"params\":{{\"uri\":\"{s}\"," ++ meta_f ++ "}}}}", .{link}));
    try testing.expectEqualStrings("image/png", result(r).get("contents").?.array.items[0].object.get("mimeType").?.string);
    const outline = try h.send(try h.fmt("{{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"resources/read\",\"params\":{{\"uri\":\"zender://scene/{s}/object/Cube\"," ++ meta_f ++ "}}}}", .{sid}));
    try testing.expect(std.mem.indexOf(u8, result(outline).get("contents").?.array.items[0].object.get("text").?.string, "\"location\"") != null);
    const missing = try h.send("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"resources/read\",\"params\":{\"uri\":\"zender://scene/nope/log\"," ++ meta ++ "}}");
    try testing.expectEqual(@as(i64, -32602), errorCode(missing));
}

test "closing a changed scene asks for confirmation via MRTR" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const c = try h.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"scene.create\",\"arguments\":{}," ++ meta ++ "}}");
    const sid = result(c).get("structuredContent").?.object.get("scene_id").?.string;
    _ = try h.send(try h.fmt("{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{{\"name\":\"object.add_primitive\",\"arguments\":{{\"scene_id\":\"{s}\",\"kind\":\"plane\"}}," ++ meta_f ++ "}}}}", .{sid}));
    const ask = try h.send(try h.fmt("{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{{\"name\":\"scene.close\",\"arguments\":{{\"scene_id\":\"{s}\"}}," ++ meta_elicit_f ++ "}}}}", .{sid}));
    try testing.expectEqualStrings("input_required", result(ask).get("resultType").?.string);
    try testing.expect(result(ask).get("inputRequests").?.object.get("confirm") != null);
    const declined = try h.send(try h.fmt("{{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{{\"name\":\"scene.close\",\"arguments\":{{\"scene_id\":\"{s}\"}},\"inputResponses\":{{\"confirm\":{{\"action\":\"decline\"}}}}," ++ meta_elicit_f ++ "}}}}", .{sid}));
    try testing.expectEqual(true, result(declined).get("isError").?.bool);
    const done = try h.send(try h.fmt("{{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{{\"name\":\"scene.close\",\"arguments\":{{\"scene_id\":\"{s}\"}},\"inputResponses\":{{\"confirm\":{{\"action\":\"accept\",\"content\":{{\"confirm\":true}}}}}}," ++ meta_elicit_f ++ "}}}}", .{sid}));
    try testing.expectEqual(false, result(done).get("isError").?.bool);
    try testing.expectEqual(@as(usize, 0), h.server.scenes.count());
}
