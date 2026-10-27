//! The selector JSON grammar (TRD §7), parsed into the engine's form.
//! A selector is one JSON object; every key present must hold, so keys
//! combine as AND:
//!
//!   domain    "face" | "edge" | "vert" (top level only; default per tool)
//!   space     "world" (default) | "local" (top level only)
//!   index     [3, [10, 20]]: indices or inclusive [first, last] ranges
//!   where     "z > 0.5" or a list of such; left side x y z (centre),
//!             nx ny nz (normal), area, length, index or a scalar attribute,
//!             optionally abs(...); operators < <= > >= == !=
//!   box       {"min": [x, y, z], "max": [x, y, z]}: centre inside
//!   sphere    {"center": [x, y, z], "radius": r}
//!   normal    [x, y, z] with "within": degrees (default 30)
//!   direction [x, y, z]: edges running along it, either way, with the
//!             same "within" (edge domain only)
//!   union     [selector, ...]: any of them
//!   intersect [selector, ...]: all of them
//!   subtract  selector or [selector, ...]: none of them
//!
//! `{}` selects everything in the domain.

const std = @import("std");
const engine = @import("engine");
const schema = @import("schema.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Stringify = std.json.Stringify;
const sel = engine.geom.select;
const Selector = sel.Selector;
const Node = sel.Node;
const Domain = sel.Domain;

/// The grammar in one paragraph, for tool descriptions.
pub const summary = "Selector: one JSON object whose keys must all hold. domain face|edge|vert, space world (default)|local; index [3,[10,20]] (inclusive ranges); where \"z > 0.5\" or a list (x y z centre, nx ny nz normal, area, length, index, or a scalar attribute such as material_index; abs(...) allowed; < <= > >= == !=); box {min,max} (centre inside); sphere {center,radius}; normal [x,y,z] with within (deg, default 30); direction [x,y,z] (edges along it either way, same within); union / intersect [selectors]; subtract selector or list. {} selects all. Face centre = mean of corners.";

const max_depth = 16;
const max_nodes = 256;

const node_keys = [_][]const u8{ "index", "where", "box", "sphere", "normal", "direction", "within", "union", "intersect", "subtract" };
const top_keys = [_][]const u8{ "domain", "space", "index", "where", "box", "sphere", "normal", "direction", "within", "union", "intersect", "subtract" };

const Parser = struct {
    arena: Allocator,
    failure: *schema.Failure,
    domain: Domain,
    nodes: usize = 0,

    fn fail(p: *Parser, path: []const u8, hint: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!?Node {
        p.failure.* = .{ .message = try std.fmt.allocPrint(p.arena, fmt, args), .path = path, .hint = hint };
        return null;
    }

    fn sub(p: *Parser, path: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(p.arena, "{s}" ++ fmt, .{path} ++ args);
    }

    fn node(p: *Parser, val: Value, path: []const u8, depth: usize, top: bool) Allocator.Error!?Node {
        if (val != .object) return p.fail(path, "a selector is a JSON object such as {\"normal\":[0,0,1]}", "selector must be an object", .{});
        if (depth > max_depth) return p.fail(path, "", "selectors nest at most {d} deep", .{max_depth});
        p.nodes += 1;
        if (p.nodes > max_nodes) return p.fail(path, "", "a selector may have at most {d} parts", .{max_nodes});
        const obj = val.object;
        var it = obj.iterator();
        while (it.next()) |kv| {
            const keys: []const []const u8 = if (top) &top_keys else &node_keys;
            var known = false;
            for (keys) |k| if (std.mem.eql(u8, k, kv.key_ptr.*)) {
                known = true;
            };
            if (!known) {
                const nested = !top and (std.mem.eql(u8, kv.key_ptr.*, "domain") or std.mem.eql(u8, kv.key_ptr.*, "space"));
                p.failure.* = .{
                    .message = try std.fmt.allocPrint(p.arena, "unknown selector key '{s}'", .{kv.key_ptr.*}),
                    .path = try p.sub(path, "/{s}", .{kv.key_ptr.*}),
                    .hint = if (nested) "domain and space apply to the whole selector; set them at the top level" else "",
                    .valid_values = keys,
                };
                return null;
            }
        }

        var n: Node = .{};
        if (obj.get("index")) |x| n.index = (try p.indexList(x, try p.sub(path, "/index", .{}))) orelse return null;
        if (obj.get("where")) |x| {
            const wpath = try p.sub(path, "/where", .{});
            const items: []const Value = switch (x) {
                .string => &.{x},
                .array => |a| a.items,
                else => return p.fail(wpath, "for example \"z > 0.5\" or [\"z > 0.5\", \"abs(x) < 0.1\"]", "where must be a comparison string or a list of them", .{}),
            };
            const preds = try p.arena.alloc(sel.Pred, items.len);
            for (items, preds, 0..) |item, *pr, i| {
                const ipath = if (x == .array) try p.sub(wpath, "/{d}", .{i}) else wpath;
                if (item != .string) return p.fail(ipath, "for example \"z > 0.5\"", "each where entry must be a string", .{});
                pr.* = (try p.comparison(item.string, ipath)) orelse return null;
            }
            n.where = preds;
        }
        if (obj.get("box")) |x| {
            const bpath = try p.sub(path, "/box", .{});
            if (x != .object) return p.fail(bpath, "for example {\"min\":[-1,-1,0.5],\"max\":[1,1,2]}", "box must be an object with min and max", .{});
            const lo = (try p.vec3(x.object.get("min"), try p.sub(bpath, "/min", .{}))) orelse return null;
            const hi = (try p.vec3(x.object.get("max"), try p.sub(bpath, "/max", .{}))) orelse return null;
            n.box = .{ lo, hi };
        }
        if (obj.get("sphere")) |x| {
            const spath = try p.sub(path, "/sphere", .{});
            if (x != .object) return p.fail(spath, "for example {\"center\":[0,0,1],\"radius\":0.5}", "sphere must be an object with center and radius", .{});
            const ctr = (try p.vec3(x.object.get("center"), try p.sub(spath, "/center", .{}))) orelse return null;
            const r = schema.number(x.object.get("radius") orelse .null) orelse return p.fail(try p.sub(spath, "/radius", .{}), "", "sphere radius must be a number (m)", .{});
            if (!(r >= 0) or !std.math.isFinite(r)) return p.fail(try p.sub(spath, "/radius", .{}), "", "sphere radius must be zero or more", .{});
            n.sphere = .{ .center = ctr, .radius = @floatCast(r) };
        }
        var within: f64 = 30;
        if (obj.get("within")) |w| {
            within = schema.number(w) orelse return p.fail(try p.sub(path, "/within", .{}), "", "within must be a number of degrees", .{});
            if (!(within >= 0 and within <= 180)) return p.fail(try p.sub(path, "/within", .{}), "", "within must be between 0 and 180 degrees", .{});
            if (obj.get("normal") == null and obj.get("direction") == null) {
                return p.fail(try p.sub(path, "/within", .{}), "within is the angle allowed around normal or direction; add \"normal\":[x,y,z]", "within needs normal or direction", .{});
            }
        }
        const cos_max: f32 = @floatCast(@cos(within * std.math.pi / 180.0) - 1e-6);
        if (obj.get("normal")) |x| {
            const dir = (try p.vec3(x, try p.sub(path, "/normal", .{}))) orelse return null;
            if (@abs(dir[0]) + @abs(dir[1]) + @abs(dir[2]) == 0) return p.fail(try p.sub(path, "/normal", .{}), "for example [0,0,1] for faces facing up", "normal must not be zero", .{});
            n.normal = .{ .dir = dir, .cos_max = cos_max };
        }
        if (obj.get("direction")) |x| {
            const dpath = try p.sub(path, "/direction", .{});
            if (p.domain != .edge) return p.fail(dpath, "set \"domain\":\"edge\"; for faces or verts use normal", "direction applies to edges only", .{});
            const dir = (try p.vec3(x, dpath)) orelse return null;
            if (@abs(dir[0]) + @abs(dir[1]) + @abs(dir[2]) == 0) return p.fail(dpath, "for example [0,0,1] for vertical edges", "direction must not be zero", .{});
            n.direction = .{ .dir = dir, .cos_max = cos_max };
        }
        inline for (.{ .{ "union", "any_of" }, .{ "intersect", "all_of" }, .{ "subtract", "none_of" } }) |pair| {
            if (obj.get(pair[0])) |x| {
                const lpath = try p.sub(path, "/" ++ pair[0], .{});
                const items: []const Value = switch (x) {
                    .array => |a| a.items,
                    .object => if (comptime std.mem.eql(u8, pair[0], "subtract")) &.{x} else return p.fail(lpath, "give a list of selectors", pair[0] ++ " must be a list of selectors", .{}),
                    else => return p.fail(lpath, "give a list of selectors", pair[0] ++ " must be a list of selectors", .{}),
                };
                if (items.len == 0) return p.fail(lpath, "", pair[0] ++ " needs at least one selector", .{});
                const kids = try p.arena.alloc(Node, items.len);
                for (items, kids, 0..) |item, *k, i| {
                    const kpath = if (x == .array) try p.sub(lpath, "/{d}", .{i}) else lpath;
                    k.* = (try p.node(item, kpath, depth + 1, false)) orelse return null;
                }
                @field(n, pair[1]) = kids;
            }
        }
        return n;
    }

    fn vec3(p: *Parser, val: ?Value, path: []const u8) Allocator.Error!?[3]f32 {
        const x = val orelse {
            _ = try p.fail(path, "", "missing [x, y, z]", .{});
            return null;
        };
        const arr = if (x == .array) x.array.items else &[_]Value{};
        if (arr.len != 3) {
            _ = try p.fail(path, "", "expected [x, y, z]", .{});
            return null;
        }
        var out: [3]f32 = undefined;
        for (arr, 0..) |item, i| {
            const f = schema.number(item) orelse {
                _ = try p.fail(try p.sub(path, "/{d}", .{i}), "", "expected a number", .{});
                return null;
            };
            if (!std.math.isFinite(f) or @abs(f) > 1e9) {
                _ = try p.fail(try p.sub(path, "/{d}", .{i}), "", "expected a finite number within ±1e9", .{});
                return null;
            }
            out[i] = @floatCast(f);
        }
        return out;
    }

    fn indexList(p: *Parser, val: Value, path: []const u8) Allocator.Error!?[]const sel.Range {
        const items: []const Value = switch (val) {
            .integer => &.{val},
            .array => |a| a.items,
            else => {
                _ = try p.fail(path, "for example [0, 5, [10, 20]]", "index must be a list of indices or [first, last] ranges", .{});
                return null;
            },
        };
        const out = try p.arena.alloc(sel.Range, items.len);
        for (items, out, 0..) |item, *r, i| {
            const ipath = if (val == .array) try p.sub(path, "/{d}", .{i}) else path;
            switch (item) {
                .integer => |k| r.* = .{ (try p.index(k, ipath)) orelse return null, 0 },
                .array => |a| {
                    if (a.items.len != 2 or a.items[0] != .integer or a.items[1] != .integer) {
                        _ = try p.fail(ipath, "a range is [first, last], both included", "expected an index or a [first, last] pair", .{});
                        return null;
                    }
                    r.* = .{ (try p.index(a.items[0].integer, ipath)) orelse return null, (try p.index(a.items[1].integer, ipath)) orelse return null };
                    continue;
                },
                else => {
                    _ = try p.fail(ipath, "", "expected an index or a [first, last] pair", .{});
                    return null;
                },
            }
            r[1] = r[0];
        }
        return out;
    }

    fn index(p: *Parser, k: i64, path: []const u8) Allocator.Error!?u32 {
        if (k < 0 or k >= std.math.maxInt(u32)) {
            _ = try p.fail(path, "", "indices start at 0", .{});
            return null;
        }
        return @intCast(k);
    }

    fn comparison(p: *Parser, text: []const u8, path: []const u8) Allocator.Error!?sel.Pred {
        const hint = "write <field> <op> <number>, e.g. \"z > 0.5\", \"abs(x) < 0.1\", \"material_index == 1\"";
        const ops = [_]struct { []const u8, sel.Cmp }{ .{ "<=", .le }, .{ ">=", .ge }, .{ "==", .eq }, .{ "!=", .ne }, .{ "<", .lt }, .{ ">", .gt }, .{ "=", .eq } };
        var at: ?usize = null;
        var cmp: sel.Cmp = .eq;
        var op_len: usize = 0;
        for (ops) |o| if (std.mem.indexOf(u8, text, o[0])) |i| {
            if (at == null or i < at.?) {
                at = i;
                cmp = o[1];
                op_len = o[0].len;
            }
        };
        const split = at orelse {
            _ = try p.fail(path, hint, "no comparison operator in '{s}'", .{text});
            return null;
        };
        var lhs = std.mem.trim(u8, text[0..split], " \t");
        const rhs = std.mem.trim(u8, text[split + op_len ..], " \t");
        var abs = false;
        if (std.mem.startsWith(u8, lhs, "abs(") and std.mem.endsWith(u8, lhs, ")")) {
            abs = true;
            lhs = std.mem.trim(u8, lhs[4 .. lhs.len - 1], " \t");
        }
        if (lhs.len == 0 or lhs.len > 255) {
            _ = try p.fail(path, hint, "missing field before the operator in '{s}'", .{text});
            return null;
        }
        const value: f64 = if (std.mem.eql(u8, rhs, "true")) 1 else if (std.mem.eql(u8, rhs, "false")) 0 else std.fmt.parseFloat(f64, rhs) catch {
            _ = try p.fail(path, hint, "'{s}' is not a number in '{s}'", .{ rhs, text });
            return null;
        };
        if (!std.math.isFinite(value)) {
            _ = try p.fail(path, hint, "'{s}' is not finite", .{rhs});
            return null;
        }
        const builtin = std.meta.stringToEnum(std.meta.Tag(sel.Field), lhs);
        const field: sel.Field = if (builtin) |b| switch (b) {
            .attribute => .{ .attribute = lhs },
            inline else => |t| t,
        } else .{ .attribute = try p.arena.dupe(u8, lhs) };
        return .{ .field = field, .abs = abs, .cmp = cmp, .value = value };
    }
};

pub fn parseDomain(s: []const u8) ?Domain {
    const names = [_]struct { []const u8, Domain }{
        .{ "face", .face }, .{ "faces", .face }, .{ "edge", .edge },   .{ "edges", .edge },
        .{ "vert", .vert }, .{ "verts", .vert }, .{ "vertex", .vert }, .{ "vertices", .vert },
    };
    for (names) |n| if (std.mem.eql(u8, n[0], s)) return n[1];
    return null;
}

/// Parses a selector argument at JSON pointer `path`. A missing selector
/// selects everything in `default_domain`. Null on failure, with `failure` set.
pub fn parse(arena: Allocator, val: ?Value, default_domain: Domain, path: []const u8, failure: *schema.Failure) Allocator.Error!?Selector {
    var p: Parser = .{ .arena = arena, .failure = failure, .domain = default_domain };
    var out: Selector = .{ .domain = default_domain };
    const x = val orelse return out;
    if (x == .null) return out;
    if (x != .object) {
        failure.* = .{ .message = "selector must be an object", .path = path, .hint = summary };
        return null;
    }
    if (x.object.get("domain")) |d| {
        out.domain = (if (d == .string) parseDomain(d.string) else null) orelse {
            failure.* = .{ .message = "domain must be face, edge or vert", .path = try p.sub(path, "/domain", .{}), .valid_values = &.{ "face", "edge", "vert" } };
            return null;
        };
    }
    if (x.object.get("space")) |s| {
        out.space = (if (s == .string) std.meta.stringToEnum(sel.Space, s.string) else null) orelse {
            failure.* = .{ .message = "space must be world or local", .path = try p.sub(path, "/space", .{}), .valid_values = &.{ "world", "local" } };
            return null;
        };
    }
    p.domain = out.domain;
    out.root = (try p.node(x, path, 0, true)) orelse return null;
    return out;
}

/// Writes sorted indices as the `index` form a selector accepts: single
/// indices and [first, last] runs. Stops after `max_items` entries and
/// returns false if it had to.
pub fn writeIndices(w: *Stringify, sorted: []const u32, max_items: usize) Stringify.Error!bool {
    try w.beginArray();
    var i: usize = 0;
    var n: usize = 0;
    var complete = true;
    while (i < sorted.len) {
        var j = i;
        while (j + 1 < sorted.len and sorted[j + 1] == sorted[j] + 1) j += 1;
        if (n == max_items) {
            complete = false;
            break;
        }
        if (j == i) {
            try w.write(sorted[i]);
        } else {
            try w.beginArray();
            try w.write(sorted[i]);
            try w.write(sorted[j]);
            try w.endArray();
        }
        n += 1;
        i = j + 1;
    }
    try w.endArray();
    return complete;
}

const testing = std.testing;

fn parseText(arena: Allocator, text: []const u8, failure: *schema.Failure) !?Selector {
    const val = try std.json.parseFromSliceLeaky(Value, arena, text, .{});
    return parse(arena, val, .face, "/selector", failure);
}

test "selector grammar parses and reports precise paths" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var failure: schema.Failure = undefined;

    const s = (try parseText(arena,
        \\{"domain":"verts","where":["abs(x) < 0.1","material_index == 2"],"normal":[0,0,1],"within":45,
        \\ "union":[{"index":[1,[4,6]]},{"box":{"min":[0,0,0],"max":[1,1,1]}}],"subtract":{"sphere":{"center":[0,0,0],"radius":0.5}}}
    , &failure)).?;
    try testing.expectEqual(Domain.vert, s.domain);
    try testing.expectEqual(@as(usize, 2), s.root.where.len);
    try testing.expect(s.root.where[0].abs);
    try testing.expectEqual(sel.Cmp.lt, s.root.where[0].cmp);
    try testing.expectEqualStrings("material_index", s.root.where[1].field.attribute);
    try testing.expectApproxEqAbs(@as(f32, @cos(std.math.pi / 4.0)), s.root.normal.?.cos_max, 1e-5);
    try testing.expectEqual(sel.Range{ 4, 6 }, s.root.any_of[0].index.?[1]);
    try testing.expectEqual(@as(usize, 1), s.root.none_of.len);

    try testing.expect(try parseText(arena, "{\"where\":\"z >> 1\"}", &failure) == null);
    try testing.expectEqualStrings("/selector/where", failure.path);
    try testing.expect(try parseText(arena, "{\"union\":[{\"index\":[0]},{\"domain\":\"vert\"}]}", &failure) == null);
    try testing.expectEqualStrings("/selector/union/1/domain", failure.path);
    try testing.expect(failure.hint.len > 0);
    try testing.expect(try parseText(arena, "{\"index\":[1,[2]]}", &failure) == null);
    try testing.expectEqualStrings("/selector/index/1", failure.path);
    try testing.expect(try parseText(arena, "{\"within\":10}", &failure) == null);
    try testing.expect(try parseText(arena, "{\"normals\":[0,0,1]}", &failure) == null);
    try testing.expect(failure.valid_values.len > 0);

    const d = (try parseText(arena, "{\"domain\":\"edge\",\"direction\":[0,0,2],\"within\":5}", &failure)).?;
    try testing.expectApproxEqAbs(@as(f32, @cos(5 * std.math.pi / 180.0)), d.root.direction.?.cos_max, 1e-5);
    try testing.expect(try parseText(arena, "{\"direction\":[0,0,1]}", &failure) == null);
    try testing.expectEqualStrings("/selector/direction", failure.path);
}

test "index output compresses runs" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var w: Stringify = .{ .writer = &out.writer };
    try testing.expect(try writeIndices(&w, &.{ 0, 1, 2, 5, 7, 8 }, 10));
    try testing.expectEqualStrings("[[0,2],5,[7,8]]", out.written());
}
