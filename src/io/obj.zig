//! Wavefront OBJ and MTL, read and written as Blender's OBJ importer and
//! exporter do by default: the file is Y up (forward −Z), so positions map
//! (x, y, z)_obj ↔ (x, −z, y), and `o` starts a new object (`g` groups are
//! ignored). Faces keep their corner order and n-gons; `vt` become the UV
//! map; `usemtl` picks material slots; `s` groups set smooth shading, and a
//! file with normals but no `s` imports smooth. Custom normals, lines,
//! points, free-form geometry, vertex colours and texture maps are reported
//! as dropped.
//!
//! As in Blender, `usemtl` state carries over `o` statements, so an object
//! with no materials written after one with materials picks up the last
//! one on re-import.
//!
//! MTL: Kd → base colour, d (or 1 − Tr) → alpha, Ni → IOR, Ke → emission,
//! Pr / Pm → roughness / metallic, else roughness from Ns as Blender maps
//! it: Ns = ((1 − roughness)·30)².

const std = @import("std");
const math = @import("math");
const ir = @import("ir");
const mf = @import("meshfile.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Vec3 = math.Vec3;
const v = math.vec;

pub const Parsed = struct {
    objects: []mf.Object,
    /// Material names in slot order of first use across the file.
    material_names: []const []const u8,
    /// `mtllib` file names, relative to the OBJ file.
    libraries: []const []const u8,
    dropped: []const []const u8,
};

const Building = struct {
    name: []const u8,
    /// Global vertex → local, for vertices this object uses.
    local: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    positions: std.ArrayList(Vec3) = .empty,
    offsets: std.ArrayList(u32) = .empty,
    corners: std.ArrayList(u32) = .empty,
    uvs: std.ArrayList([2]f32) = .empty,
    has_uv: bool = false,
    smooth: std.ArrayList(bool) = .empty,
    slot: std.ArrayList(i32) = .empty,
    /// Material (index into the file's names) per slot.
    slots: std.ArrayList(u32) = .empty,
};

/// Parses OBJ text. `default_name` names geometry before any `o`.
pub fn parse(arena: Allocator, bytes: []const u8, default_name: []const u8) Allocator.Error!Parsed {
    var positions: std.ArrayList(Vec3) = .empty;
    var uvs: std.ArrayList([2]f32) = .empty;
    var normals: usize = 0;
    var objects: std.ArrayList(mf.Object) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var libraries: std.ArrayList([]const u8) = .empty;
    var dropped: std.ArrayList([]const u8) = .empty;
    var cur: Building = .{ .name = default_name };
    var material: ?u32 = null;
    var smooth: ?bool = null;
    var any_s = false;
    var skipped = struct { lines: usize = 0, points: usize = 0, freeform: usize = 0, colours: bool = false, bad_faces: usize = 0, unknown: usize = 0 }{};

    var lines = mf.Lines.init(bytes);
    var joined: std.ArrayList(u8) = .empty;
    while (lines.next()) |raw| {
        // A trailing backslash continues the statement on the next line.
        var line = raw;
        if (std.mem.endsWith(u8, std.mem.trimEnd(u8, line, " \t"), "\\")) {
            joined.clearRetainingCapacity();
            while (std.mem.endsWith(u8, std.mem.trimEnd(u8, line, " \t"), "\\")) {
                const t = std.mem.trimEnd(u8, line, " \t");
                try joined.appendSlice(arena, t[0 .. t.len - 1]);
                try joined.append(arena, ' ');
                line = lines.next() orelse "";
            }
            try joined.appendSlice(arena, line);
            line = joined.items;
        }
        const hash = std.mem.indexOfScalar(u8, line, '#') orelse line.len;
        var toks = std.mem.tokenizeAny(u8, line[0..hash], " \t");
        const key = toks.next() orelse continue;
        if (std.mem.eql(u8, key, "v")) {
            var p: Vec3 = .{ 0, 0, 0 };
            for (&p) |*x| x.* = mf.parseF32(toks.next() orelse "") orelse 0;
            var extra: usize = 0;
            while (toks.next()) |_| extra += 1;
            if (extra >= 3) skipped.colours = true;
            try positions.append(arena, .{ p[0], -p[2], p[1] });
        } else if (std.mem.eql(u8, key, "vt")) {
            const u = mf.parseF32(toks.next() orelse "") orelse 0;
            const w = mf.parseF32(toks.next() orelse "") orelse 0;
            try uvs.append(arena, .{ u, w });
        } else if (std.mem.eql(u8, key, "vn")) {
            normals += 1;
        } else if (std.mem.eql(u8, key, "f")) {
            const start: u32 = @intCast(cur.corners.items.len);
            var ok = true;
            var face_uv = true;
            var n: usize = 0;
            while (toks.next()) |t| : (n += 1) {
                var parts = std.mem.splitScalar(u8, t, '/');
                const vi = index(parts.next() orelse "", positions.items.len) orelse {
                    ok = false;
                    break;
                };
                const ti = if (parts.next()) |s| (if (s.len > 0) index(s, uvs.items.len) else null) else null;
                if (ti == null) face_uv = false;
                const gop = try cur.local.getOrPut(arena, vi);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(cur.positions.items.len);
                    try cur.positions.append(arena, positions.items[vi]);
                }
                // A corner repeating the previous one adds nothing.
                const lv = gop.value_ptr.*;
                if (cur.corners.items.len > start and cur.corners.items[cur.corners.items.len - 1] == lv) continue;
                try cur.corners.append(arena, lv);
                try cur.uvs.append(arena, if (ti) |i| uvs.items[i] else .{ 0, 0 });
            }
            const corners = cur.corners.items[start..];
            if (corners.len > 1 and corners[0] == corners[corners.len - 1]) {
                cur.corners.items.len -= 1;
                cur.uvs.items.len -= 1;
            }
            if (ok) ok = cur.corners.items.len - start >= 3 and distinct(cur.corners.items[start..]);
            if (!ok) {
                cur.corners.items.len = start;
                cur.uvs.items.len = start;
                skipped.bad_faces += 1;
                continue;
            }
            if (face_uv) cur.has_uv = true;
            try cur.offsets.append(arena, start);
            try cur.smooth.append(arena, smooth orelse false);
            try cur.slot.append(arena, if (material) |mi| try slotOf(arena, &cur, mi) else 0);
        } else if (std.mem.eql(u8, key, "o")) {
            const name = std.mem.trim(u8, toks.rest(), " \t");
            try finish(arena, &cur, &objects);
            cur = .{ .name = if (name.len > 0) try arena.dupe(u8, name) else default_name };
        } else if (std.mem.eql(u8, key, "usemtl")) {
            const name = std.mem.trim(u8, toks.rest(), " \t");
            material = try nameIndex(arena, &names, name);
        } else if (std.mem.eql(u8, key, "mtllib")) {
            const name = std.mem.trim(u8, toks.rest(), " \t");
            if (name.len > 0) try libraries.append(arena, try arena.dupe(u8, name));
        } else if (std.mem.eql(u8, key, "s")) {
            const arg = toks.next() orelse "off";
            smooth = !(std.mem.eql(u8, arg, "off") or std.mem.eql(u8, arg, "0"));
            any_s = true;
        } else if (std.mem.eql(u8, key, "g")) {
            // Blender's default: groups do not split objects.
        } else if (std.mem.eql(u8, key, "l")) {
            skipped.lines += 1;
        } else if (std.mem.eql(u8, key, "p")) {
            skipped.points += 1;
        } else if (isFreeform(key)) {
            skipped.freeform += 1;
        } else if (!std.mem.eql(u8, key, "vp")) {
            skipped.unknown += 1;
        }
    }
    try finish(arena, &cur, &objects);

    // With normals but no smoothing groups, Blender imports smooth.
    if (!any_s and normals > 0) for (objects.items) |*o| {
        o.sharp_face = &.{};
    };
    if (normals > 0) try dropped.append(arena, try std.fmt.allocPrint(arena, "{d} vertex normal(s) (vn): shading comes from smoothing groups", .{normals}));
    if (skipped.lines > 0) try dropped.append(arena, try std.fmt.allocPrint(arena, "{d} line element(s) (l)", .{skipped.lines}));
    if (skipped.points > 0) try dropped.append(arena, try std.fmt.allocPrint(arena, "{d} point element(s) (p)", .{skipped.points}));
    if (skipped.freeform > 0) try dropped.append(arena, try std.fmt.allocPrint(arena, "{d} free-form curve or surface statement(s)", .{skipped.freeform}));
    if (skipped.colours) try dropped.append(arena, "vertex colours (v x y z r g b)");
    if (skipped.bad_faces > 0) try dropped.append(arena, try std.fmt.allocPrint(arena, "{d} face(s) with bad indices or fewer than 3 distinct corners", .{skipped.bad_faces}));
    if (skipped.unknown > 0) try dropped.append(arena, try std.fmt.allocPrint(arena, "{d} unknown statement(s)", .{skipped.unknown}));
    return .{ .objects = objects.items, .material_names = names.items, .libraries = libraries.items, .dropped = dropped.items };
}

fn isFreeform(key: []const u8) bool {
    const keys = [_][]const u8{ "curv", "curv2", "surf", "cstype", "deg", "bmat", "step", "parm", "trim", "hole", "scrv", "sp", "end", "con" };
    for (keys) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

/// A 1-based (or negative, relative) OBJ index as 0-based, if in range.
fn index(s: []const u8, count: usize) ?u32 {
    const i = std.fmt.parseInt(i64, s, 10) catch return null;
    const z: i64 = if (i < 0) @as(i64, @intCast(count)) + i else i - 1;
    if (z < 0 or z >= count) return null;
    return @intCast(z);
}

fn distinct(xs: []const u32) bool {
    for (xs, 0..) |a, i| for (xs[i + 1 ..]) |b| if (a == b) return false;
    return true;
}

fn nameIndex(arena: Allocator, names: *std.ArrayList([]const u8), name: []const u8) Allocator.Error!u32 {
    for (names.items, 0..) |n, i| if (std.mem.eql(u8, n, name)) return @intCast(i);
    try names.append(arena, try arena.dupe(u8, name));
    return @intCast(names.items.len - 1);
}

fn slotOf(arena: Allocator, b: *Building, material: u32) Allocator.Error!i32 {
    for (b.slots.items, 0..) |m, i| if (m == material) return @intCast(i);
    try b.slots.append(arena, material);
    return @intCast(b.slots.items.len - 1);
}

fn finish(arena: Allocator, b: *Building, out: *std.ArrayList(mf.Object)) Allocator.Error!void {
    if (b.offsets.items.len == 0) return;
    try b.offsets.append(arena, @intCast(b.corners.items.len));
    var any_sharp = false;
    var any_slot = false;
    const sharp = try arena.alloc(bool, b.smooth.items.len);
    for (b.smooth.items, sharp) |s, *o| {
        o.* = !s;
        any_sharp = any_sharp or !s;
    }
    for (b.slot.items) |s| any_slot = any_slot or s != 0;
    try out.append(arena, .{
        .name = b.name,
        .positions = b.positions.items,
        .face_offsets = b.offsets.items,
        .corner_verts = b.corners.items,
        .corner_uvs = if (b.has_uv) b.uvs.items else &.{},
        .sharp_face = if (any_sharp) sharp else &.{},
        .material_index = if (any_slot) b.slot.items else &.{},
        .slots = b.slots.items,
    });
}

/// A material with Blender's defaults for anything the MTL leaves out.
pub fn defaultMaterial(name: []const u8) ir.Material {
    return .{
        .name = name,
        .base_color = .{ 0.8, 0.8, 0.8, 1 },
        .metallic = 0,
        .roughness = 0.5,
        .ior = 1.5,
        .transmission = 0,
        .emission_color = .{ 0, 0, 0 },
        .emission_strength = 0,
        .alpha = 1,
        .double_sided = true,
    };
}

/// Fills `materials` (by name) from MTL text; materials it does not name
/// are left as they are. Texture maps are reported to `dropped`.
pub fn parseMtl(arena: Allocator, bytes: []const u8, materials: []ir.Material, dropped: *std.ArrayList([]const u8)) Allocator.Error!void {
    var cur: ?*ir.Material = null;
    var pr_seen = false;
    var lines = mf.Lines.init(bytes);
    while (lines.next()) |line| {
        const hash = std.mem.indexOfScalar(u8, line, '#') orelse line.len;
        var toks = std.mem.tokenizeAny(u8, line[0..hash], " \t");
        const key = toks.next() orelse continue;
        if (std.mem.eql(u8, key, "newmtl")) {
            const name = std.mem.trim(u8, toks.rest(), " \t");
            cur = null;
            pr_seen = false;
            for (materials) |*m| if (std.mem.eql(u8, m.name, name)) {
                cur = m;
            };
            continue;
        }
        const m = cur orelse continue;
        const a = mf.parseF32(toks.next() orelse "");
        const b = mf.parseF32(toks.next() orelse "");
        const c = mf.parseF32(toks.next() orelse "");
        if (std.mem.eql(u8, key, "Kd")) {
            m.base_color = .{ a orelse 0.8, b orelse a orelse 0.8, c orelse a orelse 0.8, m.base_color[3] };
        } else if (std.mem.eql(u8, key, "d")) {
            m.alpha = std.math.clamp(a orelse 1, 0, 1);
            m.base_color[3] = m.alpha;
        } else if (std.mem.eql(u8, key, "Tr")) {
            m.alpha = std.math.clamp(1 - (a orelse 0), 0, 1);
            m.base_color[3] = m.alpha;
        } else if (std.mem.eql(u8, key, "Ni")) {
            m.ior = std.math.clamp(a orelse 1.5, 1, 4);
        } else if (std.mem.eql(u8, key, "Ke")) {
            m.emission_color = .{ a orelse 0, b orelse a orelse 0, c orelse a orelse 0 };
            m.emission_strength = if (m.emission_color[0] + m.emission_color[1] + m.emission_color[2] > 0) 1 else 0;
        } else if (std.mem.eql(u8, key, "Pr")) {
            m.roughness = std.math.clamp(a orelse 0.5, 0, 1);
            pr_seen = true;
        } else if (std.mem.eql(u8, key, "Pm")) {
            m.metallic = std.math.clamp(a orelse 0, 0, 1);
        } else if (std.mem.eql(u8, key, "Ns")) {
            if (!pr_seen) m.roughness = std.math.clamp(1 - @sqrt(@max(a orelse 0, 0)) / 30, 0, 1);
        } else if (std.mem.startsWith(u8, key, "map_") or std.mem.eql(u8, key, "bump") or std.mem.eql(u8, key, "disp") or std.mem.eql(u8, key, "norm")) {
            try dropped.append(arena, try std.fmt.allocPrint(arena, "texture map {s} of material '{s}' (images are not imported yet)", .{ key, m.name }));
        }
    }
}

pub const WriteOptions = struct {
    base: mf.ExportOptions = .{},
    generator: []const u8 = "Zender",
    /// File name written after `mtllib` when any material is used.
    mtl_name: ?[]const u8 = null,
};

/// Writes `scene`'s meshes as OBJ to `out`, and the materials they use as
/// MTL to `mtl_out` (when given).
pub fn write(arena: Allocator, scene: ir.Scene, opts: WriteOptions, out: *Writer, mtl_out: ?*Writer) (Allocator.Error || Writer.Error)!mf.Report {
    var report: mf.Report = .{};
    var dropped: std.ArrayList([]const u8) = .empty;
    const nodes = try mf.meshNodes(arena, scene, opts.base, "OBJ", &dropped);
    var used: std.ArrayList(u32) = .empty;
    for (nodes) |ni| for (scene.nodes[ni].materials) |slot| if (slot) |m| {
        if (std.mem.indexOfScalar(u32, used.items, m) == null) try used.append(arena, m);
    };
    try out.print("# {s}\n", .{opts.generator});
    if (used.items.len > 0) {
        if (opts.mtl_name) |name| try out.print("mtllib {s}\n", .{name}) else try dropped.append(arena, "materials (no .mtl file written)");
    }
    // OBJ indices are global and 1-based.
    var base_v: usize = 1;
    var base_t: usize = 1;
    var base_n: usize = 1;
    var tri: std.ArrayList(u32) = .empty;
    for (nodes) |ni| {
        const node = scene.nodes[ni];
        const m = scene.meshes[node.kind.mesh];
        report.objects += 1;
        try out.print("o {s}\n", .{node.name});
        const pos = try mf.worldPositions(arena, m, node.world);
        for (pos) |p| {
            try out.print("v {d} {d} {d}\n", .{ p[0], p[2], -p[1] });
        }
        // Distinct UVs and normals, numbered in first-use order.
        const t_index = try arena.alloc(u32, m.corner_verts.len);
        var t_map: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        var n_t: u32 = 0;
        for (m.corner_uvs, 0..) |uv, k| {
            const key = @as(u64, @as(u32, @bitCast(uv[0]))) << 32 | @as(u32, @bitCast(uv[1]));
            const gop = try t_map.getOrPut(arena, key);
            if (!gop.found_existing) {
                gop.value_ptr.* = n_t;
                n_t += 1;
                try out.print("vt {d} {d}\n", .{ uv[0], uv[1] });
            }
            t_index[k] = gop.value_ptr.*;
        }
        const n_index = try arena.alloc(u32, m.corner_verts.len);
        var n_map: std.AutoHashMapUnmanaged([3]u32, u32) = .empty;
        var n_n: u32 = 0;
        const nm = v.normalMatrix(node.world);
        for (m.corner_normals, 0..) |n0, k| {
            const n = v.normalize(v.transformDir(nm, n0));
            const y_up: Vec3 = .{ n[0], n[2], -n[1] };
            const key: [3]u32 = .{ @bitCast(y_up[0]), @bitCast(y_up[1]), @bitCast(y_up[2]) };
            const gop = try n_map.getOrPut(arena, key);
            if (!gop.found_existing) {
                gop.value_ptr.* = n_n;
                n_n += 1;
                try out.print("vn {d} {d} {d}\n", .{ y_up[0], y_up[1], y_up[2] });
            }
            n_index[k] = gop.value_ptr.*;
        }
        var cur_slot: ?u16 = null;
        var cur_smooth: ?bool = null;
        for (0..m.faceCount()) |f| {
            // A face is smooth when its corner normals differ; flat faces
            // get `s 0` so importers do not smooth them (Blender writes the
            // same pair).
            if (m.corner_normals.len > 0) {
                const ns = m.corner_normals[m.face_offsets[f]..m.face_offsets[f + 1]];
                var smooth = false;
                for (ns[1..]) |n| smooth = smooth or v.length(v.sub(n, ns[0])) > 1e-5;
                if (cur_smooth == null or cur_smooth.? != smooth) {
                    cur_smooth = smooth;
                    try out.writeAll(if (smooth) "s 1\n" else "s 0\n");
                }
            }
            const slot: u16 = if (m.face_material.len > 0) m.face_material[f] else 0;
            if (cur_slot == null or cur_slot.? != slot) {
                cur_slot = slot;
                const mat: ?u32 = if (slot < node.materials.len) node.materials[slot] else null;
                if (mat) |mi| try out.print("usemtl {s}\n", .{scene.materials[mi].name});
            }
            try out.writeByte('f');
            for (m.face_offsets[f]..m.face_offsets[f + 1]) |k| {
                try out.print(" {d}", .{base_v + m.corner_verts[k]});
                if (m.corner_uvs.len > 0) try out.print("/{d}", .{base_t + t_index[k]}) else if (m.corner_normals.len > 0) try out.writeByte('/');
                if (m.corner_normals.len > 0) try out.print("/{d}", .{base_n + n_index[k]});
            }
            try out.writeByte('\n');
            try mf.triangulateFace(arena, pos, m, f, &tri);
            report.triangles += tri.items.len / 3;
        }
        report.faces += m.faceCount();
        base_v += pos.len;
        base_t += n_t;
        base_n += n_n;
    }
    if (mtl_out) |mo| if (opts.mtl_name != null and used.items.len > 0) {
        try mo.print("# {s}\n", .{opts.generator});
        for (used.items) |mi| try writeMtl(mo, scene.materials[mi]);
    };
    report.dropped = dropped.items;
    return report;
}

fn writeMtl(out: *Writer, m: ir.Material) Writer.Error!void {
    const ns = std.math.pow(f32, (1 - m.roughness) * 30, 2);
    try out.print("\nnewmtl {s}\n", .{m.name});
    try out.print("Ns {d}\nKa 1 1 1\nKd {d} {d} {d}\nKs 0.5 0.5 0.5\n", .{ ns, m.base_color[0], m.base_color[1], m.base_color[2] });
    const e = v.scale(m.emission_color, m.emission_strength);
    try out.print("Ke {d} {d} {d}\nNi {d}\nd {d}\nillum 2\nPr {d}\nPm {d}\n", .{ e[0], e[1], e[2], m.ior, m.alpha, m.roughness, m.metallic });
}

const testing = std.testing;

test "OBJ parsing: objects, n-gons, UVs, slots, smoothing, negatives" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\# a quad and a triangle in two objects
        \\mtllib scene.mtl
        \\v 0 0 0
        \\v 1 0 0
        \\v 1 1 0
        \\v 0 1 0
        \\vt 0 0
        \\vt 1 0
        \\vt 1 1
        \\vt 0 1
        \\o Quad
        \\usemtl Red
        \\s 1
        \\f 1/1 2/2 3/3 4/4
        \\o Tri
        \\usemtl Blue
        \\s off
        \\f -4 -3 -2
        \\l 1 2
        \\f 1 1 2
        \\
    ;
    const p = try parse(arena, text, "Mesh");
    try testing.expectEqual(@as(usize, 2), p.objects.len);
    try testing.expectEqualStrings("scene.mtl", p.libraries[0]);
    const q = p.objects[0];
    try testing.expectEqualStrings("Quad", q.name);
    try testing.expectEqual(@as(usize, 4), q.positions.len);
    // OBJ (x, y, z) is engine (x, -z, y): the quad stands in the XZ plane.
    try testing.expectEqual(Vec3{ 1, 0, 1 }, q.positions[2]);
    try testing.expectEqual(@as(usize, 4), q.corner_uvs.len);
    try testing.expectEqual(@as(usize, 0), q.sharp_face.len);
    const t = p.objects[1];
    try testing.expectEqual(@as(usize, 3), t.corner_verts.len);
    try testing.expectEqual(@as(usize, 0), t.corner_uvs.len);
    try testing.expectEqual(true, t.sharp_face[0]);
    try testing.expectEqual(@as(u32, 1), t.slots[0]);
    try testing.expectEqualStrings("Blue", p.material_names[1]);
    // The line and the degenerate face are reported.
    try testing.expectEqual(@as(usize, 2), p.dropped.len);

    var mats = [_]ir.Material{ defaultMaterial("Red"), defaultMaterial("Blue") };
    var dropped: std.ArrayList([]const u8) = .empty;
    try parseMtl(arena, "newmtl Red\nKd 1 0 0\nNs 225\nd 0.5\nmap_Kd red.png\n", &mats, &dropped);
    try testing.expectEqual(@as(f32, 1), mats[0].base_color[0]);
    try testing.expectApproxEqAbs(@as(f32, 0.5), mats[0].roughness, 1e-6);
    try testing.expectEqual(@as(f32, 0.5), mats[0].alpha);
    try testing.expectEqual(@as(f32, 0.8), mats[1].base_color[0]);
    try testing.expectEqual(@as(usize, 1), dropped.items.len);
}
