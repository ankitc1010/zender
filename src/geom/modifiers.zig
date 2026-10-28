//! Modifier geometry (TRD §7): each modifier is a pure function from a mesh
//! and its settings (plus, for some, another object's evaluated mesh and
//! transform) to a new mesh. The stack and its dependencies are evaluated
//! by the depsgraph in src/eval. Results keep the UV map, smooth shading
//! and material slots; other generic attributes stay on the base mesh.

const std = @import("std");
const math = @import("math");
const core = @import("../core/root.zig");
const build = @import("build.zig");
const em_mod = @import("editmesh.zig");
const ops = @import("ops.zig");
const normals_mod = @import("normals.zig");

pub const subdivision = @import("modifiers/subdivision.zig");
pub const decimate = @import("modifiers/decimate.zig");
pub const noise = @import("modifiers/noise.zig");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const v = math.vec;
const Mesh = core.types.Mesh;
const Modifier = core.types.Modifier;
const EditMesh = em_mod.EditMesh;

pub const Purpose = enum { viewport, render };

pub const Target = struct {
    /// The target object's evaluated mesh (null for an empty or camera).
    mesh: ?*const Mesh,
    world: Mat4,
};

pub const Context = struct {
    /// The modified object's world matrix.
    world: Mat4,
    target: ?Target = null,
    purpose: Purpose = .render,
    stop: ?em_mod.Stop = null,
};

pub const Error = Allocator.Error || math.DeadlineError;

/// What a modifier did, besides its mesh.
pub const Note = enum {
    none,
    /// The modifier could not run (e.g. a boolean on an open mesh) and
    /// passed its input through.
    skipped,
    /// Its target object is missing or has no mesh.
    no_target,
    /// UVs were dropped (decimate).
    dropped_uvs,
    /// Bevel width was reduced so neighbouring cuts do not cross.
    width_reduced,
};

/// Applies `md` to `m`, returning a new mesh the caller owns.
pub fn apply(gpa: Allocator, m: *const Mesh, md: *const Modifier, ctx: Context, note: *Note) Error!Mesh {
    note.* = .none;
    return switch (md.kind) {
        .array => array(gpa, m, md, ctx),
        .mirror => mirror(gpa, m, md, ctx),
        .solidify => solidify(gpa, m, md),
        .subdivision => blk: {
            const levels: u32 = @intCast(std.math.clamp(if (ctx.purpose == .render) md.render_levels else md.levels, 0, 6));
            break :blk subdivision.subdivide(gpa, m, levels, md.subdivision_type == .simple, md.use_limit_surface, ctx.stop);
        },
        .bevel => bevelEdges(gpa, m, md, ctx, note),
        .boolean => booleanWith(gpa, m, md, ctx, note),
        .displace => displace(gpa, m, md, ctx),
        .decimate => blk: {
            if (m.attribute(Mesh.uv_name) != null) note.* = .dropped_uvs;
            break :blk decimate.collapse(gpa, m, md.ratio, ctx.stop);
        },
        .triangulate => triangulateAll(gpa, m, md, note),
    };
}

/// Face and corner data of a mesh in the forms modifiers carry along.
pub const Source = struct {
    m: *const Mesh,
    pos: []const Vec3,
    off: []const u32,
    cv: []const u32,
    uv: ?[]const [2]f32,
    sharp: ?[]const bool,
    mat: ?[]const i32,

    pub fn init(m: *const Mesh) Source {
        return .{
            .m = m,
            .pos = m.positions.slice(),
            .off = m.face_offsets.slice(),
            .cv = m.corner_verts.slice(),
            .uv = if (m.attribute(Mesh.uv_name)) |a| (if (a.domain == .corner and a.data == .float2) a.data.float2.slice() else null) else null,
            .sharp = if (m.attribute("sharp_face")) |a| (if (a.domain == .face and a.data == .boolean) a.data.boolean.slice() else null) else null,
            .mat = if (m.attribute("material_index")) |a| (if (a.domain == .face and a.data == .int) a.data.int.slice() else null) else null,
        };
    }

    pub fn faces(s: Source) usize {
        return if (s.off.len == 0) 0 else s.off.len - 1;
    }
    pub fn cornerUv(s: Source, c: usize) [2]f32 {
        return if (s.uv) |u| u[c] else .{ 0, 0 };
    }
    pub fn faceSharp(s: Source, f: usize) bool {
        return if (s.sharp) |x| x[f] else false;
    }
    pub fn faceMat(s: Source, f: usize) i32 {
        return if (s.mat) |x| x[f] else 0;
    }
};

/// Accumulates polygons, then builds a Mesh with the source's material slots.
pub const Builder = struct {
    gpa: Allocator,
    positions: std.ArrayList(Vec3) = .empty,
    offsets: std.ArrayList(u32) = .empty,
    corners: std.ArrayList(u32) = .empty,
    uvs: std.ArrayList([2]f32) = .empty,
    sharp: std.ArrayList(bool) = .empty,
    mat: std.ArrayList(i32) = .empty,
    with_uv: bool,

    pub fn init(gpa: Allocator, with_uv: bool) Builder {
        return .{ .gpa = gpa, .with_uv = with_uv };
    }

    pub fn deinit(b: *Builder) void {
        b.positions.deinit(b.gpa);
        b.offsets.deinit(b.gpa);
        b.corners.deinit(b.gpa);
        b.uvs.deinit(b.gpa);
        b.sharp.deinit(b.gpa);
        b.mat.deinit(b.gpa);
    }

    pub fn vert(b: *Builder, p: Vec3) Allocator.Error!u32 {
        try b.positions.append(b.gpa, p);
        return @intCast(b.positions.items.len - 1);
    }

    pub fn beginFace(b: *Builder) Allocator.Error!void {
        try b.offsets.append(b.gpa, @intCast(b.corners.items.len));
    }

    pub fn corner(b: *Builder, x: u32, uv: [2]f32) Allocator.Error!void {
        try b.corners.append(b.gpa, x);
        if (b.with_uv) try b.uvs.append(b.gpa, uv);
    }

    pub fn endFace(b: *Builder, sharp: bool, mat: i32) Allocator.Error!void {
        try b.sharp.append(b.gpa, sharp);
        try b.mat.append(b.gpa, mat);
    }

    pub fn finish(b: *Builder, src: *const Mesh) Error!Mesh {
        const n_faces = b.offsets.items.len;
        if (n_faces > 0) try b.offsets.append(b.gpa, @intCast(b.corners.items.len));
        var any_sharp = false;
        for (b.sharp.items) |x| any_sharp = any_sharp or x;
        var any_mat = false;
        for (b.mat.items) |x| any_mat = any_mat or x != 0;
        var m = build.fromPolygons(b.gpa, .{
            .positions = b.positions.items,
            .face_offsets = b.offsets.items,
            .corner_verts = b.corners.items,
            .corner_uvs = if (b.with_uv) b.uvs.items else &.{},
            .sharp_face = if (any_sharp) b.sharp.items else &.{},
            .material_index = if (any_mat) b.mat.items else &.{},
        }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            // Inputs come from valid meshes; nothing else can fail.
            else => unreachable,
        };
        m.materials.release(b.gpa);
        m.materials = src.materials.retain();
        return m;
    }

    /// Appends every face of `s` with vertices offset by `base` (which the
    /// caller has already added), optionally reversing the winding.
    pub fn copyFaces(b: *Builder, s: Source, map: []const u32, reverse: bool) Allocator.Error!void {
        for (0..s.faces()) |f| {
            try b.beginFace();
            const lo = s.off[f];
            const hi = s.off[f + 1];
            if (reverse) {
                var c = hi;
                while (c > lo) {
                    c -= 1;
                    try b.corner(map[s.cv[c]], s.cornerUv(c));
                }
            } else {
                for (lo..hi) |c| try b.corner(map[s.cv[c]], s.cornerUv(c));
            }
            try b.endFace(s.faceSharp(f), s.faceMat(f));
        }
    }
};

/// An unchanged copy of `m` (for modifiers that do nothing).
pub fn copy(m: *const Mesh) Mesh {
    var out = m.*;
    out.retainRefs();
    return out;
}

fn bounds(pos: []const Vec3) [2]Vec3 {
    if (pos.len == 0) return .{ .{ 0, 0, 0 }, .{ 0, 0, 0 } };
    var lo = pos[0];
    var hi = pos[0];
    for (pos[1..]) |p| {
        lo = v.min3(lo, p);
        hi = v.max3(hi, p);
    }
    return .{ lo, hi };
}

fn weld(gpa: Allocator, m: Mesh, threshold: f32) Error!Mesh {
    var mesh = m;
    defer mesh.releaseRefs(gpa);
    var em = EditMesh.fromMesh(gpa, &mesh) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    defer em.deinit();
    const all = try gpa.alloc(u32, em.verts.items.len);
    defer gpa.free(all);
    for (all, 0..) |*x, i| x.* = @intCast(i);
    var out = ops.merge.merge(&em, gpa, all, .identity, .{ .mode = .distance, .threshold = threshold }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return copy(&mesh),
    };
    out.deinit(gpa);
    var res = em.toMesh(gpa, null) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return copy(&mesh),
    };
    res.materials.release(gpa);
    res.materials = mesh.materials.retain();
    return res;
}

/// Copies stepped by an offset: the mesh's size times relative_offset,
/// plus constant_offset, then (with a target) the target's transform
/// relative to the object, applied again for each copy.
fn array(gpa: Allocator, m: *const Mesh, md: *const Modifier, ctx: Context) Error!Mesh {
    const s = Source.init(m);
    const count: usize = @intCast(std.math.clamp(md.count, 1, 1000));
    const bb = bounds(s.pos);
    const size = v.sub(bb[1], bb[0]);
    var step = v.compose(v.add(v.mul(md.relative_offset, size), md.constant_offset), v.quat_identity, .{ 1, 1, 1 });
    if (ctx.target) |t| if (v.invert(ctx.world)) |inv| {
        step = v.matMul(step, v.matMul(inv, t.world));
    };
    var b = Builder.init(gpa, s.uv != null);
    defer b.deinit();
    const map = try gpa.alloc(u32, s.pos.len);
    defer gpa.free(map);
    var xf: Mat4 = v.identity;
    for (0..count) |_| {
        if (ctx.stop) |st| if (st.deadline.passed(st.io)) return error.DeadlineExceeded;
        for (s.pos, map) |p, *x| x.* = try b.vert(v.transformPoint(xf, p));
        try b.copyFaces(s, map, false);
        xf = v.matMul(step, xf);
    }
    const out = try b.finish(m);
    return if (md.merge) weld(gpa, out, md.merge_threshold) else out;
}

/// Mirrors across the enabled local planes (of the target object, when
/// set), welding vertices within merge_threshold of a plane.
fn mirror(gpa: Allocator, m: *const Mesh, md: *const Modifier, ctx: Context) Error!Mesh {
    var frame: Mat4 = v.identity;
    if (ctx.target) |t| if (v.invert(ctx.world)) |inv| {
        frame = v.matMul(inv, t.world);
    };
    const frame_inv = v.invert(frame) orelse v.identity;
    var cur = copy(m);
    errdefer cur.releaseRefs(gpa);
    for ([3]bool{ md.axis_x, md.axis_y, md.axis_z }, 0..) |on, axis| {
        if (!on) continue;
        const next = try mirrorAxis(gpa, &cur, axis, frame, frame_inv, if (md.merge) md.merge_threshold else -1);
        cur.releaseRefs(gpa);
        cur = next;
    }
    return cur;
}

fn mirrorAxis(gpa: Allocator, m: *const Mesh, axis: usize, frame: Mat4, frame_inv: Mat4, threshold: f32) Error!Mesh {
    const s = Source.init(m);
    var b = Builder.init(gpa, s.uv != null);
    defer b.deinit();
    const n = s.pos.len;
    const map = try gpa.alloc(u32, n);
    defer gpa.free(map);
    const mirrored = try gpa.alloc(u32, n);
    defer gpa.free(mirrored);
    // Vertices on the plane are shared by both halves, snapped onto it.
    for (s.pos, map, mirrored) |p, *x, *y| {
        var q = v.transformPoint(frame_inv, p);
        if (threshold >= 0 and @abs(q[axis]) <= threshold) {
            q[axis] = 0;
            x.* = try b.vert(v.transformPoint(frame, q));
            y.* = x.*;
        } else {
            x.* = try b.vert(p);
            y.* = std.math.maxInt(u32);
        }
    }
    for (s.pos, mirrored) |p, *y| {
        if (y.* != std.math.maxInt(u32)) continue;
        var q = v.transformPoint(frame_inv, p);
        q[axis] = -q[axis];
        y.* = try b.vert(v.transformPoint(frame, q));
    }
    try b.copyFaces(s, map, false);
    // The mirrored half winds the other way; faces lying in the plane
    // would only duplicate their originals.
    for (0..s.faces()) |f| {
        var flat = true;
        for (s.cv[s.off[f]..s.off[f + 1]]) |x| flat = flat and mirrored[x] == map[x];
        if (flat) continue;
        try b.beginFace();
        var c = s.off[f + 1];
        while (c > s.off[f]) {
            c -= 1;
            try b.corner(mirrored[s.cv[c]], s.cornerUv(c));
        }
        try b.endFace(s.faceSharp(f), s.faceMat(f));
    }
    return b.finish(m);
}

/// Vertex normals as Blender computes them: face normals weighted by the
/// corner angle. As in Blender, a zero-area face faces +Z, a corner with a
/// zero-length edge weighs a right angle, and a vertex whose faces cancel
/// out (or a loose one) takes the direction of its position, so solidify
/// and displace move degenerate spots alike.
pub fn vertexNormals(gpa: Allocator, s: Source) Allocator.Error![]Vec3 {
    const out = try gpa.alloc(Vec3, s.pos.len);
    @memset(out, .{ 0, 0, 0 });
    for (0..s.faces()) |f| {
        const cs = s.cv[s.off[f]..s.off[f + 1]];
        const n = normals_mod.faceNormal(s.pos, cs);
        for (cs, 0..) |x, k| {
            const p = s.pos[x];
            const a = v.normalize(v.sub(s.pos[cs[if (k == 0) cs.len - 1 else k - 1]], p));
            const b = v.normalize(v.sub(s.pos[cs[if (k + 1 == cs.len) 0 else k + 1]], p));
            out[x] = v.add(out[x], v.scale(n, std.math.acos(std.math.clamp(v.dot(a, b), -1.0, 1.0))));
        }
    }
    for (out, s.pos) |*n, p| n.* = normals_mod.vertexNormal(n.*, p);
    return out;
}

/// A shell: the surface and a copy offset along the vertex normals, wound
/// the other way, joined by a rim along open edges.
fn solidify(gpa: Allocator, m: *const Mesh, md: *const Modifier) Error!Mesh {
    const s = Source.init(m);
    const normals = try vertexNormals(gpa, s);
    defer gpa.free(normals);
    var b = Builder.init(gpa, s.uv != null);
    defer b.deinit();
    const n = s.pos.len;
    const outer = try gpa.alloc(u32, n);
    defer gpa.free(outer);
    const inner = try gpa.alloc(u32, n);
    defer gpa.free(inner);
    const t = md.thickness;
    const off = std.math.clamp(md.offset, -1, 1);
    for (s.pos, normals, outer) |p, nn, *x| x.* = try b.vert(v.add(p, v.scale(nn, t * (off + 1) / 2)));
    for (s.pos, normals, inner) |p, nn, *x| x.* = try b.vert(v.add(p, v.scale(nn, t * (off - 1) / 2)));
    try b.copyFaces(s, outer, false);
    try b.copyFaces(s, inner, true);
    // Rim quads on edges used by one face.
    var uses: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer uses.deinit(gpa);
    for (0..s.faces()) |f| {
        const lo = s.off[f];
        const hi = s.off[f + 1];
        for (lo..hi) |c| {
            const a = s.cv[c];
            const z = s.cv[if (c + 1 == hi) lo else c + 1];
            const gop = try uses.getOrPut(gpa, edgeKey(a, z));
            gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        }
    }
    for (0..s.faces()) |f| {
        const lo = s.off[f];
        const hi = s.off[f + 1];
        for (lo..hi) |c| {
            const cn = if (c + 1 == hi) lo else c + 1;
            const a = s.cv[c];
            const z = s.cv[cn];
            if (uses.get(edgeKey(a, z)).? != 1) continue;
            try b.beginFace();
            try b.corner(outer[z], s.cornerUv(cn));
            try b.corner(outer[a], s.cornerUv(c));
            try b.corner(inner[a], s.cornerUv(c));
            try b.corner(inner[z], s.cornerUv(cn));
            try b.endFace(s.faceSharp(f), s.faceMat(f));
        }
    }
    return b.finish(m);
}

fn edgeKey(a: u32, b: u32) u64 {
    return @as(u64, @min(a, b)) << 32 | @max(a, b);
}

/// Moves vertices along their normals by strength × (texture − mid_level);
/// with no texture the value is 1, as in Blender.
fn displace(gpa: Allocator, m: *const Mesh, md: *const Modifier, ctx: Context) Error!Mesh {
    const s = Source.init(m);
    const normals = try vertexNormals(gpa, s);
    defer gpa.free(normals);
    var out = copy(m);
    errdefer out.releaseRefs(gpa);
    const pos = try out.positions.mut(gpa);
    for (pos, normals, 0..) |*p, n, i| {
        if (i % 4096 == 0) if (ctx.stop) |st| if (st.deadline.passed(st.io)) return error.DeadlineExceeded;
        const value: f32 = switch (md.texture) {
            .none => 1,
            .noise => noise.fbm(v.scale(p.*, 1 / @max(md.noise_scale, 1e-4)), @intCast(md.noise_seed)),
            .recipe => md.recipe.scalar(p.*),
        };
        p.* = v.add(p.*, v.scale(n, md.strength * (value - md.mid_level)));
    }
    return out;
}

/// Bevels the edges whose faces meet at more than angle_limit, leaving out
/// edges at open borders (bevel needs a closed fan at each vertex).
fn bevelEdges(gpa: Allocator, m: *const Mesh, md: *const Modifier, ctx: Context, note: *Note) Error!Mesh {
    var em = EditMesh.fromMesh(gpa, m) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            note.* = .skipped;
            return copy(m);
        },
    };
    defer em.deinit();
    em.stop = ctx.stop;
    var open: std.DynamicBitSetUnmanaged = try .initEmpty(gpa, em.verts.items.len);
    defer open.deinit(gpa);
    for (em.edges.items, 0..) |e, i| if (em.edgeFaceCount(@intCast(i)) != 2) {
        open.set(e.v[0]);
        open.set(e.v[1]);
    };
    var edges: std.ArrayList(u32) = .empty;
    defer edges.deinit(gpa);
    const cos_limit = @cos(md.angle_limit);
    for (em.edges.items, 0..) |e, i| {
        if (open.isSet(e.v[0]) or open.isSet(e.v[1])) continue;
        const l = e.l;
        const r = em.loops.items[l].radial_next;
        const n0 = em.faceNormal(em.loops.items[l].f);
        const n1 = em.faceNormal(em.loops.items[r].f);
        if (v.dot(n0, n1) < cos_limit) try edges.append(gpa, @intCast(i));
    }
    if (edges.items.len == 0) return copy(m);
    const world_xf = ops.Xform.init(ctx.world) orelse ops.Xform.identity;
    var out = ops.bevel.bevel(&em, gpa, edges.items, world_xf, .{ .width = md.width, .segments = @intCast(std.math.clamp(md.segments, 1, 64)) }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DeadlineExceeded => return error.DeadlineExceeded,
        else => {
            note.* = .skipped;
            return copy(m);
        },
    };
    if (out.width_used < md.width) note.* = .width_reduced;
    out.deinit(gpa);
    return toMesh(gpa, &em, m, note);
}

fn toMesh(gpa: Allocator, em: *const EditMesh, src: *const Mesh, note: *Note) Error!Mesh {
    var res = em.toMesh(gpa, null) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            note.* = .skipped;
            return copy(src);
        },
    };
    res.materials.release(gpa);
    res.materials = src.materials.retain();
    return res;
}

fn booleanWith(gpa: Allocator, m: *const Mesh, md: *const Modifier, ctx: Context, note: *Note) Error!Mesh {
    const t = ctx.target orelse {
        note.* = .no_target;
        return copy(m);
    };
    const tm = t.mesh orelse {
        note.* = .no_target;
        return copy(m);
    };
    var failure: ops.boolean.Failure = .none;
    const op: ops.boolean.Op = switch (md.operation) {
        .difference => .difference,
        .@"union" => .union_,
        .intersect => .intersect,
    };
    var out = ops.boolean.apply(gpa, .{ .mesh = m, .world = ctx.world }, .{ .mesh = tm, .world = t.world }, op, &failure) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            note.* = .skipped;
            return copy(m);
        },
    };
    gpa.free(out.from_operand);
    out.from_operand = &.{};
    return out.mesh;
}

fn triangulateAll(gpa: Allocator, m: *const Mesh, md: *const Modifier, note: *Note) Error!Mesh {
    var em = EditMesh.fromMesh(gpa, m) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            note.* = .skipped;
            return copy(m);
        },
    };
    defer em.deinit();
    var faces: std.ArrayList(u32) = .empty;
    defer faces.deinit(gpa);
    for (em.faces.items, 0..) |f, i| if (!f.removed and f.len > 3) try faces.append(gpa, @intCast(i));
    if (faces.items.len == 0) return copy(m);
    var out = ops.triangulate.triangulate(&em, gpa, faces.items, .{
        .quad = @enumFromInt(@intFromEnum(md.quad_method)),
        .ngon = @enumFromInt(@intFromEnum(md.ngon_method)),
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            note.* = .skipped;
            return copy(m);
        },
    };
    out.deinit(gpa);
    return toMesh(gpa, &em, m, note);
}

test {
    _ = subdivision;
    _ = decimate;
    _ = noise;
}

const testing = std.testing;
const prims = @import("primitives.zig");

fn applyKind(gpa: Allocator, m: *const Mesh, md: Modifier, ctx: Context) !Mesh {
    var note: Note = .none;
    const out = try apply(gpa, m, &md, ctx, &note);
    try testing.expect(build.validate(&out) == null);
    return out;
}

test "array, mirror, solidify, displace and triangulate" {
    const gpa = testing.allocator;
    var cube = try prims.generate(gpa, .cube, .{});
    defer cube.releaseRefs(gpa);
    const ctx: Context = .{ .world = v.identity };

    var arr = try applyKind(gpa, &cube, .{ .kind = .array, .count = 3, .merge = false }, ctx);
    defer arr.releaseRefs(gpa);
    try testing.expectEqual(@as(usize, 18), arr.faceCount());
    // Touching copies weld when merging.
    var arr2 = try applyKind(gpa, &cube, .{ .kind = .array, .count = 3, .merge = true }, ctx);
    defer arr2.releaseRefs(gpa);
    try testing.expectEqual(@as(usize, 16), arr2.vertCount());

    // Mirroring a half-cube (x >= 0) across X welds the seam.
    var half = try prims.generate(gpa, .grid, .{ .x_subdivisions = 2, .y_subdivisions = 2 });
    defer half.releaseRefs(gpa);
    var mir = try applyKind(gpa, &half, .{ .kind = .mirror }, ctx);
    defer mir.releaseRefs(gpa);
    try testing.expectEqual(@as(usize, 8), mir.faceCount());
    try testing.expectEqual(@as(usize, 15), mir.vertCount());

    var shell = try applyKind(gpa, &half, .{ .kind = .solidify, .thickness = 0.1 }, ctx);
    defer shell.releaseRefs(gpa);
    // 4 + 4 faces and a rim of 8 quads round the open border.
    try testing.expectEqual(@as(usize, 16), shell.faceCount());

    var disp = try applyKind(gpa, &cube, .{ .kind = .displace, .strength = 0.2 }, ctx);
    defer disp.releaseRefs(gpa);
    // Value 1, mid 0.5: every corner moves 0.1 outward.
    try testing.expectApproxEqAbs(@as(f32, @sqrt(3.0) + 0.1), v.length(disp.positions.slice()[0]), 1e-5);

    var tri = try applyKind(gpa, &cube, .{ .kind = .triangulate }, ctx);
    defer tri.releaseRefs(gpa);
    try testing.expectEqual(@as(usize, 12), tri.faceCount());
}
