//! Catmull-Clark subdivision (Blender's Subdivision Surface modifier). Each
//! level splits every n-gon into n quads around a new face point, with new
//! points on every edge; `simple` keeps them at plain averages, so the
//! shape stays and only the faces split, while Catmull-Clark also moves
//! every point by the standard rules (open borders follow the cubic
//! B-spline rule along the border). UVs are interpolated linearly within
//! each face, so UV islands keep their borders.

const std = @import("std");
const math = @import("math");
const core = @import("../../core/root.zig");
const mods = @import("../modifiers.zig");
const em_mod = @import("../editmesh.zig");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const v = math.vec;
const Mesh = core.types.Mesh;

pub fn subdivide(gpa: Allocator, m: *const Mesh, levels: u32, simple: bool, stop: ?em_mod.Stop) mods.Error!Mesh {
    var cur = mods.copy(m);
    errdefer cur.releaseRefs(gpa);
    for (0..levels) |_| {
        if (stop) |s| if (s.deadline.passed(s.io)) return error.DeadlineExceeded;
        const next = try once(gpa, &cur, simple);
        cur.releaseRefs(gpa);
        cur = next;
    }
    return cur;
}

fn edgeKey(a: u32, b: u32) u64 {
    return @as(u64, @min(a, b)) << 32 | @max(a, b);
}

fn once(gpa: Allocator, m: *const Mesh, simple: bool) mods.Error!Mesh {
    const s = mods.Source.init(m);
    const nv = s.pos.len;
    const nf = s.faces();
    // Edges: index, the faces' count, and each edge's two ends.
    var edge_of: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer edge_of.deinit(gpa);
    var ends: std.ArrayList([2]u32) = .empty;
    defer ends.deinit(gpa);
    var uses: std.ArrayList(u32) = .empty;
    defer uses.deinit(gpa);
    const corner_edge = try gpa.alloc(u32, s.cv.len);
    defer gpa.free(corner_edge);
    for (0..nf) |f| {
        const lo = s.off[f];
        const hi = s.off[f + 1];
        for (lo..hi) |c| {
            const a = s.cv[c];
            const z = s.cv[if (c + 1 == hi) lo else c + 1];
            const gop = try edge_of.getOrPut(gpa, edgeKey(a, z));
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(ends.items.len);
                try ends.append(gpa, .{ a, z });
                try uses.append(gpa, 0);
            }
            uses.items[gop.value_ptr.*] += 1;
            corner_edge[c] = gop.value_ptr.*;
        }
    }
    const ne = ends.items.len;

    // Face points: corner means.
    const face_pt = try gpa.alloc(Vec3, nf);
    defer gpa.free(face_pt);
    for (face_pt, 0..) |*fp, f| {
        var acc: Vec3 = .{ 0, 0, 0 };
        for (s.cv[s.off[f]..s.off[f + 1]]) |x| acc = v.add(acc, s.pos[x]);
        fp.* = v.scale(acc, 1 / @as(f32, @floatFromInt(s.off[f + 1] - s.off[f])));
    }
    // Edge points: midpoint, or for an edge between two faces the mean of
    // its ends and the two face points.
    const face_sum = try gpa.alloc(Vec3, ne);
    defer gpa.free(face_sum);
    @memset(face_sum, .{ 0, 0, 0 });
    for (0..nf) |f| for (s.off[f]..s.off[f + 1]) |c| {
        face_sum[corner_edge[c]] = v.add(face_sum[corner_edge[c]], face_pt[f]);
    };
    const edge_pt = try gpa.alloc(Vec3, ne);
    defer gpa.free(edge_pt);
    for (ends.items, uses.items, face_sum, edge_pt) |e, u, fs, *ep| {
        const mid = v.scale(v.add(s.pos[e[0]], s.pos[e[1]]), 0.5);
        ep.* = if (simple or u != 2) mid else v.scale(v.add(v.add(s.pos[e[0]], s.pos[e[1]]), fs), 0.25);
    }
    // Vertex points.
    const vert_pt = try gpa.dupe(Vec3, s.pos);
    defer gpa.free(vert_pt);
    if (!simple) {
        const valence = try gpa.alloc(u32, nv);
        defer gpa.free(valence);
        @memset(valence, 0);
        const border = try gpa.alloc(u32, nv);
        defer gpa.free(border);
        @memset(border, 0);
        const edge_mid_sum = try gpa.alloc(Vec3, nv);
        defer gpa.free(edge_mid_sum);
        @memset(edge_mid_sum, .{ 0, 0, 0 });
        const border_nb = try gpa.alloc(Vec3, nv);
        defer gpa.free(border_nb);
        @memset(border_nb, .{ 0, 0, 0 });
        var nonmanifold = try std.DynamicBitSetUnmanaged.initEmpty(gpa, nv);
        defer nonmanifold.deinit(gpa);
        for (ends.items, uses.items) |e, u| {
            const mid = v.scale(v.add(s.pos[e[0]], s.pos[e[1]]), 0.5);
            for (e, 0..) |x, k| {
                valence[x] += 1;
                edge_mid_sum[x] = v.add(edge_mid_sum[x], mid);
                if (u == 1) {
                    border[x] += 1;
                    border_nb[x] = v.add(border_nb[x], s.pos[e[1 - k]]);
                } else if (u > 2) nonmanifold.set(x);
            }
        }
        const face_count = try gpa.alloc(u32, nv);
        defer gpa.free(face_count);
        @memset(face_count, 0);
        const face_mean = try gpa.alloc(Vec3, nv);
        defer gpa.free(face_mean);
        @memset(face_mean, .{ 0, 0, 0 });
        for (0..nf) |f| for (s.cv[s.off[f]..s.off[f + 1]]) |x| {
            face_count[x] += 1;
            face_mean[x] = v.add(face_mean[x], face_pt[f]);
        };
        for (vert_pt, 0..) |*p, x| {
            if (nonmanifold.isSet(x) or valence[x] == 0) continue;
            if (border[x] == 2 and valence[x] == 2) {
                // A corner of an open mesh stays (Blender's "keep corners").
            } else if (border[x] == 2) {
                // Cubic B-spline along the border: (n1 + 6p + n2) / 8.
                p.* = v.scale(v.add(v.scale(s.pos[x], 6), border_nb[x]), 1.0 / 8.0);
            } else if (border[x] == 0 and face_count[x] == valence[x]) {
                const n: f32 = @floatFromInt(valence[x]);
                const q = v.scale(face_mean[x], 1 / n);
                const r = v.scale(edge_mid_sum[x], 1 / n);
                p.* = v.scale(v.add(v.add(q, v.scale(r, 2)), v.scale(s.pos[x], n - 3)), 1 / n);
            }
        }
    }

    // New mesh: vertex points, then edge points, then face points.
    var b = mods.Builder.init(gpa, s.uv != null);
    defer b.deinit();
    try b.positions.ensureTotalCapacity(gpa, nv + ne + nf);
    for (vert_pt) |p| _ = try b.vert(p);
    for (edge_pt) |p| _ = try b.vert(p);
    for (face_pt) |p| _ = try b.vert(p);
    for (0..nf) |f| {
        const lo = s.off[f];
        const hi = s.off[f + 1];
        const n = hi - lo;
        var mean_uv: [2]f32 = .{ 0, 0 };
        for (lo..hi) |c| {
            const u = s.cornerUv(c);
            mean_uv = .{ mean_uv[0] + u[0], mean_uv[1] + u[1] };
        }
        mean_uv = .{ mean_uv[0] / @as(f32, @floatFromInt(n)), mean_uv[1] / @as(f32, @floatFromInt(n)) };
        for (lo..hi) |c| {
            const cp = if (c == lo) hi - 1 else c - 1;
            const cn = if (c + 1 == hi) lo else c + 1;
            const u = s.cornerUv(c);
            const un = s.cornerUv(cn);
            const up = s.cornerUv(cp);
            try b.beginFace();
            try b.corner(s.cv[c], u);
            try b.corner(@intCast(nv + corner_edge[c]), .{ (u[0] + un[0]) / 2, (u[1] + un[1]) / 2 });
            try b.corner(@intCast(nv + ne + f), mean_uv);
            try b.corner(@intCast(nv + corner_edge[cp]), .{ (u[0] + up[0]) / 2, (u[1] + up[1]) / 2 });
            try b.endFace(s.faceSharp(f), s.faceMat(f));
        }
    }
    return b.finish(m);
}

const testing = std.testing;
const prims = @import("../primitives.zig");
const build = @import("../build.zig");

test "Catmull-Clark on a cube converges toward a sphere-like shape" {
    const gpa = testing.allocator;
    var cube = try prims.generate(gpa, .cube, .{});
    defer cube.releaseRefs(gpa);
    var one = try subdivide(gpa, &cube, 1, false, null);
    defer one.releaseRefs(gpa);
    try testing.expect(build.validate(&one) == null);
    try testing.expectEqual(@as(usize, 24), one.faceCount());
    try testing.expectEqual(@as(usize, 26), one.vertCount());
    // Corner vertex of a unit-half cube: (Q + 2R + (n-3)P)/n with n = 3
    // gives 5/9 on each axis.
    try testing.expectApproxEqAbs(@as(f32, 5.0 / 9.0), @abs(one.positions.slice()[0][0]), 1e-6);
    var three = try subdivide(gpa, &cube, 3, false, null);
    defer three.releaseRefs(gpa);
    try testing.expectEqual(@as(usize, 6 * 64), three.faceCount());
    // Simple subdivision keeps the shape: corners stay at 1.
    var flat = try subdivide(gpa, &cube, 2, true, null);
    defer flat.releaseRefs(gpa);
    try testing.expectEqual(@as(f32, 1), @abs(flat.positions.slice()[0][0]));
    try testing.expect(flat.attribute(Mesh.uv_name) != null);

    // An open grid keeps its border on the plane and its corners fixed.
    var g = try prims.generate(gpa, .grid, .{ .x_subdivisions = 2, .y_subdivisions = 2 });
    defer g.releaseRefs(gpa);
    const corner_before = g.positions.slice()[0];
    var gs = try subdivide(gpa, &g, 2, false, null);
    defer gs.releaseRefs(gpa);
    try testing.expectEqual(@as(usize, 64), gs.faceCount());
    for (gs.positions.slice()) |p| try testing.expectEqual(@as(f32, 0), p[2]);
    try testing.expectEqual(corner_before, gs.positions.slice()[0]);
}
