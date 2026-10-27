//! Parameters and helpers shared by tool handlers.

const std = @import("std");
const math = @import("math");
const engine = @import("engine");
const schema = @import("../schema.zig");
const server = @import("../server.zig");

const core = engine.core;
const v = math.vec;
const Param = schema.Param;
const Call = server.Call;
const HandlerError = server.HandlerError;
const IdHandle = core.IdHandle;

pub const scene_id: Param = .{
    .name = "scene_id",
    .type = .{ .string = .{ .max_len = 64 } },
    .doc = "From scene.create",
    .required = true,
    .header = "Scene",
};

pub const if_rev: Param = .{
    .name = "if_rev",
    .type = .{ .integer = .{ .min = 0 } },
    .doc = "Fail with rev_mismatch unless scene_rev equals this",
};

pub const location: Param = .{ .name = "location", .type = .{ .vec3 = .{ .min = -1e9, .max = 1e9, .unit = .metres } }, .doc = "Position [x, y, z], Z up", .default = .{ .vec3 = .{ 0, 0, 0 } } };
pub const rotation: Param = .{ .name = "rotation", .type = .{ .vec3 = .{ .min = -1e6, .max = 1e6, .unit = .degrees } }, .doc = "Euler XYZ rotation [x, y, z]", .default = .{ .vec3 = .{ 0, 0, 0 } } };
pub const scale: Param = .{ .name = "scale", .type = .{ .vec3 = .{ .min = -1e6, .max = 1e6 } }, .doc = "Scale factors [x, y, z]", .default = .{ .vec3 = .{ 1, 1, 1 } } };
pub const look_at: Param = .{ .name = "look_at", .type = .{ .vec3 = .{ .min = -1e9, .max = 1e9, .unit = .metres } }, .doc = "Point to aim at; overrides rotation" };
pub const name: Param = .{ .name = "name", .type = .{ .string = .{ .max_len = 255 } }, .doc = "Name; made unique with .001 suffixes if taken" };

/// Scene tools that mutate take scene_id, if_rev, then their own params.
pub fn mutating(comptime own: []const Param) []const Param {
    return &([_]Param{ scene_id, if_rev } ++ own[0..own.len].*);
}

pub fn reading(comptime own: []const Param) []const Param {
    return &([_]Param{scene_id} ++ own[0..own.len].*);
}

pub fn degVec(d: [3]f32) [3]f32 {
    return .{ v.degToRad(d[0]), v.degToRad(d[1]), v.degToRad(d[2]) };
}

pub fn radVecToDeg(r: [3]f32) [3]f64 {
    var out: [3]f64 = undefined;
    for (0..3) |i| out[i] = @round(@as(f64, r[i]) * (180.0 / std.math.pi) * 1e4) / 1e4;
    return out;
}

/// Applies location / rotation / scale / look_at arguments to a new object.
pub fn applyPlacement(c: *Call, ob: *core.types.Object) void {
    if (c.args.vec3("location")) |l| ob.location = l;
    if (c.args.vec3("rotation")) |r| ob.rotation_euler = degVec(r);
    if (c.args.vec3("scale")) |s| ob.scale = s;
    if (c.args.vec3("look_at")) |t| aimAt(ob, t);
}

/// Orients an object so its −Z axis points at `target` with +Y up as far
/// as possible: how Blender cameras and lights look along their view axis.
pub fn aimAt(ob: *core.types.Object, target: [3]f32) void {
    const dir = v.sub(target, ob.location);
    if (v.length(dir) < 1e-9) return;
    const q = v.lookRotation(dir, .{ 0, 0, 1 });
    ob.rotation_quaternion = q;
    if (ob.rotation_mode == .quaternion) return;
    ob.rotation_mode = .xyz;
    ob.rotation_euler = v.quatToEulerXyz(q);
}

pub fn writeVec(w: *std.json.Stringify, x: [3]f32) !void {
    try w.beginArray();
    for (x) |c| try core.registry.writeF32(w, c);
    try w.endArray();
}

pub fn writeVec64(w: *std.json.Stringify, x: [3]f64) !void {
    try w.beginArray();
    for (x) |c| try core.registry.writeF64(w, c);
    try w.endArray();
}

/// Bounds as {min, max, size, center}.
pub fn writeBounds(w: *std.json.Stringify, b: [2][3]f32) !void {
    try w.beginObject();
    try w.objectField("min");
    try writeVec(w, b[0]);
    try w.objectField("max");
    try writeVec(w, b[1]);
    try w.objectField("size");
    try writeVec(w, v.sub(b[1], b[0]));
    try w.objectField("center");
    try writeVec(w, v.scale(v.add(b[0], b[1]), 0.5));
    try w.endObject();
}

/// Compact object summary used by inspect outlines and creation results.
pub fn writeObjectSummary(c: *Call, w: *std.json.Stringify, h: IdHandle) HandlerError!void {
    const doc = c.doc();
    const ob = doc.db.get(.object, h).?;
    try w.beginObject();
    try w.objectField("name");
    try w.write(ob.name.slice());
    try w.objectField("type");
    try w.write(@tagName(ob.kind));
    try w.objectField("location");
    try writeVec(w, ob.location);
    try w.objectField("rotation");
    try writeVec64(w, radVecToDeg(if (ob.rotation_mode == .quaternion) v.quatToEulerXyz(ob.rotation_quaternion) else ob.rotation_euler));
    try w.objectField("scale");
    try writeVec(w, ob.scale);
    if (ob.parent) |p| if (doc.db.get(.object, p)) |po| {
        try w.objectField("parent");
        try w.write(po.name.slice());
    };
    if (ob.data) |d| {
        try w.objectField("data");
        switch (ob.kind) {
            .mesh => if (doc.db.get(.mesh, d)) |m| {
                try w.write(m.name.slice());
                try w.objectField("faces");
                try w.write(m.faceCount());
                try w.objectField("triangles");
                try w.write(m.triangleCount());
                const mats = m.materials.slice();
                if (mats.len > 0) {
                    try w.objectField("materials");
                    try w.beginArray();
                    for (mats) |mh| {
                        if (mh) |x| if (doc.db.get(.material, x)) |mat| {
                            try w.write(mat.name.slice());
                            continue;
                        };
                        try w.write(null);
                    }
                    try w.endArray();
                }
            } else try w.write(null),
            .camera => try w.write(if (doc.db.get(.camera, d)) |x| x.name.slice() else ""),
            .light => if (doc.db.get(.light, d)) |x| {
                try w.write(x.name.slice());
                try w.objectField("light_type");
                try w.write(@tagName(x.type));
            } else try w.write(null),
            .empty => try w.write(null),
        }
    }
    if (ob.hide_render) {
        try w.objectField("hide_render");
        try w.write(true);
    }
    if (try engine.eval.flatten.objectBounds(doc, h)) |b| {
        if (ob.kind == .mesh) {
            try w.objectField("bounds");
            try writeBounds(w, b);
        }
    }
    try w.endObject();
}

/// Compact collection summary: name, parent, the objects linked directly
/// into it, and its hide flags when set.
pub fn writeCollectionSummary(c: *Call, w: *std.json.Stringify, h: IdHandle) HandlerError!void {
    const db = &c.doc().db;
    const coll = db.get(.collection, h).?;
    try w.beginObject();
    try w.objectField("name");
    try w.write(coll.name.slice());
    if (core.edit.collectionParent(db, h)) |p| {
        try w.objectField("parent");
        try w.write(db.get(.collection, p).?.name.slice());
    }
    try w.objectField("objects");
    try w.beginArray();
    for (coll.objects.slice()) |o| if (db.get(.object, o)) |ob| try w.write(ob.name.slice());
    try w.endArray();
    if (coll.hide_render) {
        try w.objectField("hide_render");
        try w.write(true);
    }
    if (coll.hide_viewport) {
        try w.objectField("hide_viewport");
        try w.write(true);
    }
    try w.endObject();
}

/// Every collection from the master down, parents before children.
pub fn writeCollectionTree(c: *Call, w: *std.json.Stringify) HandlerError!void {
    try w.beginArray();
    if (c.doc().sceneData().collection) |root| try writeSubtree(c, w, root, 0);
    try w.endArray();
}

fn writeSubtree(c: *Call, w: *std.json.Stringify, h: IdHandle, depth: u32) HandlerError!void {
    if (depth > 64) return;
    const coll = c.doc().db.get(.collection, h) orelse return;
    try writeCollectionSummary(c, w, h);
    for (coll.children.slice()) |child| try writeSubtree(c, w, child, depth + 1);
}

/// Applies a `properties` object to a datablock through the registry,
/// stopping at the first invalid entry.
pub fn setProperties(c: *Call, comptime T: type, target: *T, props: std.json.Value, arg_name: []const u8) HandlerError!usize {
    var n: usize = 0;
    var it = props.object.iterator();
    while (it.next()) |kv| {
        var diag: core.registry.Diag = .{};
        core.registry.set(T, target, kv.key_ptr.*, kv.value_ptr.*, &diag, c.arena) catch {
            const path = try std.fmt.allocPrint(c.arena, "/{s}/{s}", .{ arg_name, kv.key_ptr.* });
            return c.failAt(.invalid_argument, path, if (diag.hint.len > 0) diag.hint else "see schema.describe for names, units and ranges", diag.valid_values, "{s}.{s}: {s}", .{ arg_name, kv.key_ptr.*, diag.message });
        };
        n += 1;
    }
    return n;
}
