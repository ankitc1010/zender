//! glTF 2.0 exporter (.gltf with an embedded buffer, or .glb).
//!
//! Axis conversion follows Blender's exporter with "+Y Up": positions map
//! (x, y, z) → (x, z, −y), i.e. the basis change C = Rx(−90°). Node matrices
//! become C·L·C⁻¹, and cameras and lights get Blender's extra Rx(−90°)
//! correction so their −Z view axis survives. Light intensity uses the
//! exporter's "Standard" units: W → cd as W·683/(4π) for point and spot,
//! W/m² → lux unchanged for sun. Area lights have no glTF equivalent and
//! are reported as dropped.

const std = @import("std");
const math = @import("math");
const ir = @import("ir");
const png = @import("../image/png.zig");

const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const Writer = std.Io.Writer;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const v = math.vec;

pub const Format = enum { gltf, glb };

pub const Options = struct {
    format: Format = .glb,
    generator: []const u8 = "Zender",
    /// Skip nodes with hide_render set (their children are kept and
    /// re-parented to the nearest exported ancestor).
    skip_hidden: bool = true,
};

pub const Report = struct {
    nodes: usize = 0,
    meshes: usize = 0,
    triangles: usize = 0,
    bytes: usize = 0,
    /// Things the format could not carry (FR-IO-2), allocated in the arena.
    dropped: []const []const u8 = &.{},
};

/// Rx(−90°): Blender Z-up → glTF Y-up, (x, y, z) → (x, z, −y).
const C: Mat4 = .{
    1, 0, 0,  0,
    0, 0, -1, 0,
    0, 1, 0,  0,
    0, 0, 0,  1,
};
const C_inv: Mat4 = .{
    1, 0,  0, 0,
    0, 0,  1, 0,
    0, -1, 0, 0,
    0, 0,  0, 1,
};

fn toYUp(p: Vec3) Vec3 {
    return .{ p[0], p[2], -p[1] };
}

fn needsCorrection(n: ir.Node) bool {
    return n.kind == .camera or n.kind == .light;
}

const BufferBuilder = struct {
    gpa: Allocator,
    bytes: std.ArrayList(u8) = .empty,
    views: std.ArrayList(View) = .empty,
    accessors: std.ArrayList(Accessor) = .empty,

    const View = struct { offset: usize, len: usize, target: u32 };
    const Accessor = struct {
        view: usize,
        component: u32,
        count: usize,
        type: []const u8,
        min: ?Vec3 = null,
        max: ?Vec3 = null,
    };

    fn addView(b: *BufferBuilder, data: []const u8, target: u32) Allocator.Error!usize {
        while (b.bytes.items.len % 4 != 0) try b.bytes.append(b.gpa, 0);
        const off = b.bytes.items.len;
        try b.bytes.appendSlice(b.gpa, data);
        try b.views.append(b.gpa, .{ .offset = off, .len = data.len, .target = target });
        return b.views.items.len - 1;
    }

    fn addAccessor(b: *BufferBuilder, a: Accessor) Allocator.Error!usize {
        try b.accessors.append(b.gpa, a);
        return b.accessors.items.len - 1;
    }
};

const Primitive = struct {
    position: usize,
    normal: usize,
    uv: ?usize,
    tangent: ?usize,
    color: ?usize,
    indices: usize,
    material: ?u32,
};

const VertKey = struct {
    vert: u32,
    normal: [3]u32,
    uv: [2]u32,
    color: [4]u32,
};

/// Splits one mesh into one primitive per material slot with deduplicated
/// (vertex, normal, uv, colour) corners; slots with a normal map get
/// tangents, slots whose material reads a colour attribute get COLOR_0
/// (the material's base_color throughout where the mesh lacks it).
fn writeMesh(arena: Allocator, bb: *BufferBuilder, m: ir.Mesh, slots: []const ?u32, materials: []const ir.Material, report: *Report) Allocator.Error![]Primitive {
    const n_faces = m.faceCount();
    var max_slot: usize = 0;
    for (m.face_material) |s| max_slot = @max(max_slot, s);
    var prims: std.ArrayList(Primitive) = .empty;
    var tri: std.ArrayList(u32) = .empty;
    const has_uv = m.corner_uvs.len == m.corner_verts.len and m.corner_uvs.len > 0;

    for (0..max_slot + 1) |slot| {
        const mat = if (slot < slots.len) slots[slot] else null;
        const attr = if (mat) |i| materials[i].base_color_attribute else "";
        const layer = if (attr.len > 0) m.colorLayer(attr) else null;
        var map: std.AutoHashMapUnmanaged(VertKey, u32) = .empty;
        var pos: std.ArrayList(Vec3) = .empty;
        var nor: std.ArrayList(Vec3) = .empty;
        var uvs: std.ArrayList([2]f32) = .empty;
        var cols: std.ArrayList([4]f32) = .empty;
        var idx: std.ArrayList(u32) = .empty;
        for (0..n_faces) |f| {
            const s: usize = if (m.face_material.len > 0) m.face_material[f] else 0;
            if (s != slot) continue;
            const start = m.face_offsets[f];
            const corners = m.corner_verts[start..m.face_offsets[f + 1]];
            tri.clearRetainingCapacity();
            try math.triangulate.triangulate(arena, m.positions, corners, &tri);
            for (tri.items) |local| {
                const c = start + local;
                const n = m.corner_normals[c];
                const uv: [2]f32 = if (has_uv) m.corner_uvs[c] else .{ 0, 0 };
                const bc = if (mat) |i| materials[i].base_color else [4]f32{ 0, 0, 0, 0 };
                const col: [4]f32 = if (layer) |l| l[c] else if (attr.len > 0) .{ bc[0], bc[1], bc[2], 1 } else .{ 0, 0, 0, 0 };
                const key: VertKey = .{
                    .vert = m.corner_verts[c],
                    .normal = .{ @bitCast(n[0]), @bitCast(n[1]), @bitCast(n[2]) },
                    .uv = .{ @bitCast(uv[0]), @bitCast(uv[1]) },
                    .color = @bitCast(col),
                };
                const gop = try map.getOrPut(arena, key);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(pos.items.len);
                    try pos.append(arena, toYUp(m.positions[m.corner_verts[c]]));
                    try nor.append(arena, toYUp(n));
                    // glTF puts the UV origin at the top left.
                    try uvs.append(arena, .{ uv[0], 1 - uv[1] });
                    try cols.append(arena, col);
                }
                try idx.append(arena, gop.value_ptr.*);
            }
        }
        if (idx.items.len == 0) continue;
        report.triangles += idx.items.len / 3;

        var lo = pos.items[0];
        var hi = pos.items[0];
        for (pos.items) |p| {
            lo = v.min3(lo, p);
            hi = v.max3(hi, p);
        }
        const pv = try bb.addView(std.mem.sliceAsBytes(pos.items), 34962);
        const pa = try bb.addAccessor(.{ .view = pv, .component = 5126, .count = pos.items.len, .type = "VEC3", .min = lo, .max = hi });
        const nv = try bb.addView(std.mem.sliceAsBytes(nor.items), 34962);
        const na = try bb.addAccessor(.{ .view = nv, .component = 5126, .count = nor.items.len, .type = "VEC3" });
        var ua: ?usize = null;
        if (has_uv) {
            const uvv = try bb.addView(std.mem.sliceAsBytes(uvs.items), 34962);
            ua = try bb.addAccessor(.{ .view = uvv, .component = 5126, .count = uvs.items.len, .type = "VEC2" });
        }
        var ca: ?usize = null;
        if (attr.len > 0) {
            const cv = try bb.addView(std.mem.sliceAsBytes(cols.items), 34962);
            ca = try bb.addAccessor(.{ .view = cv, .component = 5126, .count = cols.items.len, .type = "VEC4" });
        }
        var ta: ?usize = null;
        if (has_uv and mat != null and materials[mat.?].normal_image != null) {
            const tan = try tangents(arena, pos.items, nor.items, uvs.items, idx.items);
            const tv = try bb.addView(std.mem.sliceAsBytes(tan), 34962);
            ta = try bb.addAccessor(.{ .view = tv, .component = 5126, .count = tan.len, .type = "VEC4" });
        }
        var ia: usize = undefined;
        if (pos.items.len <= 65535) {
            const small = try arena.alloc(u16, idx.items.len);
            for (idx.items, small) |x, *o| o.* = @intCast(x);
            const iv = try bb.addView(std.mem.sliceAsBytes(small), 34963);
            ia = try bb.addAccessor(.{ .view = iv, .component = 5123, .count = small.len, .type = "SCALAR" });
        } else {
            const iv = try bb.addView(std.mem.sliceAsBytes(idx.items), 34963);
            ia = try bb.addAccessor(.{ .view = iv, .component = 5125, .count = idx.items.len, .type = "SCALAR" });
        }
        try prims.append(arena, .{
            .position = pa,
            .normal = na,
            .uv = ua,
            .tangent = ta,
            .color = ca,
            .indices = ia,
            .material = mat,
        });
    }
    return prims.items;
}

/// Per-vertex tangents (xyz unit, w the handedness) in the frame
/// material.bake writes normal maps in: each triangle's direction of +u,
/// with +v (Blender's, up the image) as the bitangent, summed per vertex
/// and made orthogonal to the normal.
fn tangents(arena: Allocator, pos: []const Vec3, nor: []const Vec3, uvs: []const [2]f32, idx: []const u32) Allocator.Error![][4]f32 {
    const t_sum = try arena.alloc(Vec3, pos.len);
    @memset(t_sum, .{ 0, 0, 0 });
    const b_sum = try arena.alloc(Vec3, pos.len);
    @memset(b_sum, .{ 0, 0, 0 });
    var i: usize = 0;
    while (i + 2 < idx.len) : (i += 3) {
        const k = idx[i .. i + 3];
        const e1 = v.sub(pos[k[1]], pos[k[0]]);
        const e2 = v.sub(pos[k[2]], pos[k[0]]);
        // The exported v runs down the image; the bake's runs up.
        const du1 = uvs[k[1]][0] - uvs[k[0]][0];
        const dv1 = uvs[k[0]][1] - uvs[k[1]][1];
        const du2 = uvs[k[2]][0] - uvs[k[0]][0];
        const dv2 = uvs[k[0]][1] - uvs[k[2]][1];
        const det = du1 * dv2 - du2 * dv1;
        if (@abs(det) < 1e-20) continue;
        const t = v.scale(v.sub(v.scale(e1, dv2), v.scale(e2, dv1)), 1 / det);
        const b = v.scale(v.sub(v.scale(e2, du1), v.scale(e1, du2)), 1 / det);
        for (k) |x| {
            t_sum[x] = v.add(t_sum[x], t);
            b_sum[x] = v.add(b_sum[x], b);
        }
    }
    const out = try arena.alloc([4]f32, pos.len);
    for (out, nor, t_sum, b_sum) |*o, n, ts, bs| {
        var t = v.sub(ts, v.scale(n, v.dot(ts, n)));
        if (v.length(t) < 1e-12) {
            const a: Vec3 = if (@abs(n[0]) < 0.9) .{ 1, 0, 0 } else .{ 0, 1, 0 };
            t = v.cross(a, n);
        }
        t = v.normalize(t);
        o.* = .{ t[0], t[1], t[2], if (v.dot(v.cross(n, t), bs) < 0) -1 else 1 };
    }
    return out;
}

fn f32Array(w: *Stringify, xs: []const f32) !void {
    try w.beginArray();
    for (xs) |x| try writeF32(w, x);
    try w.endArray();
}

fn writeF32(w: *Stringify, x: f32) !void {
    const y: f32 = if (std.math.isFinite(x)) x else 0;
    // Normalise -0 so output does not depend on how a zero was reached.
    const z: f32 = if (y == 0) 0 else y;
    try w.beginWriteRaw();
    try w.writer.print("{d}", .{z});
    w.endWriteRaw();
}

fn isIdentityTrs(t: Vec3, r: math.Quat, s: Vec3) bool {
    return t[0] == 0 and t[1] == 0 and t[2] == 0 and r[0] == 0 and r[1] == 0 and r[2] == 0 and r[3] == 1 and s[0] == 1 and s[1] == 1 and s[2] == 1;
}

/// Exports `scene` to `out`. `arena` holds temporary data and the report.
pub fn write(arena: Allocator, scene: ir.Scene, opts: Options, out: *Writer) (Allocator.Error || Writer.Error)!Report {
    var report: Report = .{};
    var dropped: std.ArrayList([]const u8) = .empty;
    var bb: BufferBuilder = .{ .gpa = arena };

    // Which nodes are exported, and each one's exported ancestor.
    const n_nodes = scene.nodes.len;
    const export_index = try arena.alloc(?u32, n_nodes);
    const export_parent = try arena.alloc(?u32, n_nodes);
    var exported: std.ArrayList(u32) = .empty;
    for (scene.nodes, 0..) |n, i| {
        var p = n.parent;
        while (p) |pi| : (p = scene.nodes[pi].parent) {
            if (export_index[pi] != null) break;
        }
        export_parent[i] = p;
        const skip = (opts.skip_hidden and n.hide_render) or (n.kind == .light and scene.lights[n.kind.light].kind == .area);
        if (n.kind == .light and scene.lights[n.kind.light].kind == .area) {
            try dropped.append(arena, try std.fmt.allocPrint(arena, "area light '{s}' (KHR_lights_punctual has no area lights)", .{n.name}));
        }
        if (skip) {
            export_index[i] = null;
        } else {
            export_index[i] = @intCast(exported.items.len);
            try exported.append(arena, @intCast(i));
        }
    }

    // Meshes, in first-use order.
    const mesh_out = try arena.alloc(?u32, scene.meshes.len);
    @memset(mesh_out, null);
    var mesh_prims: std.ArrayList([]Primitive) = .empty;
    var mesh_names: std.ArrayList([]const u8) = .empty;
    for (exported.items) |i| {
        const n = scene.nodes[i];
        if (n.kind != .mesh) continue;
        const mi = n.kind.mesh;
        if (mesh_out[mi] != null) continue;
        const prims = try writeMesh(arena, &bb, scene.meshes[mi], n.materials, scene.materials, &report);
        mesh_out[mi] = @intCast(mesh_prims.items.len);
        try mesh_prims.append(arena, prims);
        try mesh_names.append(arena, scene.meshes[mi].name);
    }
    report.meshes = mesh_prims.items.len;

    // Materials referenced by exported primitives, in first-use order.
    const mat_out = try arena.alloc(?u32, scene.materials.len);
    @memset(mat_out, null);
    var mats: std.ArrayList(u32) = .empty;
    for (mesh_prims.items) |prims| for (prims) |p| if (p.material) |m| if (mat_out[m] == null) {
        mat_out[m] = @intCast(mats.items.len);
        try mats.append(arena, m);
    };

    // Cameras and lights, in node order.
    var cams: std.ArrayList(u32) = .empty;
    const cam_out = try arena.alloc(?u32, scene.cameras.len);
    @memset(cam_out, null);
    var lights: std.ArrayList(u32) = .empty;
    const light_out = try arena.alloc(?u32, scene.lights.len);
    @memset(light_out, null);
    for (exported.items) |i| switch (scene.nodes[i].kind) {
        .camera => |c| if (cam_out[c] == null) {
            cam_out[c] = @intCast(cams.items.len);
            try cams.append(arena, c);
        },
        .light => |l| if (light_out[l] == null) {
            light_out[l] = @intCast(lights.items.len);
            try lights.append(arena, l);
        },
        else => {},
    };

    var uses_emissive_strength = false;
    var uses_ior = false;
    var uses_transmission = false;
    var uses_clearcoat = false;
    var uses_sheen = false;
    var uses_specular = false;
    for (mats.items) |mi| {
        const m = scene.materials[mi];
        if (m.emission_strength > 0 and m.emission_strength != 1) uses_emissive_strength = true;
        if (m.ior != 1.5) uses_ior = true;
        if (m.transmission > 0) uses_transmission = true;
        if (m.coat_weight > 0) uses_clearcoat = true;
        if (m.sheen_weight > 0) uses_sheen = true;
        if (hasSpecular(m)) uses_specular = true;
        if (m.coat_weight > 0 and !isWhite(m.coat_tint))
            try dropped.append(arena, try std.fmt.allocPrint(arena, "coat tint of material '{s}' (KHR_materials_clearcoat has no tint)", .{m.name}));
        if (m.procedural.len > 0) {
            const list = try std.mem.join(arena, ", ", m.procedural);
            try dropped.append(arena, try std.fmt.allocPrint(arena, "procedural {s} of material '{s}' (exported as the texture's mean; bake it with material.bake)", .{ list, m.name }));
        }
        if (m.coat_weight > 0 and m.coat_ior != 1.5)
            try dropped.append(arena, try std.fmt.allocPrint(arena, "coat IOR of material '{s}' (KHR_materials_clearcoat assumes 1.5)", .{m.name}));
    }

    var json: Writer.Allocating = .init(arena);
    var w: Stringify = .{ .writer = &json.writer };
    try w.beginObject();
    try w.objectField("asset");
    try w.beginObject();
    try w.objectField("generator");
    try w.write(opts.generator);
    try w.objectField("version");
    try w.write("2.0");
    try w.endObject();

    var ext_used: std.ArrayList([]const u8) = .empty;
    if (lights.items.len > 0) try ext_used.append(arena, "KHR_lights_punctual");
    if (uses_emissive_strength) try ext_used.append(arena, "KHR_materials_emissive_strength");
    if (uses_ior) try ext_used.append(arena, "KHR_materials_ior");
    if (uses_transmission) try ext_used.append(arena, "KHR_materials_transmission");
    if (uses_clearcoat) try ext_used.append(arena, "KHR_materials_clearcoat");
    if (uses_sheen) try ext_used.append(arena, "KHR_materials_sheen");
    if (uses_specular) try ext_used.append(arena, "KHR_materials_specular");
    if (ext_used.items.len > 0) {
        try w.objectField("extensionsUsed");
        try w.write(ext_used.items);
    }
    if (lights.items.len > 0) {
        try w.objectField("extensions");
        try w.beginObject();
        try w.objectField("KHR_lights_punctual");
        try w.beginObject();
        try w.objectField("lights");
        try w.beginArray();
        for (lights.items) |li| try writeLight(&w, scene.lights[li]);
        try w.endArray();
        try w.endObject();
        try w.endObject();
    }

    try w.objectField("scene");
    try w.write(0);
    try w.objectField("scenes");
    try w.beginArray();
    try w.beginObject();
    try w.objectField("name");
    try w.write(scene.name);
    try w.objectField("nodes");
    try w.beginArray();
    for (exported.items) |i| if (export_parent[i] == null) try w.write(export_index[i].?);
    try w.endArray();
    try w.endObject();
    try w.endArray();

    // Nodes.
    const gl_world = try arena.alloc(Mat4, n_nodes);
    for (scene.nodes, 0..) |n, i| {
        const corr = if (needsCorrection(n)) C else v.identity;
        gl_world[i] = v.matMul(v.matMul(C, v.matMul(n.world, C_inv)), corr);
    }
    if (exported.items.len > 0) {
        try w.objectField("nodes");
        try w.beginArray();
        for (exported.items) |i| {
            const n = scene.nodes[i];
            const local: Mat4 = blk: {
                const p = export_parent[i] orelse break :blk gl_world[i];
                if (n.parent != null and n.parent.? == p) {
                    // Exact path: K_p⁻¹ · C · L · C⁻¹ · K.
                    const kp_inv = if (needsCorrection(scene.nodes[p])) C_inv else v.identity;
                    const k = if (needsCorrection(n)) C else v.identity;
                    break :blk v.matMul(kp_inv, v.matMul(C, v.matMul(n.local, v.matMul(C_inv, k))));
                }
                break :blk v.matMul(v.invert(gl_world[p]) orelse v.identity, gl_world[i]);
            };
            try w.beginObject();
            try w.objectField("name");
            try w.write(n.name);
            var d = v.decompose(local);
            // Snap float noise from the matrix round trip (0.99999994 → 1).
            for (&d.s) |*x| {
                if (@abs(x.* - 1) < 1e-6) x.* = 1;
            }
            for (&d.t) |*x| {
                if (@abs(x.*) < 1e-7) x.* = 0;
            }
            const back = v.compose(d.t, d.r, d.s);
            var exact = true;
            for (back, local) |a, b| {
                if (@abs(a - b) > 1e-5 * @max(1, @abs(b))) exact = false;
            }
            if (!exact) {
                try w.objectField("matrix");
                try f32Array(&w, &local);
            } else if (!isIdentityTrs(d.t, d.r, d.s)) {
                if (d.t[0] != 0 or d.t[1] != 0 or d.t[2] != 0) {
                    try w.objectField("translation");
                    try f32Array(&w, &d.t);
                }
                if (d.r[0] != 0 or d.r[1] != 0 or d.r[2] != 0 or d.r[3] != 1) {
                    try w.objectField("rotation");
                    try f32Array(&w, &d.r);
                }
                if (d.s[0] != 1 or d.s[1] != 1 or d.s[2] != 1) {
                    try w.objectField("scale");
                    try f32Array(&w, &d.s);
                }
            }
            switch (n.kind) {
                .mesh => |m| if (mesh_out[m]) |mo| {
                    try w.objectField("mesh");
                    try w.write(mo);
                },
                .camera => |c| {
                    try w.objectField("camera");
                    try w.write(cam_out[c].?);
                },
                .light => |l| {
                    try w.objectField("extensions");
                    try w.beginObject();
                    try w.objectField("KHR_lights_punctual");
                    try w.beginObject();
                    try w.objectField("light");
                    try w.write(light_out[l].?);
                    try w.endObject();
                    try w.endObject();
                },
                .empty => {},
            }
            var has_children = false;
            for (exported.items) |j| if (export_parent[j] == @as(u32, @intCast(i))) {
                has_children = true;
            };
            if (has_children) {
                try w.objectField("children");
                try w.beginArray();
                for (exported.items) |j| if (export_parent[j] == @as(u32, @intCast(i))) try w.write(export_index[j].?);
                try w.endArray();
            }
            try w.endObject();
        }
        try w.endArray();
    }
    report.nodes = exported.items.len;

    if (mesh_prims.items.len > 0) {
        try w.objectField("meshes");
        try w.beginArray();
        for (mesh_prims.items, mesh_names.items) |prims, name| {
            try w.beginObject();
            try w.objectField("name");
            try w.write(name);
            try w.objectField("primitives");
            try w.beginArray();
            for (prims) |p| {
                try w.beginObject();
                try w.objectField("attributes");
                try w.beginObject();
                try w.objectField("POSITION");
                try w.write(p.position);
                try w.objectField("NORMAL");
                try w.write(p.normal);
                if (p.uv) |u| {
                    try w.objectField("TEXCOORD_0");
                    try w.write(u);
                }
                if (p.tangent) |t| {
                    try w.objectField("TANGENT");
                    try w.write(t);
                }
                if (p.color) |col| {
                    try w.objectField("COLOR_0");
                    try w.write(col);
                }
                try w.endObject();
                try w.objectField("indices");
                try w.write(p.indices);
                if (p.material) |m| if (mat_out[m]) |mo| {
                    try w.objectField("material");
                    try w.write(mo);
                };
                try w.endObject();
            }
            try w.endArray();
            try w.endObject();
        }
        try w.endArray();
    }

    if (mats.items.len > 0) {
        try w.objectField("materials");
        try w.beginArray();
        // Images become PNG buffer views; glTF reads metallic (B) and
        // roughness (G) from one texture, so those two are combined.
        var textures: Textures = .{ .arena = arena, .scene = &scene, .bb = &bb };
        const mat_tex = try arena.alloc(MatTextures, mats.items.len);
        for (mats.items, 0..) |mi, k| mat_tex[k] = try textures.forMaterial(scene.materials[mi]);
        for (mats.items, 0..) |mi, k| try writeMaterial(&w, scene.materials[mi], mat_tex[k]);
        try w.endArray();
        if (textures.images.items.len > 0) {
            try w.objectField("images");
            try w.beginArray();
            for (textures.images.items) |im| {
                try w.beginObject();
                try w.objectField("name");
                try w.write(im.name);
                try w.objectField("bufferView");
                try w.write(im.view);
                try w.objectField("mimeType");
                try w.write("image/png");
                try w.endObject();
            }
            try w.endArray();
            try w.objectField("textures");
            try w.beginArray();
            for (0..textures.images.items.len) |i| {
                try w.beginObject();
                try w.objectField("source");
                try w.write(i);
                try w.endObject();
            }
            try w.endArray();
        }
    }

    if (cams.items.len > 0) {
        const aspect = @as(f32, @floatFromInt(scene.resolution[0])) / @as(f32, @floatFromInt(scene.resolution[1]));
        try w.objectField("cameras");
        try w.beginArray();
        for (cams.items) |ci| try writeCamera(&w, scene.cameras[ci], aspect);
        try w.endArray();
    }

    if (bb.accessors.items.len > 0) {
        try w.objectField("accessors");
        try w.beginArray();
        for (bb.accessors.items) |a| {
            try w.beginObject();
            try w.objectField("bufferView");
            try w.write(a.view);
            try w.objectField("componentType");
            try w.write(a.component);
            try w.objectField("count");
            try w.write(a.count);
            try w.objectField("type");
            try w.write(a.type);
            if (a.min) |lo| {
                try w.objectField("min");
                try f32Array(&w, &lo);
                try w.objectField("max");
                try f32Array(&w, &a.max.?);
            }
            try w.endObject();
        }
        try w.endArray();
        try w.objectField("bufferViews");
        try w.beginArray();
        for (bb.views.items) |bv| {
            try w.beginObject();
            try w.objectField("buffer");
            try w.write(0);
            try w.objectField("byteLength");
            try w.write(bv.len);
            if (bv.offset != 0) {
                try w.objectField("byteOffset");
                try w.write(bv.offset);
            }
            // Image views have no target.
            if (bv.target != 0) {
                try w.objectField("target");
                try w.write(bv.target);
            }
            try w.endObject();
        }
        try w.endArray();
        while (bb.bytes.items.len % 4 != 0) try bb.bytes.append(arena, 0);
        try w.objectField("buffers");
        try w.beginArray();
        try w.beginObject();
        try w.objectField("byteLength");
        try w.write(bb.bytes.items.len);
        if (opts.format == .gltf) {
            try w.objectField("uri");
            const enc = std.base64.standard.Encoder;
            const prefix = "data:application/octet-stream;base64,";
            const uri = try arena.alloc(u8, prefix.len + enc.calcSize(bb.bytes.items.len));
            @memcpy(uri[0..prefix.len], prefix);
            _ = enc.encode(uri[prefix.len..], bb.bytes.items);
            try w.write(uri);
        }
        try w.endObject();
        try w.endArray();
    }
    try w.endObject();

    const json_bytes = json.written();
    switch (opts.format) {
        .gltf => {
            try out.writeAll(json_bytes);
            report.bytes = json_bytes.len;
        },
        .glb => {
            const json_pad = (4 - json_bytes.len % 4) % 4;
            const has_bin = bb.bytes.items.len > 0;
            const json_len = json_bytes.len + json_pad;
            const total = 12 + 8 + json_len + (if (has_bin) 8 + bb.bytes.items.len else 0);
            var hdr: [12]u8 = undefined;
            std.mem.writeInt(u32, hdr[0..4], 0x46546C67, .little);
            std.mem.writeInt(u32, hdr[4..8], 2, .little);
            std.mem.writeInt(u32, hdr[8..12], @intCast(total), .little);
            try out.writeAll(&hdr);
            try chunkHeader(out, json_len, 0x4E4F534A);
            try out.writeAll(json_bytes);
            try out.splatByteAll(' ', json_pad);
            if (has_bin) {
                try chunkHeader(out, bb.bytes.items.len, 0x004E4942);
                try out.writeAll(bb.bytes.items);
            }
            report.bytes = total;
        },
    }
    report.dropped = dropped.items;
    return report;
}

fn chunkHeader(out: *Writer, len: usize, kind: u32) Writer.Error!void {
    var h: [8]u8 = undefined;
    std.mem.writeInt(u32, h[0..4], @intCast(len), .little);
    std.mem.writeInt(u32, h[4..8], kind, .little);
    try out.writeAll(&h);
}

fn isWhite(c: [3]f32) bool {
    return c[0] == 1 and c[1] == 1 and c[2] == 1;
}

fn hasSpecular(m: ir.Material) bool {
    return m.specular_ior_level != 0.5 or !isWhite(m.specular_tint);
}

/// glTF texture indices of one material's inputs.
const MatTextures = struct {
    base_color: ?usize = null,
    metallic_roughness: ?usize = null,
    has_metallic: bool = false,
    has_roughness: bool = false,
    normal: ?usize = null,
    emission: ?usize = null,
};

/// Encodes the scene's images as PNG buffer views, each once.
const Textures = struct {
    arena: Allocator,
    scene: *const ir.Scene,
    bb: *BufferBuilder,
    images: std.ArrayList(struct { name: []const u8, view: usize }) = .empty,
    by_key: std.AutoHashMapUnmanaged(u64, usize) = .empty,

    fn forMaterial(t: *Textures, m: ir.Material) !MatTextures {
        var out: MatTextures = .{};
        if (m.base_color_image) |i| out.base_color = try t.single(i, true);
        if (m.normal_image) |i| out.normal = try t.single(i, false);
        if (m.emission_image) |i| if (m.emission_strength > 0) {
            out.emission = try t.single(i, true);
        };
        if (m.roughness_image != null or m.metallic_image != null) {
            const r = m.roughness_image;
            var mt = m.metallic_image;
            // Both must share a size to share a texture; roughness wins.
            if (r != null and mt != null) {
                const a = t.scene.images[r.?];
                const b = t.scene.images[mt.?];
                if (a.width != b.width or a.height != b.height) mt = null;
            }
            out.metallic_roughness = try t.combined(r, mt);
            out.has_roughness = r != null;
            out.has_metallic = mt != null;
        }
        return out;
    }

    fn single(t: *Textures, i: u32, srgb: bool) !usize {
        const key = (@as(u64, 1) << 62) | (@as(u64, @intFromBool(srgb)) << 61) | i;
        if (t.by_key.get(key)) |x| return x;
        const im = t.scene.images[i];
        const bytes = try t.arena.alloc(u8, @as(usize, im.width) * im.height * 4);
        for (0..im.height) |y| for (0..im.width) |x| {
            // PNG rows run top to bottom; images are stored bottom up.
            const src = im.pixels[(im.height - 1 - y) * im.width + x];
            const dst = bytes[(y * im.width + x) * 4 ..][0..4];
            for (0..3) |c| dst[c] = if (srgb) srgb8(src[c]) else unit8(src[c]);
            dst[3] = unit8(src[3]);
        };
        return t.add(key, im.name, im.width, im.height, bytes);
    }

    fn combined(t: *Textures, rough: ?u32, metal: ?u32) !usize {
        const key = (@as(u64, 2) << 62) | (@as(u64, rough orelse 0xFFFFFF) << 24) | (metal orelse 0xFFFFFF);
        if (t.by_key.get(key)) |x| return x;
        const ref = t.scene.images[(rough orelse metal).?];
        const bytes = try t.arena.alloc(u8, @as(usize, ref.width) * ref.height * 4);
        for (0..ref.height) |y| for (0..ref.width) |x| {
            const k = (ref.height - 1 - y) * ref.width + x;
            const dst = bytes[(y * ref.width + x) * 4 ..][0..4];
            dst[0] = 255;
            dst[1] = if (rough) |r| unit8(t.scene.images[r].pixels[k][0]) else 255;
            dst[2] = if (metal) |mm| unit8(t.scene.images[mm].pixels[k][0]) else 255;
            dst[3] = 255;
        };
        const name = try std.fmt.allocPrint(t.arena, "{s}_metallicRoughness", .{ref.name});
        return t.add(key, name, ref.width, ref.height, bytes);
    }

    fn add(t: *Textures, key: u64, name: []const u8, w: u32, h: u32, rgba: []const u8) !usize {
        var encoded: Writer.Allocating = .init(t.arena);
        try png.encode(t.arena, .{ .width = w, .height = h, .channels = 4, .pixels = rgba }, .default, &encoded.writer);
        const view = try t.bb.addView(encoded.written(), 0);
        try t.images.append(t.arena, .{ .name = name, .view = view });
        const idx = t.images.items.len - 1;
        try t.by_key.put(t.arena, key, idx);
        return idx;
    }
};

fn unit8(x: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(x, 0, 1) * 255));
}

fn srgb8(x: f32) u8 {
    const c = std.math.clamp(x, 0, 1);
    const s = if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(s * 255));
}

fn texRef(w: *Stringify, field: []const u8, index: usize) !void {
    try w.objectField(field);
    try w.beginObject();
    try w.objectField("index");
    try w.write(index);
    try w.endObject();
}

fn writeMaterial(w: *Stringify, m: ir.Material, tex: MatTextures) !void {
    try w.beginObject();
    try w.objectField("name");
    try w.write(m.name);
    try w.objectField("pbrMetallicRoughness");
    try w.beginObject();
    // glTF multiplies factor by texture and by COLOR_0, so a textured or
    // attribute-driven input's factor is 1.
    try w.objectField("baseColorFactor");
    if (tex.base_color != null or m.base_color_attribute.len > 0) {
        try f32Array(w, &.{ 1, 1, 1, m.base_color[3] * m.alpha });
    } else try f32Array(w, &.{ m.base_color[0], m.base_color[1], m.base_color[2], m.base_color[3] * m.alpha });
    if (tex.base_color) |i| try texRef(w, "baseColorTexture", i);
    try w.objectField("metallicFactor");
    try writeF32(w, if (tex.has_metallic) 1 else m.metallic);
    try w.objectField("roughnessFactor");
    try writeF32(w, if (tex.has_roughness) 1 else m.roughness);
    if (tex.metallic_roughness) |i| try texRef(w, "metallicRoughnessTexture", i);
    try w.endObject();
    if (tex.normal) |i| try texRef(w, "normalTexture", i);
    if (m.emission_strength > 0) {
        try w.objectField("emissiveFactor");
        if (tex.emission != null) try f32Array(w, &.{ 1, 1, 1 }) else try f32Array(w, &m.emission_color);
        if (tex.emission) |i| try texRef(w, "emissiveTexture", i);
    }
    if (m.base_color[3] * m.alpha < 1) {
        try w.objectField("alphaMode");
        try w.write("BLEND");
    }
    if (m.double_sided) {
        try w.objectField("doubleSided");
        try w.write(true);
    }
    const strength = m.emission_strength > 0 and m.emission_strength != 1;
    if (strength or m.ior != 1.5 or m.transmission > 0 or m.coat_weight > 0 or m.sheen_weight > 0 or hasSpecular(m)) {
        try w.objectField("extensions");
        try w.beginObject();
        if (strength) {
            try w.objectField("KHR_materials_emissive_strength");
            try w.beginObject();
            try w.objectField("emissiveStrength");
            try writeF32(w, m.emission_strength);
            try w.endObject();
        }
        if (m.ior != 1.5) {
            try w.objectField("KHR_materials_ior");
            try w.beginObject();
            try w.objectField("ior");
            try writeF32(w, m.ior);
            try w.endObject();
        }
        if (m.transmission > 0) {
            try w.objectField("KHR_materials_transmission");
            try w.beginObject();
            try w.objectField("transmissionFactor");
            try writeF32(w, m.transmission);
            try w.endObject();
        }
        if (m.coat_weight > 0) {
            try w.objectField("KHR_materials_clearcoat");
            try w.beginObject();
            try w.objectField("clearcoatFactor");
            try writeF32(w, m.coat_weight);
            try w.objectField("clearcoatRoughnessFactor");
            try writeF32(w, m.coat_roughness);
            try w.endObject();
        }
        if (m.sheen_weight > 0) {
            // glTF sheen has no separate weight; it scales the colour.
            try w.objectField("KHR_materials_sheen");
            try w.beginObject();
            try w.objectField("sheenColorFactor");
            try f32Array(w, &.{ m.sheen_tint[0] * m.sheen_weight, m.sheen_tint[1] * m.sheen_weight, m.sheen_tint[2] * m.sheen_weight });
            try w.objectField("sheenRoughnessFactor");
            try writeF32(w, m.sheen_roughness);
            try w.endObject();
        }
        if (hasSpecular(m)) {
            // Specular IOR Level 0.5 leaves F0 as the IOR gives it, which is
            // glTF's specularFactor 1; above 0.5 the boost moves to the colour.
            const level = 2 * m.specular_ior_level;
            const boost = @max(1, level);
            try w.objectField("KHR_materials_specular");
            try w.beginObject();
            try w.objectField("specularFactor");
            try writeF32(w, @min(1, level));
            try w.objectField("specularColorFactor");
            try f32Array(w, &.{ m.specular_tint[0] * boost, m.specular_tint[1] * boost, m.specular_tint[2] * boost });
            try w.endObject();
        }
        try w.endObject();
    }
    try w.endObject();
}

fn writeCamera(w: *Stringify, c: ir.Camera, aspect: f32) !void {
    const fov = c.fov(aspect);
    try w.beginObject();
    try w.objectField("name");
    try w.write(c.name);
    switch (c.projection) {
        .perspective => {
            try w.objectField("type");
            try w.write("perspective");
            try w.objectField("perspective");
            try w.beginObject();
            try w.objectField("aspectRatio");
            try writeF32(w, aspect);
            try w.objectField("yfov");
            try writeF32(w, fov.y);
            try w.objectField("zfar");
            try writeF32(w, c.clip_end);
            try w.objectField("znear");
            try writeF32(w, c.clip_start);
            try w.endObject();
        },
        .orthographic => {
            try w.objectField("type");
            try w.write("orthographic");
            try w.objectField("orthographic");
            try w.beginObject();
            try w.objectField("xmag");
            try writeF32(w, fov.half_w);
            try w.objectField("ymag");
            try writeF32(w, fov.half_h);
            try w.objectField("zfar");
            try writeF32(w, c.clip_end);
            try w.objectField("znear");
            try writeF32(w, c.clip_start);
            try w.endObject();
        },
    }
    try w.endObject();
}

fn writeLight(w: *Stringify, l: ir.Light) !void {
    try w.beginObject();
    try w.objectField("name");
    try w.write(l.name);
    try w.objectField("color");
    try f32Array(w, &l.color);
    try w.objectField("intensity");
    const watts_to_lumens = 683.0;
    try writeF32(w, switch (l.kind) {
        .sun => l.power,
        else => l.power * watts_to_lumens / (4 * std.math.pi),
    });
    try w.objectField("type");
    switch (l.kind) {
        .sun => try w.write("directional"),
        .point, .area => try w.write("point"),
        .spot => {
            try w.write("spot");
            const outer = l.spot_size / 2;
            try w.objectField("spot");
            try w.beginObject();
            try w.objectField("innerConeAngle");
            try writeF32(w, outer - outer * l.spot_blend);
            try w.objectField("outerConeAngle");
            try writeF32(w, outer);
            try w.endObject();
        },
    }
    try w.endObject();
}

test "camera node keeps its view axis through the Y-up conversion" {
    // Blender camera rotated 90° about X looks along +Y; in glTF, after
    // (x, y, z) → (x, z, −y), it must look along −Z.
    const q = v.eulerToQuat(.{ std.math.pi / 2.0, 0, 0 }, .xyz);
    const world = v.compose(.{ 0, 0, 0 }, q, .{ 1, 1, 1 });
    // Sanity: in Blender space the camera's -Z looks along +Y.
    const blender_view = v.transformDir(world, .{ 0, 0, -1 });
    try std.testing.expectApproxEqAbs(@as(f32, 1), blender_view[1], 1e-6);
    const gl = v.matMul(v.matMul(C, v.matMul(world, C_inv)), C);
    const gl_view = v.transformDir(gl, .{ 0, 0, -1 });
    const expect = toYUp(blender_view);
    for (0..3) |i| try std.testing.expectApproxEqAbs(expect[i], gl_view[i], 1e-6);
}

test "exports a small scene as valid glTF JSON and GLB" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const mesh: ir.Mesh = .{
        .name = "Quad",
        .positions = &.{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 0, 1, 0 } },
        .face_offsets = &.{ 0, 4 },
        .corner_verts = &.{ 0, 1, 2, 3 },
        .corner_normals = &.{ .{ 0, 0, 1 }, .{ 0, 0, 1 }, .{ 0, 0, 1 }, .{ 0, 0, 1 } },
        .corner_uvs = &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } },
        .face_material = &.{},
        .edges = &.{},
    };
    const mat: ir.Material = .{ .name = "Red", .base_color = .{ 1, 0, 0, 1 }, .metallic = 0, .roughness = 0.5, .ior = 1.5, .transmission = 0, .emission_color = .{ 1, 1, 1 }, .emission_strength = 0, .alpha = 1, .double_sided = true };
    const cam: ir.Camera = .{ .name = "Cam", .projection = .perspective, .lens_mm = 50, .sensor_width_mm = 36, .sensor_height_mm = 24, .sensor_fit = .auto, .ortho_scale = 6, .clip_start = 0.1, .clip_end = 100, .shift = .{ 0, 0 } };
    const light: ir.Light = .{ .name = "Lamp", .kind = .point, .color = .{ 1, 1, 1 }, .power = 1000, .radius = 0.1, .spot_size = 1, .spot_blend = 0.15, .area_size = .{ 1, 1 } };
    const area: ir.Light = .{ .name = "Panel", .kind = .area, .color = .{ 1, 1, 1 }, .power = 100, .radius = 0.1, .spot_size = 1, .spot_blend = 0.15, .area_size = .{ 1, 1 } };
    const slots = [_]?u32{0};
    const scene: ir.Scene = .{
        .name = "Scene",
        .nodes = &.{
            .{ .name = "Quad", .parent = null, .local = v.identity, .world = v.identity, .kind = .{ .mesh = 0 }, .materials = &slots, .hide_render = false },
            .{ .name = "Cam", .parent = 0, .local = v.compose(.{ 0, -5, 1 }, v.quat_identity, .{ 1, 1, 1 }), .world = v.compose(.{ 0, -5, 1 }, v.quat_identity, .{ 1, 1, 1 }), .kind = .{ .camera = 0 }, .materials = &.{}, .hide_render = false },
            .{ .name = "Lamp", .parent = null, .local = v.identity, .world = v.identity, .kind = .{ .light = 0 }, .materials = &.{}, .hide_render = false },
            .{ .name = "Panel", .parent = null, .local = v.identity, .world = v.identity, .kind = .{ .light = 1 }, .materials = &.{}, .hide_render = false },
        },
        .meshes = &.{mesh},
        .materials = &.{mat},
        .cameras = &.{cam},
        .lights = &.{ light, area },
        .world = .{ .color = .{ 0, 0, 0 }, .strength = 1 },
        .active_camera = 1,
        .resolution = .{ 1920, 1080 },
        .fps = 24,
        .frame_start = 1,
        .frame_end = 250,
    };
    var out: Writer.Allocating = .init(arena);
    const rep = try write(arena, scene, .{ .format = .gltf }, &out.writer);
    try std.testing.expectEqual(@as(usize, 3), rep.nodes);
    try std.testing.expectEqual(@as(usize, 2), rep.triangles);
    try std.testing.expectEqual(@as(usize, 1), rep.dropped.len);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const nodes = parsed.object.get("nodes").?.array.items;
    try std.testing.expectEqualStrings("Cam", nodes[1].object.get("name").?.string);
    // Root node indices: the quad and the lamp; the camera is a child.
    try std.testing.expectEqual(@as(usize, 2), parsed.object.get("scenes").?.array.items[0].object.get("nodes").?.array.items.len);

    var glb: Writer.Allocating = .init(arena);
    const rep2 = try write(arena, scene, .{ .format = .glb }, &glb.writer);
    try std.testing.expectEqual(rep2.bytes, glb.written().len);
    try std.testing.expectEqual(@as(usize, 0), glb.written().len % 4);
    try std.testing.expectEqualStrings("glTF", glb.written()[0..4]);
}
