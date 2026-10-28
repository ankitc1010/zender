//! Tools that build a new mesh object from data rather than a primitive:
//! mesh.from_data, mesh.revolve and mesh.from_sdf.

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
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const sdf = geom.sdf;
const shading = @import("shading.zig");

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
            .{ .name = "relief_texture", .type = .{ .properties = writeObjectSchema }, .doc = "Recipe (as material.create) offsetting radii by relief_depth x (value - 0.5), instead of strips" },
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
    .{
        .name = "mesh.from_sdf",
        .title = "Mesh from SDF",
        .description = "Model with blended shapes, meshed in one call (smooth organic forms: heads, hair, armour). steps run in order; each {op: add|subtract|intersect, blend: smooth radius m (0 = hard), offset: grow m, slot: material slot (a hard border along the voxel faces), color: scene-linear [r, g, b] that fades across the blend like the surfaces do (once any step has one, steps without paint the tool's color; for smooth colour borders give the object one material with base_color {attribute: \"Color\"}), color_blend: fade width m instead (0 = crisp, about a voxel), displace {amount m, texture: a material.create recipe}, and shape or steps (a group)}. shape {type, location, rotation (deg), scale (uniform), mirror_x} plus: sphere radius; ellipsoid radii [x,y,z]; box size [x,y,z], round; capsule a, b, radius or radii [ra, rb]; torus major_radius, minor_radius, stretch [sx, sy]; cylinder radius, depth (along Z); half_space normal (removes nothing on its own; everything below the plane through location); chain points [[x,y,z]...], radius or radii per point (tubes, locks of hair). voxel_size sets detail: cells = volume / voxel_size^3, at most 64M. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"name\":\"Pebble\",\"voxel_size\":0.01,\"steps\":[{\"shape\":{\"type\":\"ellipsoid\",\"radii\":[0.3,0.2,0.12]}},{\"blend\":0.05,\"shape\":{\"type\":\"capsule\",\"a\":[0,0,0.1],\"b\":[0,0,0.3],\"radius\":0.04}},{\"op\":\"subtract\",\"blend\":0.02,\"shape\":{\"type\":\"sphere\",\"radius\":0.08,\"location\":[0.2,0,0.1]}}]}.",
        .params = common.mutating(&.{
            common.name,
            .{ .name = "steps", .type = .{ .objects = .{ .max_items = 4096 } }, .doc = "Shapes and groups, in order", .required = true },
            .{ .name = "voxel_size", .type = .{ .number = .{ .min = 0.0001, .max = 100, .unit = .metres } }, .doc = "Grid spacing", .default = .{ .number = 0.02 } },
            .{ .name = "bounds_min", .type = .{ .vec3 = .{ .min = -1e6, .max = 1e6, .unit = .metres } }, .doc = "Sampled box; default: the added shapes" },
            .{ .name = "bounds_max", .type = .{ .vec3 = .{ .min = -1e6, .max = 1e6, .unit = .metres } }, .doc = "Sampled box" },
            .{ .name = "smooth_iterations", .type = .{ .integer = .{ .min = 0, .max = 50 } }, .doc = "Volume-keeping smoothing passes", .default = .{ .integer = 0 } },
            .{ .name = "color_attribute", .type = .{ .string = .{ .max_len = 64 } }, .doc = "Point colour attribute the step colours go to", .default = .{ .string = "Color" } },
            .{ .name = "color", .type = .color, .doc = "With step colours: the colour of steps without one (as slot 0 is for slots); default white" },
            material_param,
            common.location,
            common.rotation,
            common.scale,
        }),
        .kind = .mutating,
        .handler = fromSdf,
    },
};

fn writeObjectSchema(w: *std.json.Stringify) std.json.Stringify.Error!void {
    try w.beginObject();
    try w.objectField("type");
    try w.write("object");
    try w.endObject();
}

pub const max_shapes = 20_000;
pub const max_chain_points = 200_000;
const max_depth = 8;

fn fromSdf(c: *Call) HandlerError!void {
    const a = c.args;
    var parser: Parser = .{ .c = c };
    const steps = try parser.steps(a.value("steps").?.array.items, "/steps", 0);
    const lo = a.vec3("bounds_min");
    const hi = a.vec3("bounds_max");
    if ((lo == null) != (hi == null)) return c.failAt(.invalid_argument, if (lo == null) "/bounds_min" else "/bounds_max", "give both bounds or neither", &.{}, "only one bound is set", .{});
    if (lo != null) for (0..3) |k| if (!(hi.?[k] > lo.?[k]))
        return c.failAt(.invalid_argument, "/bounds_max", "", &.{}, "bounds_max must exceed bounds_min on every axis", .{});
    const gpa = c.doc().gpa;
    var mesh = sdf.mesh(gpa, steps, .{
        .voxel = a.float("voxel_size").?,
        .bounds = if (lo) |l| .{ l, hi.? } else null,
        .smooth_iterations = @intCast(a.int("smooth_iterations").?),
        .color_attribute = a.str("color_attribute").?,
        .base_color = if (a.color("color")) |x| x[0..3].* else .{ 1, 1, 1 },
        .pool = c.server.pool,
    }) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.DeadlineExceeded => error.ToolFailed,
        error.TooManyCells => c.failAt(.invalid_argument, "/voxel_size", "raise voxel_size, or set bounds_min/bounds_max to the part that matters", &.{}, "the grid would exceed 64M cells", .{}),
        error.Unbounded => c.failAt(.invalid_argument, "/steps", "a half_space is infinite: add it with bounds_min/bounds_max, or subtract it from a bounded shape", &.{}, "an added shape has no bounds", .{}),
        error.Empty => c.failAt(.invalid_argument, "/steps", "check that something is added inside the bounds and that subtractions leave a solid", &.{}, "the program has no surface", .{}),
        else => c.fail(.invalid_argument, "invalid SDF program", .{}),
    };
    c.spendTriangles(2 * @as(u64, mesh.faceCount())) catch |e| {
        mesh.releaseRefs(gpa);
        return e;
    };
    try addMeshObject(c, mesh, "SDF");
}

/// Reads the step program, reporting the JSON path of the first problem.
const Parser = struct {
    c: *Call,
    shapes: usize = 0,
    points: usize = 0,

    fn at(p: *Parser, path: []const u8, key: []const u8) HandlerError![]const u8 {
        return std.fmt.allocPrint(p.c.arena, "{s}/{s}", .{ path, key });
    }

    fn bad(p: *Parser, path: []const u8, hint: []const u8, comptime fmt: []const u8, args: anytype) HandlerError {
        return p.c.failAt(.invalid_argument, path, hint, &.{}, fmt, args);
    }

    fn steps(p: *Parser, arr: []const Value, path: []const u8, depth: u32) HandlerError![]sdf.Step {
        if (depth > max_depth) return p.bad(path, "flatten the program", "groups nest more than {d} deep", .{max_depth});
        if (arr.len == 0) return p.bad(path, "", "a step list needs at least one step", .{});
        const out = try p.c.arena.alloc(sdf.Step, arr.len);
        for (arr, out, 0..) |item, *o, i| {
            const sp = try std.fmt.allocPrint(p.c.arena, "{s}/{d}", .{ path, i });
            if (item != .object) return p.bad(sp, "", "a step must be an object", .{});
            o.* = try p.step(item.object, sp, depth);
        }
        return out;
    }

    fn step(p: *Parser, o: ObjectMap, path: []const u8, depth: u32) HandlerError!sdf.Step {
        try p.onlyKeys(o, path, &.{ "op", "blend", "offset", "slot", "color", "color_blend", "shape", "steps", "displace" });
        var st: sdf.Step = .{ .body = undefined };
        if (o.get("op")) |op| {
            st.op = (if (op == .string) std.meta.stringToEnum(sdf.Op, op.string) else null) orelse
                return p.c.failAt(.invalid_argument, try p.at(path, "op"), "", &.{ "add", "subtract", "intersect" }, "unknown op", .{});
        }
        st.blend = try p.num(o, "blend", path, 0, 0, 100);
        st.offset = try p.num(o, "offset", path, 0, -100, 100);
        if (o.get("slot") != null) st.slot = @intFromFloat(try p.num(o, "slot", path, 0, 0, 255));
        if (o.get("color")) |cv| {
            const cp = try p.at(path, "color");
            const items = if (cv == .array and cv.array.items.len == 3) cv.array.items else return p.bad(cp, "", "expected [r, g, b], scene-linear 0..1", .{});
            var col: [3]f32 = undefined;
            for (items, &col) |x, *ch| {
                const f = schema.number(x) orelse return p.bad(cp, "", "expected numbers", .{});
                if (!(f >= 0 and f <= 1)) return p.bad(cp, "", "colour channels must be within 0 to 1", .{});
                ch.* = @floatCast(f);
            }
            st.color = col;
        }
        if (o.get("color_blend") != null) st.color_blend = try p.num(o, "color_blend", path, null, 0, 100);
        if (o.get("displace")) |dv| {
            const dp = try p.at(path, "displace");
            if (dv != .object) return p.bad(dp, "", "'displace' must be {{amount, texture}}", .{});
            try p.onlyKeys(dv.object, dp, &.{ "amount", "texture" });
            st.displace_amount = try p.num(dv.object, "amount", dp, null, -10, 10);
            const tv = dv.object.get("texture") orelse return p.bad(try p.at(dp, "texture"), "", "missing 'texture' (a material.create recipe)", .{});
            if (tv != .object) return p.bad(try p.at(dp, "texture"), "", "'texture' must be a recipe object", .{});
            const r = try p.c.arena.create(math.texture.Recipe);
            r.* = try shading.parseRecipe(p.c, tv.object, try p.at(dp, "texture"));
            st.displace = r;
        }
        const shape_v = o.get("shape");
        const group = o.get("steps");
        if ((shape_v == null) == (group == null)) return p.bad(path, "a step holds either a shape or a group of steps", "need exactly one of 'shape' and 'steps'", .{});
        if (shape_v) |s| {
            if (s != .object) return p.bad(try p.at(path, "shape"), "", "'shape' must be an object", .{});
            st.body = .{ .shape = try p.shape(s.object, try p.at(path, "shape")) };
        } else {
            const g = group.?;
            if (g != .array) return p.bad(try p.at(path, "steps"), "", "'steps' must be a list", .{});
            st.body = .{ .group = try p.steps(g.array.items, try p.at(path, "steps"), depth + 1) };
        }
        return st;
    }

    const common_keys = [_][]const u8{ "type", "location", "rotation", "scale", "mirror_x" };

    fn shape(p: *Parser, o: ObjectMap, path: []const u8) HandlerError!sdf.Shape {
        p.shapes += 1;
        if (p.shapes > max_shapes) return p.bad(path, "merge small shapes into chains", "more than {d} shapes", .{max_shapes});
        const names = std.meta.fieldNames(sdf.Kind);
        const tv = o.get("type") orelse return p.c.failAt(.invalid_argument, try p.at(path, "type"), "", names, "missing 'type'", .{});
        const kind_tag = (if (tv == .string) std.meta.stringToEnum(std.meta.Tag(sdf.Kind), tv.string) else null) orelse
            return p.c.failAt(.invalid_argument, try p.at(path, "type"), "", names, "unknown shape type", .{});
        var s: sdf.Shape = .{ .kind = undefined };
        s.location = try p.vec(o, "location", path, .{ 0, 0, 0 });
        const r = try p.vec(o, "rotation", path, .{ 0, 0, 0 });
        s.rotation = .{ math.vec.degToRad(r[0]), math.vec.degToRad(r[1]), math.vec.degToRad(r[2]) };
        s.scale = try p.num(o, "scale", path, 1, 1e-6, 1e6);
        if (o.get("mirror_x")) |m| s.mirror_x = m == .bool and m.bool;
        switch (kind_tag) {
            .sphere => {
                try p.onlyKeys(o, path, &(common_keys ++ .{"radius"}));
                s.kind = .{ .sphere = .{ .radius = try p.num(o, "radius", path, null, 1e-6, 1e6) } };
            },
            .ellipsoid => {
                try p.onlyKeys(o, path, &(common_keys ++ .{"radii"}));
                s.kind = .{ .ellipsoid = .{ .radii = try p.positiveVec(o, "radii", path) } };
            },
            .box => {
                try p.onlyKeys(o, path, &(common_keys ++ .{ "size", "round" }));
                s.kind = .{ .box = .{ .half = math.vec.scale(try p.positiveVec(o, "size", path), 0.5), .round = try p.num(o, "round", path, 0, 0, 1e6) } };
            },
            .capsule => {
                try p.onlyKeys(o, path, &(common_keys ++ .{ "a", "b", "radius", "radii" }));
                const ab = try p.pairRadii(o, path);
                s.kind = .{ .capsule = .{ .a = try p.vec(o, "a", path, null), .b = try p.vec(o, "b", path, null), .ra = ab[0], .rb = ab[1] } };
            },
            .torus => {
                try p.onlyKeys(o, path, &(common_keys ++ .{ "major_radius", "minor_radius", "stretch" }));
                var st: [2]f32 = .{ 1, 1 };
                if (o.get("stretch")) |sv| {
                    const items = if (sv == .array and sv.array.items.len == 2) sv.array.items else return p.bad(try p.at(path, "stretch"), "", "'stretch' must be [sx, sy]", .{});
                    for (items, 0..) |x, k| st[k] = @floatCast(schema.number(x) orelse return p.bad(try p.at(path, "stretch"), "", "'stretch' must hold numbers", .{}));
                    if (!(st[0] > 0 and st[1] > 0)) return p.bad(try p.at(path, "stretch"), "", "'stretch' must be positive", .{});
                }
                s.kind = .{ .torus = .{ .major = try p.num(o, "major_radius", path, null, 0, 1e6), .minor = try p.num(o, "minor_radius", path, null, 1e-6, 1e6), .sx = st[0], .sy = st[1] } };
            },
            .cylinder => {
                try p.onlyKeys(o, path, &(common_keys ++ .{ "radius", "depth" }));
                s.kind = .{ .cylinder = .{ .radius = try p.num(o, "radius", path, null, 1e-6, 1e6), .half_height = try p.num(o, "depth", path, null, 1e-6, 1e6) / 2 } };
            },
            .half_space => {
                try p.onlyKeys(o, path, &(common_keys ++ .{"normal"}));
                const n = try p.vec(o, "normal", path, null);
                if (math.vec.length(n) < 1e-9) return p.bad(try p.at(path, "normal"), "", "'normal' must not be zero", .{});
                s.kind = .{ .half_space = .{ .normal = math.vec.normalize(n) } };
            },
            .chain => {
                try p.onlyKeys(o, path, &(common_keys ++ .{ "points", "radius", "radii" }));
                s.kind = .{ .chain = try p.chain(o, path) };
            },
        }
        return s;
    }

    fn chain(p: *Parser, o: ObjectMap, path: []const u8) HandlerError!@FieldType(sdf.Kind, "chain") {
        const pv = o.get("points") orelse return p.bad(try p.at(path, "points"), "", "missing 'points'", .{});
        const items = if (pv == .array) pv.array.items else return p.bad(try p.at(path, "points"), "", "'points' must be a list of [x, y, z]", .{});
        if (items.len < 2) return p.bad(try p.at(path, "points"), "", "a chain needs at least 2 points", .{});
        p.points += items.len;
        if (p.points > max_chain_points) return p.bad(try p.at(path, "points"), "use fewer points per chain", "more than {d} chain points in all", .{max_chain_points});
        const pts = try p.c.arena.alloc(math.Vec3, items.len);
        for (items, pts, 0..) |item, *o_pt, i| o_pt.* = try p.point(item, try std.fmt.allocPrint(p.c.arena, "{s}/points/{d}", .{ path, i }));
        const radii = try p.c.arena.alloc(f32, items.len);
        if (o.get("radii")) |rv| {
            const rs = if (rv == .array and rv.array.items.len == items.len) rv.array.items else return p.bad(try p.at(path, "radii"), "", "'radii' needs one radius per point ({d})", .{items.len});
            for (rs, radii, 0..) |x, *r, i| {
                const f = schema.number(x) orelse 0;
                if (!(f > 0 and f <= 1e6)) return p.bad(try std.fmt.allocPrint(p.c.arena, "{s}/radii/{d}", .{ path, i }), "", "radii must be positive", .{});
                r.* = @floatCast(f);
            }
        } else @memset(radii, try p.num(o, "radius", path, null, 1e-6, 1e6));
        return .{ .points = pts, .radii = radii };
    }

    fn pairRadii(p: *Parser, o: ObjectMap, path: []const u8) HandlerError![2]f32 {
        if (o.get("radii")) |rv| {
            const rs = if (rv == .array and rv.array.items.len == 2) rv.array.items else return p.bad(try p.at(path, "radii"), "", "'radii' must be [ra, rb]", .{});
            var out: [2]f32 = undefined;
            for (rs, &out) |x, *r| {
                const f = schema.number(x) orelse 0;
                if (!(f > 0 and f <= 1e6)) return p.bad(try p.at(path, "radii"), "", "radii must be positive", .{});
                r.* = @floatCast(f);
            }
            return out;
        }
        const r = try p.num(o, "radius", path, null, 1e-6, 1e6);
        return .{ r, r };
    }

    fn onlyKeys(p: *Parser, o: ObjectMap, path: []const u8, allowed: []const []const u8) HandlerError!void {
        var it = o.iterator();
        outer: while (it.next()) |e| {
            for (allowed) |k| if (std.mem.eql(u8, k, e.key_ptr.*)) continue :outer;
            return p.c.failAt(.invalid_argument, try p.at(path, e.key_ptr.*), "", allowed, "unknown key '{s}'", .{e.key_ptr.*});
        }
    }

    fn num(p: *Parser, o: ObjectMap, key: []const u8, path: []const u8, default: ?f32, min: f32, max: f32) HandlerError!f32 {
        const val = o.get(key) orelse {
            if (default) |d| return d;
            return p.bad(try p.at(path, key), "", "missing '{s}'", .{key});
        };
        const x = schema.number(val) orelse return p.bad(try p.at(path, key), "", "'{s}' must be a number", .{key});
        if (!(x >= min and x <= max)) return p.bad(try p.at(path, key), "", "'{s}' must be within {d} to {d}", .{ key, min, max });
        return @floatCast(x);
    }

    fn point(p: *Parser, val: Value, path: []const u8) HandlerError!math.Vec3 {
        const items = if (val == .array and val.array.items.len == 3) val.array.items else return p.bad(path, "", "expected [x, y, z]", .{});
        var out: math.Vec3 = undefined;
        for (items, &out) |x, *o| {
            const f = schema.number(x) orelse return p.bad(path, "", "expected numbers", .{});
            if (!(@abs(f) <= 1e6)) return p.bad(path, "", "coordinates must be finite, within 1e6", .{});
            o.* = @floatCast(f);
        }
        return out;
    }

    fn vec(p: *Parser, o: ObjectMap, key: []const u8, path: []const u8, default: ?math.Vec3) HandlerError!math.Vec3 {
        const val = o.get(key) orelse {
            if (default) |d| return d;
            return p.bad(try p.at(path, key), "", "missing '{s}'", .{key});
        };
        return p.point(val, try p.at(path, key));
    }

    fn positiveVec(p: *Parser, o: ObjectMap, key: []const u8, path: []const u8) HandlerError!math.Vec3 {
        const x = try p.vec(o, key, path, null);
        if (!(x[0] > 0 and x[1] > 0 and x[2] > 0)) return p.bad(try p.at(path, key), "", "'{s}' must be positive on every axis", .{key});
        return x;
    }
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
    var relief_texture: ?math.texture.Recipe = null;
    if (a.value("relief_texture")) |rv| relief_texture = try shading.parseRecipe(c, rv.object, "/relief_texture");
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
        .relief_texture = if (relief_texture) |*r| r else null,
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
