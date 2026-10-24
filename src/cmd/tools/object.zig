//! object.* tools.

const std = @import("std");
const math = @import("math");
const engine = @import("engine");
const server = @import("../server.zig");
const schema = @import("../schema.zig");
const common = @import("common.zig");

const core = engine.core;
const prims = engine.geom.primitives;
const Call = server.Call;
const Tool = server.Tool;
const HandlerError = server.HandlerError;
const v = math.vec;

const kinds = [_][]const u8{ "cube", "plane", "grid", "uv_sphere", "ico_sphere", "cylinder", "cone", "torus" };

fn writeObjectPropsSchema(w: *std.json.Stringify) std.json.Stringify.Error!void {
    try core.registry.writeSchema(core.types.Object, w);
}

pub const tools = [_]Tool{
    .{
        .name = "object.add_primitive",
        .title = "Add primitive",
        .description = "Create a mesh object from a primitive with Blender's defaults: cube/plane/grid size 2 m (edge length), spheres radius 1 m, cylinder and cone 32 segments, depth 2 m, centred on its origin. Z is up. Faces are flat unless smooth is true. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"kind\":\"cube\",\"name\":\"Table Top\",\"size\":1,\"location\":[0,0,0.75],\"scale\":[1.2,0.8,0.04]}.",
        .params = common.mutating(&.{
            .{ .name = "kind", .type = .{ .enumeration = &kinds }, .doc = "Primitive type", .required = true },
            common.name,
            .{ .name = "size", .type = .{ .number = .{ .min = 1e-6, .max = 1e6, .unit = .metres } }, .doc = "Edge length (cube, plane, grid)", .default = .{ .number = 2 } },
            .{ .name = "radius", .type = .{ .number = .{ .min = 1e-6, .max = 1e6, .unit = .metres } }, .doc = "Radius (spheres, cylinder, cone base)", .default = .{ .number = 1 } },
            .{ .name = "radius_top", .type = .{ .number = .{ .min = 0, .max = 1e6, .unit = .metres } }, .doc = "Cone tip radius; 0 = pointed", .default = .{ .number = 0 } },
            .{ .name = "depth", .type = .{ .number = .{ .min = 1e-6, .max = 1e6, .unit = .metres } }, .doc = "Height along Z (cylinder, cone)", .default = .{ .number = 2 } },
            .{ .name = "segments", .type = .{ .integer = .{ .min = 3, .max = prims.limits.max_segments } }, .doc = "Segments around Z (uv_sphere, cylinder, cone)", .default = .{ .integer = 32 } },
            .{ .name = "rings", .type = .{ .integer = .{ .min = 3, .max = prims.limits.max_segments } }, .doc = "Rings pole to pole (uv_sphere)", .default = .{ .integer = 16 } },
            .{ .name = "subdivisions", .type = .{ .integer = .{ .min = 1, .max = prims.limits.max_subdivisions } }, .doc = "Subdivisions (ico_sphere; 1 = icosahedron)", .default = .{ .integer = 2 } },
            .{ .name = "grid_subdivisions", .type = .{ .integer = .{ .min = 1, .max = prims.limits.max_grid } }, .doc = "Faces per side (grid)", .default = .{ .integer = 10 } },
            .{ .name = "major_radius", .type = .{ .number = .{ .min = 1e-6, .max = 1e6, .unit = .metres } }, .doc = "Torus ring radius", .default = .{ .number = 1 } },
            .{ .name = "minor_radius", .type = .{ .number = .{ .min = 1e-6, .max = 1e6, .unit = .metres } }, .doc = "Torus tube radius", .default = .{ .number = 0.25 } },
            .{ .name = "fill_caps", .type = .boolean, .doc = "Close cylinder and cone ends with n-gons", .default = .{ .boolean = true } },
            .{ .name = "smooth", .type = .boolean, .doc = "Smooth shading", .default = .{ .boolean = false } },
            .{ .name = "material", .type = .{ .name_ref = .{} }, .doc = "Material to assign to slot 0" },
            common.location,
            common.rotation,
            common.scale,
        }),
        .kind = .mutating,
        .handler = addPrimitive,
    },
    .{
        .name = "object.duplicate",
        .title = "Duplicate object",
        .description = "Copy an object. linked=false copies its data (Blender Shift+D); linked=true shares it (Alt+D). offset moves the copy in metres. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"object\":\"Leg\",\"name\":\"Leg\",\"offset\":[1,0,0]}.",
        .params = common.mutating(&.{
            .{ .name = "object", .type = .{ .name_ref = .{} }, .doc = "Object to copy", .required = true },
            common.name,
            .{ .name = "linked", .type = .boolean, .doc = "Share the data block instead of copying it", .default = .{ .boolean = false } },
            .{ .name = "offset", .type = .{ .vec3 = .{ .min = -1e9, .max = 1e9, .unit = .metres } }, .doc = "Added to the copy's location", .default = .{ .vec3 = .{ 0, 0, 0 } } },
        }),
        .kind = .mutating,
        .handler = duplicate,
    },
    .{
        .name = "object.delete",
        .title = "Delete objects",
        .description = "Delete objects. Children keep their world transform and lose the parent. Deleting more than 10 objects needs confirm: true. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"objects\":[\"Cube\"]}.",
        .params = common.mutating(&.{
            .{ .name = "objects", .type = .{ .string_list = .{} }, .doc = "Names of objects to delete", .required = true },
            .{ .name = "confirm", .type = .boolean, .doc = "Required when deleting more than 10 objects", .default = .{ .boolean = false } },
        }),
        .kind = .mutating,
        .destructive = true,
        .handler = delete,
    },
    .{
        .name = "object.transform",
        .title = "Transform object",
        .description = "Set (mode 'set') or add to (mode 'add') an object's location (m), Euler XYZ rotation (deg) and scale; omitted fields stay. Rotation applies X, then Y, then Z about the parent axes. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"object\":\"Cube\",\"location\":[0,0,1],\"rotation\":[0,0,45]}.",
        .params = common.mutating(&.{
            .{ .name = "object", .type = .{ .name_ref = .{} }, .doc = "Object to move", .required = true },
            .{ .name = "location", .type = .{ .vec3 = .{ .min = -1e9, .max = 1e9, .unit = .metres } }, .doc = "Location [x, y, z]" },
            .{ .name = "rotation", .type = .{ .vec3 = .{ .min = -1e6, .max = 1e6, .unit = .degrees } }, .doc = "Euler XYZ rotation [x, y, z]" },
            .{ .name = "scale", .type = .{ .vec3 = .{ .min = -1e6, .max = 1e6 } }, .doc = "Scale [x, y, z]" },
            .{ .name = "mode", .type = .{ .enumeration = &.{ "set", "add" } }, .doc = "set replaces; add offsets location and rotation and multiplies scale", .default = .{ .string = "set" } },
        }),
        .kind = .mutating,
        .handler = transform,
    },
    .{
        .name = "object.set_parent",
        .title = "Set parent",
        .description = "Parent an object to another (parent null clears it). keep_transform keeps the world position, like Blender's 'Object (Keep Transform)'. Cycles are rejected. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"object\":\"Leg\",\"parent\":\"Table Top\"}.",
        .params = common.mutating(&.{
            .{ .name = "object", .type = .{ .name_ref = .{} }, .doc = "Child object", .required = true },
            .{ .name = "parent", .type = .{ .name_ref = .{ .nullable = true } }, .doc = "New parent, or null to clear", .required = true },
            .{ .name = "keep_transform", .type = .boolean, .doc = "Keep the child's world transform", .default = .{ .boolean = true } },
        }),
        .kind = .mutating,
        .handler = setParent,
    },
    .{
        .name = "object.set_properties",
        .title = "Set properties",
        .description = "Rename an object or set registry properties on it ('properties') and on its camera or light data ('data'); see schema.describe for names, units and ranges. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"object\":\"Camera\",\"data\":{\"lens\":35},\"properties\":{\"hide_render\":false}}.",
        .params = common.mutating(&.{
            .{ .name = "object", .type = .{ .name_ref = .{} }, .doc = "Object to change", .required = true },
            .{ .name = "rename", .type = .{ .string = .{ .max_len = 255 } }, .doc = "New object name" },
            .{ .name = "properties", .type = .{ .properties = writeObjectPropsSchema }, .doc = "Object properties" },
            .{ .name = "data", .type = .{ .properties = writeDataPropsSchema }, .doc = "Camera or light data properties" },
        }),
        .kind = .mutating,
        .handler = setProperties,
    },
};

fn writeDataPropsSchema(w: *std.json.Stringify) std.json.Stringify.Error!void {
    try w.beginObject();
    try w.objectField("type");
    try w.write("object");
    try w.objectField("description");
    try w.write("Camera properties (lens mm, sensor_width mm, clip_start m, clip_end m, type, ortho_scale m, shift) or light properties (type, color, energy W, radius m, spot_size deg, spot_blend, size m); see schema.describe camera / light");
    try w.endObject();
}

fn primitiveTriangles(kind: prims.Kind, p: prims.Params) u64 {
    return switch (kind) {
        .cube => 12,
        .plane => 2,
        .grid => 2 * @as(u64, p.x_subdivisions) * p.y_subdivisions,
        .uv_sphere => 2 * @as(u64, p.segments) * (p.rings - 1),
        .ico_sphere => 20 * std.math.pow(u64, 4, p.subdivisions - 1),
        .cylinder => 4 * @as(u64, p.segments),
        .cone => 3 * @as(u64, p.segments),
        .torus => 2 * @as(u64, p.major_segments) * p.minor_segments,
    };
}

fn addPrimitive(c: *Call) HandlerError!void {
    const a = c.args;
    const kind = std.meta.stringToEnum(prims.Kind, a.str("kind").?).?;
    const grid_n: u32 = @intCast(a.int("grid_subdivisions").?);
    const p: prims.Params = .{
        .size = a.float("size").?,
        .radius = a.float("radius").?,
        .radius_top = a.float("radius_top").?,
        .depth = a.float("depth").?,
        .segments = @intCast(a.int("segments").?),
        .rings = @intCast(a.int("rings").?),
        .subdivisions = @intCast(a.int("subdivisions").?),
        .x_subdivisions = grid_n,
        .y_subdivisions = grid_n,
        .major_radius = a.float("major_radius").?,
        .minor_radius = a.float("minor_radius").?,
        .fill_caps = a.boolean("fill_caps").?,
        .smooth = a.boolean("smooth").?,
    };
    try c.spendTriangles(primitiveTriangles(kind, p));
    const material: ?core.IdHandle = if (a.str("material")) |m| try c.lookup(.material, m, "/material") else null;

    const doc = c.doc();
    const gpa = doc.gpa;
    var mesh = prims.generate(gpa, kind, p) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return c.fail(.invalid_argument, "invalid {s} parameters", .{@tagName(kind)}),
    };
    const default_name = defaultName(kind);
    const name = a.str("name") orelse default_name;
    const mh = doc.db.create(.mesh, name, mesh) catch |e| {
        mesh.releaseRefs(gpa);
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
    try c.say("Added {s} '{s}' ({d} verts, {d} faces) at [{d:.3}, {d:.3}, {d:.3}].", .{ @tagName(kind), ob.name.slice(), m.vertCount(), m.faceCount(), ob.location[0], ob.location[1], ob.location[2] });
}

fn defaultName(kind: prims.Kind) []const u8 {
    return switch (kind) {
        .cube => "Cube",
        .plane => "Plane",
        .grid => "Grid",
        .uv_sphere => "Sphere",
        .ico_sphere => "Icosphere",
        .cylinder => "Cylinder",
        .cone => "Cone",
        .torus => "Torus",
    };
}

fn duplicate(c: *Call) HandlerError!void {
    const src = try c.object("object");
    const doc = c.doc();
    const src_name = try c.arena.dupe(u8, doc.db.get(.object, src).?.name.slice());
    if (doc.db.get(.object, src).?.kind == .mesh) {
        if (doc.db.get(.object, src).?.data) |d| try c.spendTriangles(doc.db.get(.mesh, d).?.triangleCount());
    }
    const name = c.args.str("name") orelse src_name;
    const h = core.edit.duplicateObject(doc, src, name, c.args.boolean("linked").?) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return c.fail(.stale_handle, "object vanished during duplication", .{}),
    };
    const ob = doc.db.get(.object, h).?;
    ob.location = v.add(ob.location, c.args.vec3("offset").?);
    try c.markCreated(h, ob.name.slice());
    if (ob.data) |d| if (!c.args.boolean("linked").?) {
        const data_name = switch (ob.kind) {
            .mesh => doc.db.get(.mesh, d).?.name.slice(),
            .camera => doc.db.get(.camera, d).?.name.slice(),
            .light => doc.db.get(.light, d).?.name.slice(),
            .empty => "",
        };
        try c.markCreated(d, data_name);
    };
    try c.field("object");
    try common.writeObjectSummary(c, &c.out, h);
    try c.say("Duplicated '{s}' as '{s}'{s}.", .{ src_name, ob.name.slice(), if (c.args.boolean("linked").?) " (linked data)" else "" });
}

fn delete(c: *Call) HandlerError!void {
    const names = c.args.strings("objects");
    const budgets = c.server.config.budgets;
    if (names.len > budgets.delete_confirm_over and !c.args.boolean("confirm").?) {
        return c.failAt(.confirmation_required, "/confirm", "pass confirm: true to delete this many objects", &.{}, "deleting {d} objects needs confirmation", .{names.len});
    }
    const doc = c.doc();
    var handles: std.ArrayList(core.IdHandle) = .empty;
    for (names, 0..) |n, i| {
        const h = try c.lookup(.object, n.string, try std.fmt.allocPrint(c.arena, "/objects/{d}", .{i}));
        try handles.append(c.arena, h);
    }
    for (handles.items) |h| {
        const ob = doc.db.get(.object, h) orelse continue; // listed twice
        const name = try c.arena.dupe(u8, ob.name.slice());
        var it = doc.db.object.iterator();
        while (it.next()) |e| if (e.value.parent) |p| if (p.eql(h)) try c.markChanged(e.handle, e.value.name.slice());
        core.edit.deleteObject(doc, h) catch return error.OutOfMemory;
        try c.markChanged(h, name);
    }
    try c.field("deleted");
    try c.out.write(handles.items.len);
    try c.say("Deleted {d} object(s).", .{handles.items.len});
}

fn transform(c: *Call) HandlerError!void {
    const h = try c.object("object");
    const ob = c.doc().db.get(.object, h).?;
    const add = std.mem.eql(u8, c.args.str("mode").?, "add");
    if (c.args.vec3("location")) |l| ob.location = if (add) v.add(ob.location, l) else l;
    if (c.args.vec3("rotation")) |r| {
        const rad = common.degVec(r);
        if (ob.rotation_mode == .quaternion) {
            const q = v.eulerToQuat(rad, .xyz);
            ob.rotation_quaternion = if (add) v.quatNormalize(v.quatMul(q, ob.rotation_quaternion)) else q;
        } else {
            ob.rotation_euler = if (add) v.add(ob.rotation_euler, rad) else rad;
        }
    }
    if (c.args.vec3("scale")) |s| ob.scale = if (add) v.mul(ob.scale, s) else s;
    if (!c.args.has("location") and !c.args.has("rotation") and !c.args.has("scale")) {
        try c.warn("no location, rotation or scale given; nothing changed", .{});
    }
    try c.markChanged(h, ob.name.slice());
    try c.field("object");
    try common.writeObjectSummary(c, &c.out, h);
    try c.say("Moved '{s}' to [{d:.3}, {d:.3}, {d:.3}].", .{ ob.name.slice(), ob.location[0], ob.location[1], ob.location[2] });
}

fn setParent(c: *Call) HandlerError!void {
    const child = try c.object("object");
    const parent: ?core.IdHandle = if (c.args.str("parent")) |p| try c.lookup(.object, p, "/parent") else null;
    const doc = c.doc();
    core.edit.setParent(doc, child, parent, c.args.boolean("keep_transform").?) catch |e| switch (e) {
        error.ParentCycle => return c.failAt(.invalid_operation, "/parent", "an object cannot be parented to itself or its own descendant", &.{}, "parenting would create a cycle", .{}),
        error.OutOfMemory => return error.OutOfMemory,
        else => return c.fail(.stale_handle, "object vanished", .{}),
    };
    const ob = doc.db.get(.object, child).?;
    try c.markChanged(child, ob.name.slice());
    if (parent) |p| {
        try c.say("Parented '{s}' to '{s}'.", .{ ob.name.slice(), doc.db.get(.object, p).?.name.slice() });
    } else {
        try c.say("Cleared the parent of '{s}'.", .{ob.name.slice()});
    }
}

fn setProperties(c: *Call) HandlerError!void {
    const h = try c.object("object");
    const doc = c.doc();
    const ob = doc.db.get(.object, h).?;
    var n: usize = 0;
    if (c.args.value("properties")) |p| n += try common.setProperties(c, core.types.Object, ob, p, "properties");
    if (c.args.value("data")) |p| {
        const d = ob.data orelse return c.failAt(.invalid_argument, "/data", "only camera and light objects have data properties", &.{}, "'{s}' has no data", .{ob.name.slice()});
        switch (ob.kind) {
            .camera => n += try common.setProperties(c, core.types.Camera, doc.db.get(.camera, d).?, p, "data"),
            .light => n += try common.setProperties(c, core.types.Light, doc.db.get(.light, d).?, p, "data"),
            else => return c.failAt(.invalid_argument, "/data", "mesh data is edited with mesh.* and material.* tools", &.{}, "'{s}' is a {s}; data properties apply to cameras and lights", .{ ob.name.slice(), @tagName(ob.kind) }),
        }
        if (ob.kind == .camera) {
            const cam = doc.db.get(.camera, d).?;
            if (cam.clip_end <= cam.clip_start) return c.failAt(.invalid_argument, "/data/clip_end", "", &.{}, "clip_end must be greater than clip_start", .{});
        }
    }
    if (c.args.str("rename")) |new_name| {
        const got = doc.db.rename(.object, h, new_name).?;
        if (!got.eql(new_name)) try c.warn("name '{s}' was taken; renamed to '{s}'", .{ new_name, got.slice() });
        n += 1;
    }
    try c.markChanged(h, ob.name.slice());
    try c.field("object");
    try common.writeObjectSummary(c, &c.out, h);
    try c.say("Set {d} value(s) on '{s}'.", .{ n, ob.name.slice() });
}
