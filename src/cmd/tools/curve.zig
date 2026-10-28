//! curve.add and curve.to_mesh: splines swept into tubes (breadsticks,
//! rims, ropes, hair strands), kept editable as curves or frozen to meshes.

const std = @import("std");
const math = @import("math");
const engine = @import("engine");
const server = @import("../server.zig");
const schema = @import("../schema.zig");
const common = @import("common.zig");

const core = engine.core;
const geom = engine.geom;
const Call = server.Call;
const Tool = server.Tool;
const HandlerError = server.HandlerError;
const Curve = core.types.Curve;

pub const max_points = 100_000;

pub const tools = [_]Tool{
    .{
        .name = "curve.add",
        .title = "Add curve",
        .description = "Add a curve object: splines of points swept into a round tube of radius bevel_depth x each point's radius (bevel_depth 0 = no surface), tapering from taper_start to taper_end. Spline {points [[x,y,z]...], radius or radii (per point), tilt (deg) or tilts, type poly (straight segments) or nurbs (smooth, through the end points), order 2-6}. Edit settings later with object.set_properties data; freeze with curve.to_mesh. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"name\":\"Breadstick\",\"bevel_depth\":0.034,\"fill_caps\":true,\"taper_end\":0.8,\"splines\":[{\"points\":[[0.2,-1.07,-0.27],[1.42,-1.38,-0.2]]}]}.",
        .params = common.mutating(&.{
            common.name,
            .{ .name = "splines", .type = .{ .objects = .{ .max_items = 4096 } }, .doc = "Splines", .required = true },
            .{ .name = "bevel_depth", .type = .{ .number = .{ .min = 0, .max = 1e6, .unit = .metres } }, .doc = "Tube radius", .default = .{ .number = 0 } },
            .{ .name = "bevel_resolution", .type = .{ .integer = .{ .min = 0, .max = geom.curve.max_bevel_resolution } }, .doc = "Ring has 4 + 2 x this vertices", .default = .{ .integer = 4 } },
            .{ .name = "resolution_u", .type = .{ .integer = .{ .min = 1, .max = geom.curve.max_resolution } }, .doc = "Samples per NURBS span", .default = .{ .integer = 12 } },
            .{ .name = "fill_caps", .type = .boolean, .doc = "Close the ends", .default = .{ .boolean = false } },
            .{ .name = "taper_start", .type = .{ .number = .{ .min = 0, .max = 100 } }, .doc = "Radius factor at the start", .default = .{ .number = 1 } },
            .{ .name = "taper_end", .type = .{ .number = .{ .min = 0, .max = 100 } }, .doc = "Radius factor at the end", .default = .{ .number = 1 } },
            .{ .name = "material", .type = .{ .name_ref = .{} }, .doc = "Material for slot 0" },
            common.location,
            common.rotation,
            common.scale,
        }),
        .kind = .mutating,
        .handler = add,
    },
    .{
        .name = "curve.to_mesh",
        .title = "Curve to mesh",
        .description = "Replace a curve object's data with the mesh it evaluates to, keeping its material slots, so mesh.* tools and modifiers apply. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"object\":\"Breadstick\"}.",
        .params = common.mutating(&.{
            .{ .name = "object", .type = .{ .name_ref = .{} }, .doc = "Curve object", .required = true },
        }),
        .kind = .mutating,
        .handler = toMesh,
    },
};

fn add(c: *Call) HandlerError!void {
    const a = c.args;
    const items = a.value("splines").?.array.items;
    var points: std.ArrayList(math.Vec3) = .empty;
    var radius: std.ArrayList(f32) = .empty;
    var tilt: std.ArrayList(f32) = .empty;
    const offsets = try c.arena.alloc(u32, items.len + 1);
    const kinds = try c.arena.alloc(u8, items.len);
    const orders = try c.arena.alloc(u8, items.len);
    offsets[0] = 0;
    for (items, 0..) |item, i| {
        const path = try std.fmt.allocPrint(c.arena, "/splines/{d}", .{i});
        try readSpline(c, item.object, path, &points, &radius, &tilt, &kinds[i], &orders[i]);
        offsets[i + 1] = @intCast(points.items.len);
    }
    const gpa = c.doc().gpa;
    var cu: Curve = .{
        .bevel_depth = a.float("bevel_depth").?,
        .bevel_resolution = @intCast(a.int("bevel_resolution").?),
        .resolution_u = @intCast(a.int("resolution_u").?),
        .use_fill_caps = a.boolean("fill_caps").?,
        .taper_start = a.float("taper_start").?,
        .taper_end = a.float("taper_end").?,
    };
    errdefer cu.releaseRefs(gpa);
    cu.points = try .fromSlice(gpa, points.items);
    cu.radius = try .fromSlice(gpa, radius.items);
    cu.tilt = try .fromSlice(gpa, tilt.items);
    cu.spline_offsets = try .fromSlice(gpa, offsets);
    cu.spline_type = try .fromSlice(gpa, kinds);
    cu.spline_order = try .fromSlice(gpa, orders);
    // Budget: what the tube will hold.
    var samples: u64 = 0;
    for (0..items.len) |i| {
        const n: u64 = offsets[i + 1] - offsets[i];
        samples += if (kinds[i] == @intFromEnum(core.types.SplineType.nurbs)) @as(u64, @intCast(cu.resolution_u)) * (n - 1) + 1 else n;
    }
    try c.spendTriangles(samples * 2 * geom.curve.ringSize(@intCast(cu.bevel_resolution)));
    const material: ?core.IdHandle = if (a.str("material")) |m| try c.lookup(.material, m, "/material") else null;

    const doc = c.doc();
    const name = a.str("name") orelse "Curve";
    const ch = try doc.db.create(.curve, name, cu);
    const oh = core.edit.addObject(doc, name, .curve, ch) catch return error.OutOfMemory;
    const ob = doc.db.get(.object, oh).?;
    common.applyPlacement(c, ob);
    if (material) |m| core.edit.assignMaterial(doc, oh, m, 0) catch return error.OutOfMemory;
    try c.markCreated(oh, ob.name.slice());
    try c.markCreated(ch, doc.db.get(.curve, ch).?.name.slice());
    if (cu.bevel_depth == 0) try c.warn("bevel_depth is 0, so '{s}' has no surface; set it with object.set_properties data", .{ob.name.slice()});
    try c.field("object");
    try common.writeObjectSummary(c, &c.out, oh);
    try c.say("Added curve '{s}' ({d} spline(s), {d} points).", .{ ob.name.slice(), items.len, points.items.len });
}

fn readSpline(c: *Call, o: std.json.ObjectMap, path: []const u8, points: *std.ArrayList(math.Vec3), radius: *std.ArrayList(f32), tilt: *std.ArrayList(f32), kind: *u8, order: *u8) HandlerError!void {
    const allowed = [_][]const u8{ "points", "radius", "radii", "tilt", "tilts", "type", "order" };
    var it = o.iterator();
    outer: while (it.next()) |e| {
        for (allowed) |k| if (std.mem.eql(u8, k, e.key_ptr.*)) continue :outer;
        return c.failAt(.invalid_argument, try std.fmt.allocPrint(c.arena, "{s}/{s}", .{ path, e.key_ptr.* }), "", &allowed, "unknown key '{s}'", .{e.key_ptr.*});
    }
    const pv = o.get("points") orelse return c.failAt(.invalid_argument, try std.fmt.allocPrint(c.arena, "{s}/points", .{path}), "", &.{}, "missing 'points'", .{});
    const pts = if (pv == .array) pv.array.items else &[_]std.json.Value{};
    if (pts.len < 2) return c.failAt(.invalid_argument, try std.fmt.allocPrint(c.arena, "{s}/points", .{path}), "", &.{}, "a spline needs at least 2 points", .{});
    if (points.items.len + pts.len > max_points) return c.failAt(.invalid_argument, path, "split the curve into several objects", &.{}, "more than {d} points", .{max_points});
    for (pts, 0..) |p, i| {
        const xyz = if (p == .array and p.array.items.len == 3) p.array.items else return c.failAt(.invalid_argument, try std.fmt.allocPrint(c.arena, "{s}/points/{d}", .{ path, i }), "", &.{}, "expected [x, y, z]", .{});
        var out: math.Vec3 = undefined;
        for (xyz, &out) |x, *q| {
            const f = schema.number(x) orelse return c.failAt(.invalid_argument, try std.fmt.allocPrint(c.arena, "{s}/points/{d}", .{ path, i }), "", &.{}, "expected numbers", .{});
            if (!(@abs(f) <= 1e6)) return c.failAt(.invalid_argument, try std.fmt.allocPrint(c.arena, "{s}/points/{d}", .{ path, i }), "", &.{}, "coordinates must be within 1e6", .{});
            q.* = @floatCast(f);
        }
        try points.append(c.arena, out);
    }
    try perPoint(c, o, path, "radius", "radii", pts.len, 1, 0, radius, false);
    try perPoint(c, o, path, "tilt", "tilts", pts.len, 0, -1e5, tilt, true);
    kind.* = @intFromEnum(core.types.SplineType.poly);
    if (o.get("type")) |t| {
        const k = (if (t == .string) std.meta.stringToEnum(core.types.SplineType, t.string) else null) orelse
            return c.failAt(.invalid_argument, try std.fmt.allocPrint(c.arena, "{s}/type", .{path}), "", &.{ "poly", "nurbs" }, "unknown spline type", .{});
        kind.* = @intFromEnum(k);
    }
    order.* = 4;
    if (o.get("order")) |ov| {
        const f = schema.number(ov) orelse 0;
        if (!(f >= 2 and f <= 6 and f == @floor(f))) return c.failAt(.invalid_argument, try std.fmt.allocPrint(c.arena, "{s}/order", .{path}), "", &.{}, "order must be a whole number from 2 to 6", .{});
        order.* = @intFromFloat(f);
    }
}

/// One value for every point, from `one` (same for all) or `many` (a list).
fn perPoint(c: *Call, o: std.json.ObjectMap, path: []const u8, comptime one: []const u8, comptime many: []const u8, n: usize, default: f32, min: f64, out: *std.ArrayList(f32), degrees: bool) HandlerError!void {
    if (o.get(many)) |lv| {
        const items = if (lv == .array and lv.array.items.len == n) lv.array.items else return c.failAt(.invalid_argument, try std.fmt.allocPrint(c.arena, "{s}/" ++ many, .{path}), "", &.{}, "'" ++ many ++ "' needs one value per point ({d})", .{n});
        for (items, 0..) |x, i| {
            const f = schema.number(x) orelse min - 1;
            if (!(f >= min and f <= 1e5)) return c.failAt(.invalid_argument, try std.fmt.allocPrint(c.arena, "{s}/" ++ many ++ "/{d}", .{ path, i }), "", &.{}, "'" ++ many ++ "' values must be at least {d}", .{min});
            try out.append(c.arena, if (degrees) math.vec.degToRad(@floatCast(f)) else @floatCast(f));
        }
        return;
    }
    var val: f32 = default;
    if (o.get(one)) |x| {
        const f = schema.number(x) orelse min - 1;
        if (!(f >= min and f <= 1e5)) return c.failAt(.invalid_argument, try std.fmt.allocPrint(c.arena, "{s}/" ++ one, .{path}), "", &.{}, "'" ++ one ++ "' must be at least {d}", .{min});
        val = if (degrees) math.vec.degToRad(@floatCast(f)) else @floatCast(f);
    }
    try out.appendNTimes(c.arena, val, n);
}

fn toMesh(c: *Call) HandlerError!void {
    const oh = try c.object("object");
    const doc = c.doc();
    const ob = doc.db.get(.object, oh).?;
    if (ob.kind != .curve) return c.failAt(.invalid_argument, "/object", "", &.{}, "'{s}' is a {s}, not a curve", .{ ob.name.slice(), @tagName(ob.kind) });
    const ch = ob.data orelse return c.failAt(.stale_handle, "/object", "", &.{}, "the curve of '{s}' is missing", .{ob.name.slice()});
    const cu = doc.db.get(.curve, ch) orelse return c.failAt(.stale_handle, "/object", "", &.{}, "the curve of '{s}' is missing", .{ob.name.slice()});
    const gpa = doc.gpa;
    var mesh = geom.curve.toMesh(gpa, cu) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return c.fail(.internal, "the curve could not be evaluated", .{}),
    };
    if (mesh.faceCount() == 0) {
        mesh.releaseRefs(gpa);
        return c.failAt(.invalid_operation, "/object", "set bevel_depth above 0 with object.set_properties data", &.{}, "'{s}' has no surface to convert", .{ob.name.slice()});
    }
    mesh.materials = cu.materials.retain();
    const name = try c.arena.dupe(u8, cu.name.slice());
    const mh = doc.db.create(.mesh, name, mesh) catch |e| {
        mesh.releaseRefs(gpa);
        return e;
    };
    const obj = doc.db.get(.object, oh).?;
    obj.kind = .mesh;
    obj.data = mh;
    // The curve goes when nothing else uses it.
    if (core.edit.userCount(&doc.db, ch) == 0) _ = doc.db.remove(.curve, ch);
    try c.markChanged(oh, obj.name.slice());
    try c.markCreated(mh, doc.db.get(.mesh, mh).?.name.slice());
    try c.field("object");
    try common.writeObjectSummary(c, &c.out, oh);
    const m = doc.db.get(.mesh, mh).?;
    try c.say("Converted '{s}' to a mesh ({d} verts, {d} faces).", .{ obj.name.slice(), m.vertCount(), m.faceCount() });
}
