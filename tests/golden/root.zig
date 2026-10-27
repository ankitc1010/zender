//! Golden suites (TRD §15): geometry and render outputs compared with the
//! files in tests/golden/. Geometry covers the primitives (geometry.json)
//! and each mesh operator (mesh_ops.json). `zig build test -Dupdate-golden` rewrites them
//! from the current output; review the diff before committing it.
//!
//! Geometry: per case, exact element counts, smooth-face count and a digest
//! of the connectivity (integers, so identical everywhere), plus float
//! statistics (bounds, area, volume, UV sums) within a tolerance. Float
//! attributes are not hashed: trigonometry goes through the platform's libm
//! on macOS, so their last bits may differ between platforms. Within one
//! platform the determinism tests still require bit-identical output.
//!
//! Render: each case replays a command log, renders a preview and compares
//! it with a stored PNG by PSNR and by the share of pixels off by more than
//! 8 levels in some channel. FLIP joins with the path tracer (P3).

const std = @import("std");
const math = @import("math");
const engine = @import("engine");
const io = @import("io");
const cmd = @import("cmd");
const options = @import("golden_options");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Stringify = std.json.Stringify;
const prims = engine.geom.primitives;
const Mesh = engine.core.types.Mesh;

const GeometryCase = struct { name: []const u8, kind: prims.Kind, params: prims.Params = .{} };

const geometry_cases = [_]GeometryCase{
    .{ .name = "cube", .kind = .cube },
    .{ .name = "plane", .kind = .plane },
    .{ .name = "grid_3x3", .kind = .grid, .params = .{ .x_subdivisions = 3, .y_subdivisions = 3 } },
    .{ .name = "uv_sphere", .kind = .uv_sphere },
    .{ .name = "uv_sphere_8x4_smooth", .kind = .uv_sphere, .params = .{ .segments = 8, .rings = 4, .smooth = true } },
    .{ .name = "ico_sphere_1", .kind = .ico_sphere, .params = .{ .subdivisions = 1 } },
    .{ .name = "ico_sphere_3", .kind = .ico_sphere, .params = .{ .subdivisions = 3 } },
    .{ .name = "cylinder", .kind = .cylinder },
    .{ .name = "cylinder_6_open", .kind = .cylinder, .params = .{ .segments = 6, .fill_caps = false } },
    .{ .name = "cone", .kind = .cone },
    .{ .name = "cone_frustum_12", .kind = .cone, .params = .{ .segments = 12, .radius_top = 0.5 } },
    .{ .name = "torus", .kind = .torus },
};

/// A mesh-operator case: `ops` (a scene.apply op list) builds the scene;
/// the stats are taken from `object`'s mesh.
const OpsCase = struct { name: []const u8, object: []const u8, ops: []const u8 };

const ops_cases = [_]OpsCase{
    .{ .name = "extrude_cube_top", .object = "Cube", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"cube"}},
    \\ {"tool":"mesh.extrude","arguments":{"object":"Cube","selector":{"normal":[0,0,1]},"distance":0.5}}]
    },
    .{ .name = "extrude_individual_grid", .object = "Grid", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"grid","grid_subdivisions":3}},
    \\ {"tool":"mesh.extrude","arguments":{"object":"Grid","selector":{"index":[0,4,8]},"offset":[0,0,0.2],"mode":"individual"}}]
    },
    .{ .name = "extrude_edges_and_verts", .object = "Plane", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"plane"}},
    \\ {"tool":"mesh.extrude","arguments":{"object":"Plane","selector":{"domain":"edge","where":"y > 0.99"},"offset":[0,0.5,0.5]}},
    \\ {"tool":"mesh.extrude","arguments":{"object":"Plane","selector":{"domain":"vert","where":["x < -0.99","y < -0.99"]},"distance":1}}]
    },
    .{ .name = "inset_cube_top", .object = "Cube", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"cube"}},
    \\ {"tool":"mesh.inset","arguments":{"object":"Cube","selector":{"normal":[0,0,1]},"thickness":0.3,"depth":-0.2}}]
    },
    .{ .name = "inset_region_grid", .object = "Grid", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"grid","grid_subdivisions":4}},
    \\ {"tool":"mesh.inset","arguments":{"object":"Grid","selector":{"box":{"min":[-0.6,-0.6,-1],"max":[0.6,0.6,1]}},"thickness":0.1,"depth":0.1}}]
    },
    .{ .name = "inset_individual_cylinder", .object = "Cylinder", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"cylinder","segments":8,"rotation":[90,0,0]}},
    \\ {"tool":"mesh.inset","arguments":{"object":"Cylinder","selector":{"where":"area < 2"},"thickness":0.05,"depth":-0.05,"mode":"individual"}}]
    },
    .{ .name = "triangulate_uv_sphere", .object = "Sphere", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"uv_sphere","segments":12,"rings":6}},
    \\ {"tool":"mesh.triangulate","arguments":{"object":"Sphere"}}]
    },
    .{ .name = "triangulate_cylinder_caps", .object = "Cylinder", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"cylinder"}},
    \\ {"tool":"mesh.triangulate","arguments":{"object":"Cylinder","selector":{"where":"abs(nz) > 0.9"}}},
    \\ {"tool":"object.add_primitive","arguments":{"kind":"cylinder","name":"Clip"}},
    \\ {"tool":"mesh.triangulate","arguments":{"object":"Clip","selector":{"where":"abs(nz) > 0.9"},"ngon_method":"clip"}}]
    },
    .{ .name = "triangulate_grid_alternate", .object = "Grid", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"grid","grid_subdivisions":3}},
    \\ {"tool":"mesh.triangulate","arguments":{"object":"Grid","quad_method":"alternate"}}]
    },
    .{ .name = "merge_cube_top_center", .object = "Cube", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"cube"}},
    \\ {"tool":"mesh.merge","arguments":{"object":"Cube","selector":{"domain":"face","normal":[0,0,1]}}}]
    },
    .{ .name = "merge_distance_after_individual", .object = "Grid", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"grid","grid_subdivisions":2}},
    \\ {"tool":"mesh.extrude","arguments":{"object":"Grid","selector":{},"offset":[0,0,0],"mode":"individual"}},
    \\ {"tool":"mesh.merge","arguments":{"object":"Grid","selector":{},"mode":"distance","threshold":0.001}}]
    },
    .{ .name = "merge_collapse_rows", .object = "Grid", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"grid","grid_subdivisions":3}},
    \\ {"tool":"mesh.merge","arguments":{"object":"Grid","selector":{"domain":"vert","where":"abs(y) > 0.99"},"mode":"collapse"}}]
    },
    .{ .name = "transform_sphere_top", .object = "Sphere", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"uv_sphere","segments":16,"rings":8,"location":[1,2,3]}},
    \\ {"tool":"mesh.transform_elements","arguments":{"object":"Sphere","selector":{"domain":"vert","where":"z > 3.5"},"scale":[1.5,1.5,1],"rotate":[0,0,45],"translate":[0,0,0.5]}}]
    },
    .{ .name = "rotated_torus_inset_extrude", .object = "Torus", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"torus","rotation":[30,0,0],"scale":[1,1,2]}},
    \\ {"tool":"mesh.inset","arguments":{"object":"Torus","selector":{"where":"z > 0.4"},"thickness":0.02}},
    \\ {"tool":"mesh.extrude","arguments":{"object":"Torus","selector":{"where":"z > 0.4"},"distance":0.1}}]
    },
    .{ .name = "loop_cut_cube_ring", .object = "Cube", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"cube"}},
    \\ {"tool":"mesh.loop_cut","arguments":{"object":"Cube","selector":{"domain":"edge","direction":[0,0,1],"within":5}}}]
    },
    .{ .name = "loop_cut_grid_crossing", .object = "Grid", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"grid","grid_subdivisions":3}},
    \\ {"tool":"mesh.loop_cut","arguments":{"object":"Grid","cuts":2,"selector":{"domain":"edge","union":[
    \\  {"direction":[1,0,0],"within":1,"where":["y < -0.99","x < -0.3"]},{"direction":[0,1,0],"within":1,"where":["x < -0.99","y < -0.3"]}]}}}]
    },
    .{ .name = "loop_cut_cylinder_sides", .object = "Cylinder", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"cylinder","segments":8}},
    \\ {"tool":"mesh.loop_cut","arguments":{"object":"Cylinder","selector":{"domain":"edge","direction":[0,0,1],"within":1},"cuts":3}},
    \\ {"tool":"mesh.transform_elements","arguments":{"object":"Cylinder","selector":{"domain":"vert","where":"abs(z) < 0.1"},"scale":[1.3,1.3,1]}}]
    },
    .{ .name = "bevel_cube_rounded", .object = "Cube", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"cube","scale":[2,1,0.5]}},
    \\ {"tool":"mesh.bevel","arguments":{"object":"Cube","selector":{},"width":0.2,"segments":4}}]
    },
    .{ .name = "bevel_box_vertical_chamfer", .object = "Cube", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"cube"}},
    \\ {"tool":"mesh.bevel","arguments":{"object":"Cube","selector":{"domain":"edge","direction":[0,0,1],"within":5},"width":0.3}}]
    },
    .{ .name = "bevel_cylinder_rim", .object = "Cylinder", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"cylinder","segments":16}},
    \\ {"tool":"mesh.bevel","arguments":{"object":"Cylinder","selector":{"domain":"edge","where":"z > 0.99"},"width":0.15,"segments":3}}]
    },
    .{ .name = "boolean_window_through_wall", .object = "Wall", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"cube","name":"Wall","size":1,"scale":[4,0.3,2.5],"location":[0,0,1.25]}},
    \\ {"tool":"object.add_primitive","arguments":{"kind":"cube","name":"Cut","size":1,"scale":[1.2,1,1],"location":[0.5,0,1.4]}},
    \\ {"tool":"mesh.boolean","arguments":{"object":"Wall","operand":"Cut"}},
    \\ {"tool":"object.add_primitive","arguments":{"kind":"cylinder","name":"Hole","radius":0.3,"depth":1,"segments":16,"rotation":[90,0,0],"location":[-1.2,0,1.4]}},
    \\ {"tool":"mesh.boolean","arguments":{"object":"Wall","operand":"Hole","operand_action":"delete"}}]
    },
    .{ .name = "boolean_union_intersect", .object = "Ball", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"uv_sphere","name":"Ball","segments":16,"rings":8}},
    \\ {"tool":"object.add_primitive","arguments":{"kind":"cylinder","name":"Rod","radius":0.4,"depth":3,"segments":12}},
    \\ {"tool":"mesh.boolean","arguments":{"object":"Ball","operand":"Rod","operation":"union","operand_action":"keep"}},
    \\ {"tool":"object.add_primitive","arguments":{"kind":"cube","name":"Box","size":1.6}},
    \\ {"tool":"mesh.boolean","arguments":{"object":"Ball","operand":"Box","operation":"intersect"}}]
    },
    .{ .name = "soft_bump_on_grid", .object = "Grid", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"grid","grid_subdivisions":12}},
    \\ {"tool":"mesh.transform_elements","arguments":{"object":"Grid","selector":{"domain":"vert","sphere":{"center":[0.25,0,0],"radius":0.1}},"translate":[0,0,0.6],"falloff":0.7}},
    \\ {"tool":"mesh.transform_elements","arguments":{"object":"Grid","selector":{"domain":"vert","where":"x < -0.8"},"scale":[1,1,0],"translate":[0,0,0.2],"falloff":0.5,"falloff_curve":"sphere","falloff_connected":true}}]
    },
    .{ .name = "smooth_union_seam", .object = "Ball", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"uv_sphere","name":"Ball","segments":24,"rings":12}},
    \\ {"tool":"object.add_primitive","arguments":{"kind":"uv_sphere","name":"Bump","radius":0.4,"segments":16,"rings":8,"location":[0,-0.9,0]}},
    \\ {"tool":"mesh.boolean","arguments":{"object":"Ball","operand":"Bump","operation":"union","operand_action":"delete"}},
    \\ {"tool":"mesh.smooth","arguments":{"object":"Ball","selector":{"domain":"vert","sphere":{"center":[0,-1,0],"radius":0.5}},"iterations":8,"falloff":0.3}}]
    },
    .{ .name = "modifier_mirror_subdivision", .object = "Cube", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"cube"}},
    \\ {"tool":"mesh.loop_cut","arguments":{"object":"Cube","selector":{"domain":"edge","direction":[1,0,0],"within":5}}},
    \\ {"tool":"mesh.transform_elements","arguments":{"object":"Cube","selector":{"domain":"vert","where":"x > 0.5"},"scale":[1,1.4,0.6]}},
    \\ {"tool":"modifier.add","arguments":{"object":"Cube","type":"mirror"}},
    \\ {"tool":"modifier.add","arguments":{"object":"Cube","type":"subdivision","properties":{"levels":2}}},
    \\ {"tool":"modifier.apply","arguments":{"object":"Cube"}}]
    },
    .{ .name = "modifier_array_solidify_bevel", .object = "Plane", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"plane","size":1}},
    \\ {"tool":"modifier.add","arguments":{"object":"Plane","type":"array","properties":{"count":4,"constant_offset":[0.2,0,0]}}},
    \\ {"tool":"modifier.add","arguments":{"object":"Plane","type":"solidify","properties":{"thickness":0.3,"offset":0}}},
    \\ {"tool":"modifier.add","arguments":{"object":"Plane","type":"bevel","properties":{"width":0.03,"segments":2}}},
    \\ {"tool":"modifier.apply","arguments":{"object":"Plane"}}]
    },
    .{ .name = "modifier_displace_decimate_triangulate", .object = "Sphere", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"uv_sphere","segments":32,"rings":16}},
    \\ {"tool":"modifier.add","arguments":{"object":"Sphere","type":"displace","properties":{"texture":"noise","strength":0.3,"noise_scale":0.5,"noise_seed":7}}},
    \\ {"tool":"modifier.add","arguments":{"object":"Sphere","type":"decimate","properties":{"ratio":0.4}}},
    \\ {"tool":"modifier.apply","arguments":{"object":"Sphere"}},
    \\ {"tool":"object.add_primitive","arguments":{"kind":"cylinder","name":"Can","segments":12}},
    \\ {"tool":"modifier.add","arguments":{"object":"Can","type":"triangulate","properties":{"ngon_method":"clip"}}},
    \\ {"tool":"modifier.apply","arguments":{"object":"Can","modifier":"Triangulate"}}]
    },
    .{ .name = "modifier_boolean_array_target", .object = "Slab", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"cube","name":"Slab","scale":[3,1,0.2]}},
    \\ {"tool":"object.add_primitive","arguments":{"kind":"cylinder","name":"Drill","radius":0.3,"depth":2,"segments":16,"location":[-2,0,0]}},
    \\ {"tool":"modifier.add","arguments":{"object":"Drill","type":"array","properties":{"count":4,"relative_offset":[0,0,0],"constant_offset":[1.3,0,0]}}},
    \\ {"tool":"modifier.add","arguments":{"object":"Slab","type":"boolean","target":"Drill"}},
    \\ {"tool":"modifier.apply","arguments":{"object":"Slab"}}]
    },
    .{ .name = "uv_unwrap_smart_torus", .object = "Torus", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"torus"}},
    \\ {"tool":"mesh.uv_unwrap","arguments":{"object":"Torus"}}]
    },
    .{ .name = "uv_unwrap_conformal_cylinder", .object = "Cylinder", .ops =
    \\[{"tool":"object.add_primitive","arguments":{"kind":"cylinder","scale":[1,1,2]}},
    \\ {"tool":"mesh.uv_unwrap","arguments":{"object":"Cylinder","method":"conformal",
    \\  "seams":{"domain":"edge","union":[{"direction":[1,0,0],"within":89},{"direction":[0,0,1],"within":1,"where":["x > 0.99"]}]}}}]
    },
};

const RenderCase = struct {
    name: []const u8,
    /// Command log: a file in tests/golden/render, or "examples/<file>".
    log: []const u8,
    width: u32 = 160,
    height: u32 = 120,
    wireframe: bool = false,
    transparent: bool = false,
};

const render_cases = [_]RenderCase{
    .{ .name = "default", .log = "default.jsonl" },
    .{ .name = "primitives", .log = "primitives.jsonl", .width = 240 },
    .{ .name = "collections", .log = "collections.jsonl" },
    .{ .name = "dining", .log = "examples/dining.jsonl" },
    .{ .name = "dining_wire_transparent", .log = "examples/dining.jsonl", .wireframe = true, .transparent = true },
};

/// Thresholds for previews; identical output passes with infinite PSNR.
const min_psnr = 40.0;
const max_bad_pixels = 0.002;

const Stats = struct {
    points: usize,
    edges: usize,
    faces: usize,
    corners: usize,
    smooth_faces: usize,
    topology: u64,
    bounds: [2][3]f64,
    area: f64,
    volume: f64,
    uv_sum: [2]f64,
};

fn statsOf(m: *const Mesh) Stats {
    const pos = m.positions.slice();
    const off = m.face_offsets.slice();
    const cv = m.corner_verts.slice();
    var s: Stats = .{
        .points = m.vertCount(),
        .edges = m.edgeCount(),
        .faces = m.faceCount(),
        .corners = m.cornerCount(),
        .smooth_faces = 0,
        .topology = engine.core.canonical.topologyDigest(m),
        .bounds = .{ @splat(std.math.inf(f64)), @splat(-std.math.inf(f64)) },
        .area = 0,
        .volume = 0,
        .uv_sum = .{ 0, 0 },
    };
    for (pos) |p| for (0..3) |k| {
        s.bounds[0][k] = @min(s.bounds[0][k], p[k]);
        s.bounds[1][k] = @max(s.bounds[1][k], p[k]);
    };
    const sharp: []const bool = if (m.attribute("sharp_face")) |a| a.data.boolean.slice() else &.{};
    for (0..s.faces) |f| {
        if (sharp.len == 0 or !sharp[f]) s.smooth_faces += 1;
        const corners = cv[off[f]..off[f + 1]];
        // Newell's method for the area; a fan of tetrahedra for the volume.
        var n: [3]f64 = .{ 0, 0, 0 };
        const p0 = widen(pos[corners[0]]);
        for (corners, 0..) |c, i| {
            const a = widen(pos[c]);
            const b = widen(pos[corners[(i + 1) % corners.len]]);
            n[0] += (a[1] - b[1]) * (a[2] + b[2]);
            n[1] += (a[2] - b[2]) * (a[0] + b[0]);
            n[2] += (a[0] - b[0]) * (a[1] + b[1]);
            if (i > 0 and i + 1 < corners.len) s.volume += dot(p0, cross(a, b)) / 6;
        }
        s.area += @sqrt(dot(n, n)) / 2;
    }
    if (m.attribute(Mesh.uv_name)) |a| for (a.data.float2.slice()) |uv| {
        s.uv_sum[0] += uv[0];
        s.uv_sum[1] += uv[1];
    };
    return s;
}

fn widen(p: [3]f32) [3]f64 {
    return .{ p[0], p[1], p[2] };
}

fn dot(a: [3]f64, b: [3]f64) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn cross(a: [3]f64, b: [3]f64) [3]f64 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn close(a: f64, b: f64) bool {
    return @abs(a - b) <= 1e-6 + 1e-5 * @max(@abs(a), @abs(b));
}

fn writeF64(w: *Stringify, x: f64) !void {
    try w.print("{d}", .{x});
}

fn writeStats(w: *Stringify, s: Stats) !void {
    try w.beginObject();
    inline for (.{ "points", "edges", "faces", "corners", "smooth_faces" }) |f| {
        try w.objectField(f);
        try w.write(@field(s, f));
    }
    try w.objectField("topology");
    try w.print("\"{x:0>16}\"", .{s.topology});
    try w.objectField("bounds");
    try w.beginArray();
    for (s.bounds) |corner| {
        try w.beginArray();
        for (corner) |x| try writeF64(w, x);
        try w.endArray();
    }
    try w.endArray();
    try w.objectField("area");
    try writeF64(w, s.area);
    try w.objectField("volume");
    try writeF64(w, s.volume);
    try w.objectField("uv_sum");
    try w.beginArray();
    for (s.uv_sum) |x| try writeF64(w, x);
    try w.endArray();
    try w.endObject();
}

fn number(v: Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => std.math.nan(f64),
    };
}

/// Appends one line per mismatch between `s` and the stored `g`.
fn compareStats(arena: Allocator, name: []const u8, s: Stats, g: std.json.ObjectMap, problems: *std.ArrayList([]const u8)) !void {
    inline for (.{ "points", "edges", "faces", "corners", "smooth_faces" }) |f| {
        const want = g.get(f) orelse Value{ .integer = -1 };
        if (want != .integer or want.integer != @field(s, f)) try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: {s} is {d}, golden {f}", .{ name, f, @field(s, f), std.json.fmt(want, .{}) }));
    }
    const topo = try std.fmt.allocPrint(arena, "{x:0>16}", .{s.topology});
    const want_topo = g.get("topology") orelse Value{ .string = "" };
    if (want_topo != .string or !std.mem.eql(u8, topo, want_topo.string)) try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: topology digest {s} differs from golden", .{ name, topo }));
    var floats: std.ArrayList(struct { []const u8, f64, f64 }) = .empty;
    const gb = g.get("bounds").?.array.items;
    for (0..2) |i| for (0..3) |k| try floats.append(arena, .{ "bounds", s.bounds[i][k], number(gb[i].array.items[k]) });
    try floats.append(arena, .{ "area", s.area, number(g.get("area").?) });
    try floats.append(arena, .{ "volume", s.volume, number(g.get("volume").?) });
    const gu = g.get("uv_sum").?.array.items;
    for (0..2) |i| try floats.append(arena, .{ "uv_sum", s.uv_sum[i], number(gu[i]) });
    for (floats.items) |x| if (!close(x[1], x[2])) {
        try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: {s} is {d}, golden {d}", .{ name, x[0], x[1], x[2] }));
    };
}

fn goldenPath(arena: Allocator, parts: []const []const u8) ![]const u8 {
    var all: std.ArrayList([]const u8) = .empty;
    try all.append(arena, options.dir);
    try all.appendSlice(arena, parts);
    return std.fs.path.join(arena, all.items);
}

fn readFile(arena: Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(64 << 20)) catch |e| {
        std.debug.print("cannot read {s}: {t}; run `zig build test -Dupdate-golden` to create it\n", .{ path, e });
        return e;
    };
}

fn report(problems: []const []const u8) !void {
    if (problems.len == 0) return;
    for (problems) |p| std.debug.print("golden: {s}\n", .{p});
    std.debug.print("If the change is intended, run `zig build test -Dupdate-golden` and review the diff.\n", .{});
    return error.GoldenMismatch;
}

test "golden geometry: primitives" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var names: [geometry_cases.len][]const u8 = undefined;
    var stats: [geometry_cases.len]Stats = undefined;
    for (geometry_cases, &names, &stats) |c, *n, *s| {
        var m = try prims.generate(testing.allocator, c.kind, c.params);
        defer m.releaseRefs(testing.allocator);
        n.* = c.name;
        s.* = statsOf(&m);
    }
    try checkStats(arena, "geometry.json", &names, &stats, &.{});
}

test "golden geometry: mesh operators" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const roots = try arena.alloc([]const u8, 1);
    roots[0] = options.dir;
    var server = cmd.Server.init(testing.allocator, testing.io, .{ .io = testing.io, .threads = 4 }, .{ .roots = .{ .list = roots } }, cmd.catalog.tools);
    defer server.deinit();

    var problems: std.ArrayList([]const u8) = .empty;
    var names: [ops_cases.len][]const u8 = undefined;
    var stats: [ops_cases.len]Stats = undefined;
    for (ops_cases, &names, &stats) |c, *n, *s| {
        n.* = c.name;
        const created = try server.call(arena, "scene.create", null);
        const id = (try std.json.parseFromSliceLeaky(Value, arena, created.ok.structured, .{})).object.get("scene_id").?.string;
        var args: std.json.ObjectMap = .empty;
        try args.put(arena, "scene_id", .{ .string = id });
        try args.put(arena, "ops", try std.json.parseFromSliceLeaky(Value, arena, c.ops, .{}));
        const out = try server.call(arena, "scene.apply", .{ .object = args });
        if (out != .ok) {
            try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: scene.apply failed: {s} at {s}", .{ c.name, out.tool_error.message, out.tool_error.path }));
            s.* = std.mem.zeroes(Stats);
            continue;
        }
        const doc = &server.scenes.get(id).?.doc;
        const ob = doc.db.get(.object, doc.db.findByName(.object, c.object).?).?;
        s.* = statsOf(doc.db.get(.mesh, ob.data.?).?);
    }
    try checkStats(arena, "mesh_ops.json", &names, &stats, problems.items);
}

/// Writes (with -Dupdate-golden) or checks one stats file.
fn checkStats(arena: Allocator, file: []const u8, names: []const []const u8, stats: []const Stats, earlier: []const []const u8) !void {
    const path = try goldenPath(arena, &.{file});
    var problems: std.ArrayList([]const u8) = .empty;
    try problems.appendSlice(arena, earlier);
    if (options.update) {
        try report(problems.items);
        var out: std.Io.Writer.Allocating = .init(arena);
        var w: Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_1 } };
        try w.beginObject();
        for (names, stats) |n, s| {
            try w.objectField(n);
            try writeStats(&w, s);
        }
        try w.endObject();
        try out.writer.writeByte('\n');
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = out.written() });
        return;
    }

    const golden = try std.json.parseFromSliceLeaky(Value, arena, try readFile(arena, path), .{});
    for (names, stats) |n, s| {
        const g = golden.object.get(n) orelse {
            try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: no golden entry", .{n}));
            continue;
        };
        try compareStats(arena, n, s, g.object, &problems);
    }
    if (golden.object.count() != names.len) try problems.append(arena, try std.fmt.allocPrint(arena, "{s} has entries for cases that no longer exist", .{file}));
    try report(problems.items);
}

const Diff = struct { psnr: f64, bad: f64 };

fn compareImages(a: io.png.Image, b: io.png.Image) ?Diff {
    if (a.width != b.width or a.height != b.height or a.channels != b.channels) return null;
    var sq: f64 = 0;
    var bad: usize = 0;
    const px = a.pixels.len / a.channels;
    for (0..px) |i| {
        var off = false;
        for (0..a.channels) |k| {
            const d = @as(f64, @floatFromInt(a.pixels[i * a.channels + k])) - @as(f64, @floatFromInt(b.pixels[i * a.channels + k]));
            sq += d * d;
            if (@abs(d) > 8) off = true;
        }
        if (off) bad += 1;
    }
    const mse = sq / @as(f64, @floatFromInt(a.pixels.len));
    return .{
        .psnr = if (mse == 0) std.math.inf(f64) else 10 * std.math.log10(255.0 * 255.0 / mse),
        .bad = @as(f64, @floatFromInt(bad)) / @as(f64, @floatFromInt(px)),
    };
}

test "golden render: previews" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const roots = try arena.alloc([]const u8, 1);
    roots[0] = options.dir;
    var server = cmd.Server.init(testing.allocator, testing.io, .{ .io = testing.io, .threads = 4 }, .{ .roots = .{ .list = roots } }, cmd.catalog.tools);
    defer server.deinit();

    var problems: std.ArrayList([]const u8) = .empty;
    for (render_cases) |c| {
        const log_path = if (std.mem.startsWith(u8, c.log, "examples/"))
            try std.fs.path.join(arena, &.{ options.examples, c.log["examples/".len..] })
        else
            try goldenPath(arena, &.{ "render", c.log });
        const r = try cmd.replay.run(&server, arena, try readFile(arena, log_path));
        if (r.failed_line != 0) {
            try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}:{d}: {s}", .{ c.name, c.log, r.failed_line, r.message }));
            continue;
        }
        var args: std.json.ObjectMap = .empty;
        try args.put(arena, "scene_id", .{ .string = r.scene_id });
        try args.put(arena, "width", .{ .integer = c.width });
        try args.put(arena, "height", .{ .integer = c.height });
        try args.put(arena, "wireframe", .{ .bool = c.wireframe });
        try args.put(arena, "transparent", .{ .bool = c.transparent });
        const out = try server.call(arena, "render.preview", .{ .object = args });
        if (out != .ok) {
            try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: render.preview failed", .{c.name}));
            continue;
        }
        const png = out.ok.image.?.bytes;
        const path = try goldenPath(arena, &.{ "render", try std.fmt.allocPrint(arena, "{s}.png", .{c.name}) });
        if (options.update) {
            try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = png });
            continue;
        }
        const got = try io.png.decode(arena, png);
        const want = try io.png.decode(arena, try readFile(arena, path));
        const d = compareImages(got, want) orelse {
            try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: {d}x{d} differs in size from the golden {d}x{d}", .{ c.name, got.width, got.height, want.width, want.height }));
            continue;
        };
        if (d.psnr < min_psnr or d.bad > max_bad_pixels) {
            try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: PSNR {d:.1} dB (min {d:.0}), {d:.3}% of pixels off by more than 8 (max {d:.1}%)", .{ c.name, d.psnr, min_psnr, d.bad * 100, max_bad_pixels * 100 }));
        }
    }
    try report(problems.items);
}
