//! Evaluated normals: face normals, angle-weighted vertex normals and
//! per-corner normals that respect flat ("sharp") faces.

const std = @import("std");
const math = @import("math");
const core = @import("../core/root.zig");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const v = math.vec;
const Mesh = core.types.Mesh;

pub fn faceNormals(gpa: Allocator, m: *const Mesh) Allocator.Error![]Vec3 {
    const pos = m.positions.slice();
    const off = m.face_offsets.slice();
    const cv = m.corner_verts.slice();
    const out = try gpa.alloc(Vec3, m.faceCount());
    for (out, 0..) |*n, f| {
        n.* = v.normalize(math.triangulate.newellNormal(pos, cv[off[f]..off[f + 1]]));
    }
    return out;
}

/// Corner normals as Blender 4.1+ evaluates them without custom normals:
/// a flat face's corners get the face normal; a smooth face's corners get
/// the angle-weighted average of the smooth faces around that vertex. An
/// edge between a smooth and a flat face therefore shades sharp.
///
/// Per-face and per-vertex steps run on `pool`; the accumulation into
/// vertices runs in one fixed order, so results do not depend on threads.
pub fn cornerNormals(gpa: Allocator, m: *const Mesh, pool: math.Pool) Allocator.Error![]Vec3 {
    const pos = m.positions.slice();
    const off = m.face_offsets.slice();
    const cv = m.corner_verts.slice();
    const n_faces = m.faceCount();
    const sharp: []const bool = if (m.attribute("sharp_face")) |a| a.data.boolean.slice() else &.{};

    const out = try gpa.alloc(Vec3, cv.len);
    errdefer gpa.free(out);
    const fnorm = try gpa.alloc(Vec3, n_faces);
    defer gpa.free(fnorm);
    const weight = try gpa.alloc(f32, cv.len);
    defer gpa.free(weight);

    var any_smooth = false;
    for (0..n_faces) |f| {
        if (sharp.len == 0 or !sharp[f]) {
            any_smooth = true;
            break;
        }
    }

    const Ctx = struct {
        pos: []const Vec3,
        off: []const u32,
        cv: []const u32,
        sharp: []const bool,
        fnorm: []Vec3,
        weight: []f32,
        vnorm: []Vec3 = &.{},
        out: []Vec3,
        n_faces: usize,
        smooth: bool,

        fn faces(c: *const @This(), chunk: usize) void {
            const lo = chunk * chunk_faces;
            const hi = @min(c.n_faces, lo + chunk_faces);
            for (lo..hi) |f| {
                const s_ = c.off[f];
                const e = c.off[f + 1];
                const n = v.normalize(math.triangulate.newellNormal(c.pos, c.cv[s_..e]));
                c.fnorm[f] = n;
                if (!c.smooth or (c.sharp.len != 0 and c.sharp[f])) continue;
                for (s_..e) |k| {
                    const prev = c.cv[if (k == s_) e - 1 else k - 1];
                    const next = c.cv[if (k + 1 == e) s_ else k + 1];
                    const p = c.pos[c.cv[k]];
                    const a = v.normalize(v.sub(c.pos[prev], p));
                    const b = v.normalize(v.sub(c.pos[next], p));
                    c.weight[k] = std.math.acos(std.math.clamp(v.dot(a, b), -1.0, 1.0));
                }
            }
        }

        fn normalizeVerts(c: *const @This(), chunk: usize) void {
            const lo = chunk * chunk_verts;
            const hi = @min(c.vnorm.len, lo + chunk_verts);
            for (c.vnorm[lo..hi]) |*n| n.* = v.normalize(n.*);
        }

        fn corners(c: *const @This(), chunk: usize) void {
            const lo = chunk * chunk_faces;
            const hi = @min(c.n_faces, lo + chunk_faces);
            for (lo..hi) |f| {
                const flat = !c.smooth or (c.sharp.len != 0 and c.sharp[f]);
                for (c.off[f]..c.off[f + 1]) |k| c.out[k] = if (flat) c.fnorm[f] else c.vnorm[c.cv[k]];
            }
        }
    };
    var ctx: Ctx = .{ .pos = pos, .off = off, .cv = cv, .sharp = sharp, .fnorm = fnorm, .weight = weight, .out = out, .n_faces = n_faces, .smooth = any_smooth };
    const face_chunks = (n_faces + chunk_faces - 1) / chunk_faces;
    pool.parallelFor(face_chunks, &ctx, Ctx.faces);
    if (any_smooth) {
        const vnorm = try gpa.alloc(Vec3, pos.len);
        defer gpa.free(vnorm);
        @memset(vnorm, .{ 0, 0, 0 });
        for (0..n_faces) |f| {
            if (sharp.len != 0 and sharp[f]) continue;
            const n = fnorm[f];
            for (off[f]..off[f + 1]) |k| {
                const w = weight[k];
                const dst = &vnorm[cv[k]];
                dst.* = .{ dst[0] + n[0] * w, dst[1] + n[1] * w, dst[2] + n[2] * w };
            }
        }
        ctx.vnorm = vnorm;
        pool.parallelFor((pos.len + chunk_verts - 1) / chunk_verts, &ctx, Ctx.normalizeVerts);
        pool.parallelFor(face_chunks, &ctx, Ctx.corners);
    } else {
        pool.parallelFor(face_chunks, &ctx, Ctx.corners);
    }
    return out;
}

const chunk_faces = 8192;
const chunk_verts = 16384;

/// Axis-aligned bounds of the positions, or null for an empty mesh.
pub fn bounds(m: *const Mesh) ?[2]Vec3 {
    const pos = m.positions.slice();
    if (pos.len == 0) return null;
    var lo = pos[0];
    var hi = pos[0];
    for (pos[1..]) |p| {
        lo = v.min3(lo, p);
        hi = v.max3(hi, p);
    }
    return .{ lo, hi };
}

test "corner normals do not depend on thread count" {
    const gpa = std.testing.allocator;
    var m = try @import("primitives.zig").generate(gpa, .uv_sphere, .{ .segments = 64, .rings = 48, .smooth = true });
    defer m.releaseRefs(gpa);
    const a = try cornerNormals(gpa, &m, .{ .io = std.testing.io, .threads = 1 });
    defer gpa.free(a);
    const b = try cornerNormals(gpa, &m, .{ .io = std.testing.io, .threads = 8 });
    defer gpa.free(b);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(a), std.mem.sliceAsBytes(b));
    // Smooth sphere normals point outward.
    const p = m.positions.slice()[m.corner_verts.slice()[100]];
    try std.testing.expect(v.dot(a[100], p) > 0.99);
}
