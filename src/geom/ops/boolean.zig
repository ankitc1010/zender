//! Booleans (FR-GEO-4): union, difference and intersection of two closed
//! meshes through Manifold (decision Q3: robust rather than exact; serial,
//! so a result never depends on the thread count). Both meshes are
//! triangulated in world space and every triangle carries the id of its
//! source face to the result. Faces are then rebuilt: the result triangles
//! of one source face that form one region with a single boundary become
//! one polygon again (a region with a hole through it stays triangles), UVs
//! are interpolated in the source triangle, smooth shading and material
//! slots follow the source face, and the operand's materials join the
//! target's slots. Built only with Manifold (not on wasm32 or with
//! -Dboolean=none).

const std = @import("std");
const math = @import("math");
const core = @import("../../core/root.zig");
const build = @import("../build.zig");
const engine_options = @import("engine_options");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const v = math.vec;
const Mesh = core.types.Mesh;
const IdHandle = core.IdHandle;

pub const available = engine_options.boolean;

pub const Op = enum(c_int) { union_ = 0, difference = 1, intersect = 2 };

pub const Failure = enum {
    none,
    /// Not a closed, consistently wound surface even after welding.
    not_manifold_target,
    not_manifold_operand,
    /// Non-finite or otherwise unusable input.
    invalid_target,
    invalid_operand,
    too_large,
    other,
};

pub const Error = Allocator.Error || error{ Unavailable, BooleanFailed, InvalidTopology, TooManyAttributes };

pub const Operand = struct {
    mesh: *const Mesh,
    world: Mat4,
};

pub const Applied = struct {
    /// The result in the target's local space, material slots included.
    mesh: Mesh,
    /// Faces of `mesh` that came from the operand, ascending.
    from_operand: []u32,

    pub fn deinit(a: *Applied, gpa: Allocator) void {
        a.mesh.releaseRefs(gpa);
        gpa.free(a.from_operand);
    }
};

/// Where a triangle came from: side 0 is the target, 1 the operand; the
/// face, and the face's corners at the triangle's three vertices.
const Source = struct { side: u1, face: u32, corners: [3]u32 };

const Raw = struct {
    positions: [][3]f64,
    tris: [][3]u32,
    ids: []u32,

    fn deinit(r: *Raw, gpa: Allocator) void {
        gpa.free(r.positions);
        gpa.free(r.tris);
        gpa.free(r.ids);
    }
};

/// Computes `target op operand` and rebuilds it as a mesh in the target's
/// local space. On error.BooleanFailed, `failure` says why.
pub fn apply(gpa: Allocator, target: Operand, operand: Operand, op: Op, failure: *Failure) Error!Applied {
    failure.* = .none;
    if (comptime !available) return error.Unavailable else return applyWith(gpa, target, operand, op, failure);
}

fn applyWith(gpa: Allocator, target: Operand, operand: Operand, op: Op, failure: *Failure) Error!Applied {
    var sources: std.ArrayList(Source) = .empty;
    defer sources.deinit(gpa);
    var in: [2]Input = .{ .{}, .{} };
    defer for (&in) |*x| x.deinit(gpa);
    try triangulate(gpa, target, 0, &in[0], &sources);
    try triangulate(gpa, operand, 1, &in[1], &sources);
    var raw = try compute(gpa, &in[0], &in[1], op, failure);
    defer raw.deinit(gpa);
    return rebuild(gpa, target, operand, &raw, sources.items, &in);
}

const Input = struct {
    positions: std.ArrayList([3]f64) = .empty,
    tris: std.ArrayList([3]u32) = .empty,
    ids: std.ArrayList(u32) = .empty,

    fn deinit(x: *Input, gpa: Allocator) void {
        x.positions.deinit(gpa);
        x.tris.deinit(gpa);
        x.ids.deinit(gpa);
    }
};

fn toWorld(m: Mat4, p: Vec3) [3]f64 {
    var out: [3]f64 = undefined;
    for (0..3) |r| {
        out[r] = @as(f64, m[r]) * p[0] + @as(f64, m[4 + r]) * p[1] + @as(f64, m[8 + r]) * p[2] + @as(f64, m[12 + r]);
    }
    return out;
}

fn triangulate(gpa: Allocator, x: Operand, side: u1, out: *Input, sources: *std.ArrayList(Source)) Allocator.Error!void {
    const m = x.mesh;
    const pos = m.positions.slice();
    const off = m.face_offsets.slice();
    const cv = m.corner_verts.slice();
    const world = try gpa.alloc(Vec3, pos.len);
    defer gpa.free(world);
    try out.positions.ensureTotalCapacity(gpa, pos.len);
    for (pos, world) |p, *w| {
        const q = toWorld(x.world, p);
        out.positions.appendAssumeCapacity(q);
        w.* = .{ @floatCast(q[0]), @floatCast(q[1]), @floatCast(q[2]) };
    }
    var flat: std.ArrayList(u32) = .empty;
    defer flat.deinit(gpa);
    for (0..m.faceCount()) |f| {
        flat.clearRetainingCapacity();
        try math.triangulate.triangulate(gpa, world, cv[off[f]..off[f + 1]], &flat);
        var i: usize = 0;
        while (i + 2 < flat.items.len) : (i += 3) {
            const c: [3]u32 = .{ off[f] + flat.items[i], off[f] + flat.items[i + 1], off[f] + flat.items[i + 2] };
            try out.tris.append(gpa, .{ cv[c[0]], cv[c[1]], cv[c[2]] });
            try out.ids.append(gpa, @intCast(sources.items.len));
            try sources.append(gpa, .{ .side = side, .face = @intCast(f), .corners = c });
        }
    }
}

const zm = struct {
    const Mesh_ = extern struct {
        pos: [*]const f64,
        n_verts: u32,
        tris: [*]const u32,
        n_tris: u32,
        tri_id: [*]const u32,
    };
    const Result = opaque {};
    extern fn zm_boolean(a: *const Mesh_, b: *const Mesh_, op: c_int, out: *?*Result) c_int;
    extern fn zm_result_verts(r: *const Result, pos: *[*]const f64) u32;
    extern fn zm_result_tris(r: *const Result, tris: *[*]const u32, ids: *[*]const u32) u32;
    extern fn zm_result_free(r: *Result) void;
};

fn compute(gpa: Allocator, a: *const Input, b: *const Input, op: Op, failure: *Failure) Error!Raw {
    const ma: zm.Mesh_ = .{ .pos = @ptrCast(a.positions.items.ptr), .n_verts = @intCast(a.positions.items.len), .tris = @ptrCast(a.tris.items.ptr), .n_tris = @intCast(a.tris.items.len), .tri_id = a.ids.items.ptr };
    const mb: zm.Mesh_ = .{ .pos = @ptrCast(b.positions.items.ptr), .n_verts = @intCast(b.positions.items.len), .tris = @ptrCast(b.tris.items.ptr), .n_tris = @intCast(b.tris.items.len), .tri_id = b.ids.items.ptr };
    var res: ?*zm.Result = null;
    const s = zm.zm_boolean(&ma, &mb, @intFromEnum(op), &res);
    if (s != 0) {
        // Offsets from shim.h; Manifold::Error 2 is NotManifold, 12 ResultTooLarge.
        if (s == 1) return error.OutOfMemory;
        failure.* = if (s == 102)
            .not_manifold_target
        else if (s == 202)
            .not_manifold_operand
        else if (s > 100 and s < 200)
            .invalid_target
        else if (s > 200 and s < 300)
            .invalid_operand
        else if (s == 312)
            .too_large
        else
            .other;
        return error.BooleanFailed;
    }
    defer zm.zm_result_free(res.?);
    var pos: [*]const f64 = undefined;
    const nv = zm.zm_result_verts(res.?, &pos);
    var tris: [*]const u32 = undefined;
    var ids: [*]const u32 = undefined;
    const nt = zm.zm_result_tris(res.?, &tris, &ids);

    // Weld vertices Manifold may list more than once.
    var map: std.AutoHashMapUnmanaged([3]u64, u32) = .empty;
    defer map.deinit(gpa);
    const remap = try gpa.alloc(u32, nv);
    defer gpa.free(remap);
    var out_pos: std.ArrayList([3]f64) = .empty;
    errdefer out_pos.deinit(gpa);
    for (0..nv) |i| {
        const p: [3]f64 = .{ pos[3 * i], pos[3 * i + 1], pos[3 * i + 2] };
        const gop = try map.getOrPut(gpa, .{ @bitCast(p[0] + 0), @bitCast(p[1] + 0), @bitCast(p[2] + 0) });
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(out_pos.items.len);
            try out_pos.append(gpa, p);
        }
        remap[i] = gop.value_ptr.*;
    }
    var out_tris: std.ArrayList([3]u32) = .empty;
    errdefer out_tris.deinit(gpa);
    var out_ids: std.ArrayList(u32) = .empty;
    errdefer out_ids.deinit(gpa);
    for (0..nt) |t| {
        const tri: [3]u32 = .{ remap[tris[3 * t]], remap[tris[3 * t + 1]], remap[tris[3 * t + 2]] };
        if (tri[0] == tri[1] or tri[1] == tri[2] or tri[0] == tri[2]) continue;
        try out_tris.append(gpa, tri);
        try out_ids.append(gpa, ids[t]);
    }
    return .{ .positions = try out_pos.toOwnedSlice(gpa), .tris = try out_tris.toOwnedSlice(gpa), .ids = try out_ids.toOwnedSlice(gpa) };
}

fn find(parent: []u32, i: u32) u32 {
    var r = i;
    while (parent[r] != r) r = parent[r];
    var x = i;
    while (parent[x] != r) {
        const n = parent[x];
        parent[x] = r;
        x = n;
    }
    return r;
}

fn edgeKey(a: u32, b: u32) u64 {
    return @as(u64, a) << 32 | b;
}

fn sub3(a: [3]f64, b: [3]f64) [3]f64 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
fn cross3(a: [3]f64, b: [3]f64) [3]f64 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
fn dot3(a: [3]f64, b: [3]f64) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

/// Barycentric weights of `q` in triangle `t` (projected onto its plane).
fn barycentric(t: [3][3]f64, q: [3]f64) [3]f64 {
    const n = cross3(sub3(t[1], t[0]), sub3(t[2], t[0]));
    const nn = dot3(n, n);
    if (nn == 0) return .{ 1, 0, 0 };
    const w0 = dot3(cross3(sub3(t[1], q), sub3(t[2], q)), n) / nn;
    const w1 = dot3(cross3(sub3(t[2], q), sub3(t[0], q)), n) / nn;
    return .{ w0, w1, 1 - w0 - w1 };
}

fn faceAttr(comptime T: type, m: *const Mesh, name: []const u8) ?[]const T {
    const a = m.attribute(name) orelse return null;
    if (a.domain != (if (T == [2]f32) core.types.Domain.corner else core.types.Domain.face)) return null;
    return switch (a.data) {
        .boolean => |d| if (T == bool) d.slice() else null,
        .int => |d| if (T == i32) d.slice() else null,
        .float2 => |d| if (T == [2]f32) d.slice() else null,
        else => null,
    };
}

fn rebuild(gpa: Allocator, target: Operand, operand: Operand, raw: *const Raw, sources: []const Source, in: *const [2]Input) Error!Applied {
    const meshes = [2]*const Mesh{ target.mesh, operand.mesh };
    const nt = raw.tris.len;
    // Join result triangles from the same source face that share an edge.
    const parent = try gpa.alloc(u32, nt);
    defer gpa.free(parent);
    for (parent, 0..) |*p, i| p.* = @intCast(i);
    var edge_tri: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer edge_tri.deinit(gpa);
    try edge_tri.ensureTotalCapacity(gpa, @intCast(3 * nt));
    for (raw.tris, 0..) |t, i| for (0..3) |k| {
        const a = t[k];
        const b = t[(k + 1) % 3];
        edge_tri.putAssumeCapacity(edgeKey(a, b), @intCast(i));
    };
    for (raw.tris, 0..) |t, i| for (0..3) |k| {
        const j = edge_tri.get(edgeKey(t[(k + 1) % 3], t[k])) orelse continue;
        const si = sources[raw.ids[i]];
        const sj = sources[raw.ids[j]];
        if (si.side != sj.side or si.face != sj.face) continue;
        const ri = find(parent, @intCast(i));
        const rj = find(parent, j);
        if (ri != rj) parent[@max(ri, rj)] = @min(ri, rj);
    };
    // Components in order of their first triangle (counting sort by root).
    const start = try gpa.alloc(u32, nt + 1);
    defer gpa.free(start);
    @memset(start, 0);
    for (0..nt) |i| start[find(parent, @intCast(i)) + 1] += 1;
    for (1..start.len) |i| start[i] += start[i - 1];
    const members = try gpa.alloc(u32, nt);
    defer gpa.free(members);
    const fill = try gpa.dupe(u32, start[0..nt]);
    defer gpa.free(fill);
    for (0..nt) |i| {
        const r = find(parent, @intCast(i));
        members[fill[r]] = @intCast(i);
        fill[r] += 1;
    }

    const uvs = [2]?[]const [2]f32{ faceAttr([2]f32, meshes[0], Mesh.uv_name), faceAttr([2]f32, meshes[1], Mesh.uv_name) };
    const sharp = [2]?[]const bool{ faceAttr(bool, meshes[0], "sharp_face"), faceAttr(bool, meshes[1], "sharp_face") };
    const mat_index = [2]?[]const i32{ faceAttr(i32, meshes[0], "material_index"), faceAttr(i32, meshes[1], "material_index") };
    const with_uv = uvs[0] != null or uvs[1] != null;

    // The operand's slots join the target's: the same material reuses its
    // slot, any other is appended.
    var slots: std.ArrayList(?IdHandle) = .empty;
    defer slots.deinit(gpa);
    try slots.appendSlice(gpa, meshes[0].materials.slice());
    if (slots.items.len == 0) try slots.append(gpa, null);
    const op_slots = meshes[1].materials.slice();
    const slot_map = try gpa.alloc(i32, @max(op_slots.len, 1));
    defer gpa.free(slot_map);
    for (slot_map, 0..) |*sm, s| {
        const want: ?IdHandle = if (s < op_slots.len) op_slots[s] else null;
        var found: ?usize = null;
        for (slots.items, 0..) |have, i| {
            const same = if (have) |h| (if (want) |w| h.eql(w) else false) else want == null;
            if (same) {
                found = i;
                break;
            }
        }
        sm.* = @intCast(found orelse blk: {
            try slots.append(gpa, want);
            break :blk slots.items.len - 1;
        });
    }

    var offsets: std.ArrayList(u32) = .empty;
    defer offsets.deinit(gpa);
    var corners: std.ArrayList(u32) = .empty;
    defer corners.deinit(gpa);
    var corner_uvs: std.ArrayList([2]f32) = .empty;
    defer corner_uvs.deinit(gpa);
    var face_sharp: std.ArrayList(bool) = .empty;
    defer face_sharp.deinit(gpa);
    var face_mat: std.ArrayList(i32) = .empty;
    defer face_mat.deinit(gpa);
    var from_operand: std.ArrayList(u32) = .empty;
    errdefer from_operand.deinit(gpa);
    var next: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer next.deinit(gpa);
    var inner: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer inner.deinit(gpa);
    var loop: std.ArrayList(u32) = .empty;
    defer loop.deinit(gpa);

    var c: usize = 0;
    while (c < nt) : (c += 1) {
        if (start[c] == start[c + 1]) continue;
        const comp = members[start[c]..start[c + 1]];
        const src = sources[raw.ids[comp[0]]];
        // One polygon when the region's boundary is one simple loop.
        loop.clearRetainingCapacity();
        if (comp.len > 1) {
            inner.clearRetainingCapacity();
            next.clearRetainingCapacity();
            for (comp) |t| for (0..3) |k| try inner.put(gpa, edgeKey(raw.tris[t][k], raw.tris[t][(k + 1) % 3]), {});
            var simple = true;
            var n_boundary: usize = 0;
            var first: u32 = undefined;
            for (comp) |t| for (0..3) |k| {
                const a = raw.tris[t][k];
                const b = raw.tris[t][(k + 1) % 3];
                if (inner.contains(edgeKey(b, a))) continue;
                const gop = try next.getOrPut(gpa, a);
                if (gop.found_existing) simple = false;
                gop.value_ptr.* = b;
                if (n_boundary == 0) first = a;
                n_boundary += 1;
            };
            if (simple and n_boundary >= 3) {
                var x = first;
                while (loop.items.len <= n_boundary) {
                    try loop.append(gpa, x);
                    x = next.get(x) orelse break;
                    if (x == first) break;
                }
                if (loop.items.len != n_boundary or x != first) loop.clearRetainingCapacity();
            }
        }
        const polys: usize = if (loop.items.len > 0) 1 else comp.len;
        for (0..polys) |pi| {
            const vs: []const u32 = if (loop.items.len > 0) loop.items else &raw.tris[comp[pi]];
            try offsets.append(gpa, @intCast(corners.items.len));
            for (vs) |x| {
                try corners.append(gpa, x);
                if (!with_uv) continue;
                // UV from a source triangle of this face at this vertex.
                var s = sources[raw.ids[comp[0]]];
                for (comp) |t| if (std.mem.indexOfScalar(u32, &raw.tris[t], x) != null) {
                    s = sources[raw.ids[t]];
                    break;
                };
                const uv = uvs[s.side] orelse {
                    try corner_uvs.append(gpa, .{ 0, 0 });
                    continue;
                };
                const sm = meshes[s.side];
                const scv = sm.corner_verts.slice();
                var tri: [3][3]f64 = undefined;
                for (&tri, s.corners) |*p, k| p.* = in[s.side].positions.items[scv[k]];
                const w = barycentric(tri, raw.positions[x]);
                var acc: [2]f64 = .{ 0, 0 };
                for (s.corners, w) |k, wk| {
                    acc[0] += wk * uv[k][0];
                    acc[1] += wk * uv[k][1];
                }
                try corner_uvs.append(gpa, .{ @floatCast(acc[0]), @floatCast(acc[1]) });
            }
            const face: u32 = @intCast(offsets.items.len - 1);
            if (src.side == 1) try from_operand.append(gpa, face);
            try face_sharp.append(gpa, if (sharp[src.side]) |a| a[src.face] else false);
            const local_slot: i32 = if (mat_index[src.side]) |a| a[src.face] else 0;
            try face_mat.append(gpa, if (src.side == 0) local_slot else slot_map[@intCast(std.math.clamp(local_slot, 0, @as(i32, @intCast(slot_map.len - 1))))]);
        }
    }
    if (offsets.items.len > 0) try offsets.append(gpa, @intCast(corners.items.len));

    // Back into the target's local space.
    const inv = v.invert(target.world) orelse v.identity;
    const positions = try gpa.alloc(Vec3, raw.positions.len);
    defer gpa.free(positions);
    for (raw.positions, positions) |p, *o| {
        const q = toWorld(inv, .{ @floatCast(p[0]), @floatCast(p[1]), @floatCast(p[2]) });
        o.* = .{ @floatCast(q[0]), @floatCast(q[1]), @floatCast(q[2]) };
    }
    var any_mat = false;
    for (face_mat.items) |m| any_mat = any_mat or m != 0;
    var mesh = try build.fromPolygons(gpa, .{
        .positions = positions,
        .face_offsets = offsets.items,
        .corner_verts = corners.items,
        .corner_uvs = if (with_uv) corner_uvs.items else &.{},
        .sharp_face = face_sharp.items,
        .material_index = if (any_mat) face_mat.items else &.{},
    });
    errdefer mesh.releaseRefs(gpa);
    mesh.materials.release(gpa);
    mesh.materials = try .fromSlice(gpa, slots.items);
    return .{ .mesh = mesh, .from_operand = try from_operand.toOwnedSlice(gpa) };
}

const testing = std.testing;
const prims = @import("../primitives.zig");

/// Volume enclosed by a closed mesh (divergence theorem over fan triangles).
fn volume(m: *const Mesh) f64 {
    const pos = m.positions.slice();
    const off = m.face_offsets.slice();
    const cv = m.corner_verts.slice();
    var vol: f64 = 0;
    for (0..m.faceCount()) |f| {
        const p0 = pos[cv[off[f]]];
        for (off[f] + 1..off[f + 1] - 1) |c| {
            const a = pos[cv[c]];
            const b = pos[cv[c + 1]];
            vol += @as(f64, p0[0]) * (@as(f64, a[1]) * b[2] - @as(f64, a[2]) * b[1]) -
                @as(f64, p0[1]) * (@as(f64, a[0]) * b[2] - @as(f64, a[2]) * b[0]) +
                @as(f64, p0[2]) * (@as(f64, a[0]) * b[1] - @as(f64, a[1]) * b[0]);
        }
    }
    return vol / 6;
}

test "cube with a cube: union, difference and intersection volumes" {
    if (!available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var cube = try prims.generate(gpa, .cube, .{});
    defer cube.releaseRefs(gpa);
    const shifted = v.compose(.{ 1, 1, 1 }, v.quat_identity, .{ 1, 1, 1 });
    const cases = [_]struct { op: Op, vol: f64, faces: usize }{
        .{ .op = .union_, .vol = 15, .faces = 12 },
        .{ .op = .difference, .vol = 7, .faces = 9 },
        .{ .op = .intersect, .vol = 1, .faces = 6 },
    };
    for (cases) |cs| {
        var failure: Failure = .none;
        var out = try apply(gpa, .{ .mesh = &cube, .world = v.identity }, .{ .mesh = &cube, .world = shifted }, cs.op, &failure);
        defer out.deinit(gpa);
        try testing.expect(build.validate(&out.mesh) == null);
        try testing.expectApproxEqAbs(cs.vol, volume(&out.mesh), 1e-5);
        // Coplanar triangles of one source face come back as one polygon.
        try testing.expectEqual(cs.faces, out.mesh.faceCount());
        try testing.expect(out.mesh.attribute(Mesh.uv_name) != null);
    }
}

test "an open operand is refused" {
    if (!available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var cube = try prims.generate(gpa, .cube, .{});
    defer cube.releaseRefs(gpa);
    var plane = try prims.generate(gpa, .plane, .{});
    defer plane.releaseRefs(gpa);
    var failure: Failure = .none;
    try testing.expectError(error.BooleanFailed, apply(gpa, .{ .mesh = &cube, .world = v.identity }, .{ .mesh = &plane, .world = v.identity }, .difference, &failure));
    try testing.expectEqual(Failure.not_manifold_operand, failure);
}
