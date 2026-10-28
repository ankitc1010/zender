//! Tools that build a new mesh object from data rather than a primitive:
//! mesh.from_data and mesh.revolve.

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
const Mesh = core.types.Mesh;

/// Per call; larger meshes go through io.import (PLY), which streams.
pub const max_vertices = 200_000;
pub const max_faces = 400_000;

const material_param: schema.Param = .{ .name = "material", .type = .{ .name_ref = .{} }, .doc = "Material for slot 0" };

pub const tools = [_]Tool{
    .{
        .name = "mesh.from_data",
        .title = "Mesh from data",
        .description = "Create a mesh object from vertex positions and faces (n-gons as vertex indices, counter-clockwise seen from outside). Optional per-corner uvs in face order, per-face material_index (slots), smooth shading. Up to 200000 vertices; use io.import for more. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"name\":\"Wedge\",\"vertices\":[[0,0,0],[1,0,0],[0,1,0],[0,0,1]],\"faces\":[[0,2,1],[0,1,3],[1,2,3],[0,3,2]]}.",
        .params = common.mutating(&.{
            common.name,
            .{ .name = "vertices", .type = .{ .points = .{ .max_items = max_vertices } }, .doc = "Local positions [x, y, z]", .required = true },
            .{ .name = "faces", .type = .{ .tuples = .{ .integer = true, .min = 0, .max_items = max_faces } }, .doc = "Vertex indices per face", .required = true },
            .{ .name = "uvs", .type = .{ .tuples = .{ .width = 2, .max_items = 4 * max_faces } }, .doc = "[u, v] per face corner, in face order" },
            .{ .name = "material_index", .type = .{ .numbers = .{ .integer = true, .min = 0, .max_items = max_faces } }, .doc = "Slot per face" },
            .{ .name = "smooth", .type = .boolean, .doc = "Smooth shading", .default = .{ .boolean = false } },
            material_param,
            common.location,
            common.rotation,
            common.scale,
        }),
        .kind = .mutating,
        .handler = fromData,
    },
    .{
        .name = "mesh.revolve",
        .title = "Revolve profile",
        .description = "Create a surface of revolution (lathe): profile [height, radius] pairs, listed bottom to top, swept around local Z from angle_start to angle_end (degrees from +X). Only an end may have radius 0 (a pole). relief_count rounded strips with relief_depth and an engraved centre line relief_groove flute the surface. Caps fill end rings of full turns. Place and tilt it with location and rotation. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"name\":\"Vase\",\"profile\":[[0,0],[0,0.3],[0.4,0.45],[1,0.2],[1.2,0.25]],\"segments\":64}.",
        .params = common.mutating(&.{
            common.name,
            .{ .name = "profile", .type = .{ .tuples = .{ .width = 2, .max_items = geom.revolve.max_profile } }, .doc = "[height, radius] pairs (m)", .required = true },
            .{ .name = "segments", .type = .{ .integer = .{ .min = 3, .max = geom.primitives.limits.max_segments } }, .doc = "Steps around the sweep", .default = .{ .integer = 32 } },
            .{ .name = "angle_start", .type = .{ .number = .{ .min = -360, .max = 360, .unit = .degrees } }, .doc = "Sweep start", .default = .{ .number = 0 } },
            .{ .name = "angle_end", .type = .{ .number = .{ .min = -360, .max = 720, .unit = .degrees } }, .doc = "Sweep end; start + 360 closes it", .default = .{ .number = 360 } },
            .{ .name = "relief_count", .type = .{ .integer = .{ .min = 0, .max = 1024 } }, .doc = "Strips per full turn", .default = .{ .integer = 0 } },
            .{ .name = "relief_depth", .type = .{ .number = .{ .min = -10, .max = 10, .unit = .metres } }, .doc = "Strip height", .default = .{ .number = 0 } },
            .{ .name = "relief_groove", .type = .{ .number = .{ .min = 0, .max = 10, .unit = .metres } }, .doc = "Centre-line depth", .default = .{ .number = 0 } },
            .{ .name = "cap_start", .type = .boolean, .doc = "Fill the first ring", .default = .{ .boolean = false } },
            .{ .name = "cap_end", .type = .boolean, .doc = "Fill the last ring", .default = .{ .boolean = false } },
            .{ .name = "smooth", .type = .boolean, .doc = "Smooth shading", .default = .{ .boolean = true } },
            material_param,
            common.location,
            common.rotation,
            common.scale,
        }),
        .kind = .mutating,
        .handler = revolve,
    },
};

fn fromData(c: *Call) HandlerError!void {
    const a = c.args;
    const positions = try a.points(c.arena, "vertices");
    const faces = a.value("faces").?.array.items;
    const n_verts = positions.len;

    const offsets = try c.arena.alloc(u32, faces.len + 1);
    var corners: std.ArrayList(u32) = .empty;
    var triangles: u64 = 0;
    offsets[0] = 0;
    for (faces, 0..) |f, i| {
        const idx = f.array.items;
        const start = corners.items.len;
        for (idx, 0..) |x, k| {
            const vi: u64 = @intFromFloat(schema.number(x).?);
            if (vi >= n_verts) return c.failAt(.invalid_argument, try std.fmt.allocPrint(c.arena, "/faces/{d}/{d}", .{ i, k }), "indices count from 0", &.{}, "vertex index {d} is out of range: there are {d} vertices", .{ vi, n_verts });
            for (corners.items[start..]) |prev| if (prev == vi)
                return c.failAt(.invalid_argument, try std.fmt.allocPrint(c.arena, "/faces/{d}", .{i}), "a face lists each vertex once", &.{}, "face {d} repeats vertex {d}", .{ i, vi });
            try corners.append(c.arena, @intCast(vi));
        }
        offsets[i + 1] = @intCast(corners.items.len);
        triangles += idx.len - 2;
    }

    var uvs: [][2]f32 = &.{};
    if (a.value("uvs")) |u| {
        const items = u.array.items;
        if (items.len != corners.items.len) return c.failAt(.invalid_argument, "/uvs", "give one [u, v] per face corner, faces in order", &.{}, "uvs has {d} entries for {d} face corners", .{ items.len, corners.items.len });
        uvs = try c.arena.alloc([2]f32, items.len);
        for (items, uvs) |item, *o| o.* = .{ @floatCast(schema.number(item.array.items[0]).?), @floatCast(schema.number(item.array.items[1]).?) };
    }
    var mat_index: []i32 = &.{};
    if (a.value("material_index")) |mv| {
        const items = mv.array.items;
        if (items.len != faces.len) return c.failAt(.invalid_argument, "/material_index", "give one slot per face", &.{}, "material_index has {d} entries for {d} faces", .{ items.len, faces.len });
        mat_index = try c.arena.alloc(i32, items.len);
        for (items, mat_index) |x, *o| o.* = @intFromFloat(@min(schema.number(x).?, 255));
    }
    try c.spendTriangles(triangles);
    const sharp = try c.arena.alloc(bool, faces.len);
    @memset(sharp, !a.boolean("smooth").?);

    const gpa = c.doc().gpa;
    const mesh = geom.build.fromPolygons(gpa, .{
        .positions = positions,
        .face_offsets = offsets,
        .corner_verts = corners.items,
        .corner_uvs = uvs,
        .sharp_face = sharp,
        .material_index = mat_index,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return c.fail(.invalid_argument, "the faces do not form a valid mesh", .{}),
    };
    try addMeshObject(c, mesh, "Mesh");
}

fn revolve(c: *Call) HandlerError!void {
    const a = c.args;
    const items = a.value("profile").?.array.items;
    const profile = try c.arena.alloc([2]f32, items.len);
    for (items, profile) |item, *o| o.* = .{ @floatCast(schema.number(item.array.items[0]).?), @floatCast(schema.number(item.array.items[1]).?) };
    for (profile, 0..) |pt, k| {
        const end = k == 0 or k == profile.len - 1;
        if (pt[1] < 0 or (pt[1] == 0 and !end))
            return c.failAt(.invalid_argument, try std.fmt.allocPrint(c.arena, "/profile/{d}/1", .{k}), "radii are distances from the axis; only the first or last point may sit on it", &.{}, "profile point {d} has radius {d}", .{ k, pt[1] });
    }
    if (profile.len < 2) return c.failAt(.invalid_argument, "/profile", "give at least two [height, radius] points", &.{}, "the profile has {d} point", .{profile.len});
    const start = a.float("angle_start").?;
    const end = a.float("angle_end").?;
    if (!(end > start) or end - start > 360.0001) return c.failAt(.invalid_argument, "/angle_end", "angle_end must be above angle_start by at most 360", &.{}, "the sweep is {d} degrees", .{end - start});
    const segments: u32 = @intCast(a.int("segments").?);
    const relief: geom.revolve.Relief = .{
        .count = @intCast(a.int("relief_count").?),
        .depth = a.float("relief_depth").?,
        .groove = a.float("relief_groove").?,
    };
    // A strip needs a few columns to read as one.
    const sweep_frac = (end - start) / 360;
    if (relief.count > 0 and @as(f32, @floatFromInt(segments)) < 8 * @as(f32, @floatFromInt(relief.count)) * sweep_frac)
        try c.warn("{d} segments give fewer than 8 per strip; raise segments for clean flutes", .{segments});
    try c.spendTriangles(@as(u64, segments) * 2 * profile.len);

    const gpa = c.doc().gpa;
    const mesh = geom.revolve.revolve(gpa, .{
        .profile = profile,
        .segments = segments,
        .angle_start = math.vec.degToRad(start),
        .angle_end = math.vec.degToRad(end),
        .relief = relief,
        .cap_start = a.boolean("cap_start").?,
        .cap_end = a.boolean("cap_end").?,
        .smooth = a.boolean("smooth").?,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return c.fail(.invalid_argument, "invalid revolve parameters", .{}),
    };
    try addMeshObject(c, mesh, "Revolve");
}

/// Adds `mesh` (owned) as a new object with the call's name, placement and
/// material, and reports it.
fn addMeshObject(c: *Call, mesh_in: Mesh, default_name: []const u8) HandlerError!void {
    var mesh = mesh_in;
    const material: ?core.IdHandle = if (c.args.str("material")) |m| c.lookup(.material, m, "/material") catch |e| {
        mesh.releaseRefs(c.doc().gpa);
        return e;
    } else null;
    const doc = c.doc();
    const name = c.args.str("name") orelse default_name;
    const mh = doc.db.create(.mesh, name, mesh) catch |e| {
        mesh.releaseRefs(doc.gpa);
        return e;
    };
    const oh = core.edit.addObject(doc, name, .mesh, mh) catch return error.OutOfMemory;
    const ob = doc.db.get(.object, oh).?;
    common.applyPlacement(c, ob);
    if (material) |m| core.edit.assignMaterial(doc, oh, m, 0) catch return error.OutOfMemory;
    try c.markCreated(oh, ob.name.slice());
    try c.markCreated(mh, doc.db.get(.mesh, mh).?.name.slice());
    try c.field("object");
    try common.writeObjectSummary(c, &c.out, oh);
    const m = doc.db.get(.mesh, mh).?;
    try c.say("Added mesh '{s}' ({d} verts, {d} faces).", .{ ob.name.slice(), m.vertCount(), m.faceCount() });
}
