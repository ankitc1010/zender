//! Sculpt brushes (P1 scope extension): a stroke is a path of world-space
//! points; dabs are placed along it every `spacing` × radius, and each dab
//! moves the vertices within `radius` of its centre, weighted by a falloff
//! curve, as Blender's sculpt brushes do:
//!
//!   draw     along the dab's area normal (mean normal under the brush)
//!   inflate  along each vertex's own normal
//!   flatten  toward the plane through the area under the brush
//!   pinch    toward the dab centre
//!   crease   pinch plus a draw inward, for sharp folds
//!   smooth   toward the mean of each vertex's neighbours
//!   grab     the area under the stroke's first point moves to its last
//!
//! `subtract` turns draw, inflate and crease inward. With symmetry, every
//! dab is repeated mirrored across the object's local plane on that axis.
//! Stroke points snap to the nearest vertex, so a path given a little off
//! the surface still lands on it (for grab, only the start snaps; the drag
//! is the path as given). Displacements scale with the radius, so
//! strength is unitless (0..1).

const std = @import("std");
const math = @import("math");
const core = @import("../../core/root.zig");
const em_mod = @import("../editmesh.zig");
const ops = @import("../ops.zig");
const falloff = @import("falloff.zig");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const v = math.vec;
const Mesh = core.types.Mesh;
const Xform = ops.Xform;

pub const Brush = enum { draw, inflate, flatten, pinch, crease, smooth, grab };
pub const Symmetry = enum { none, x, y, z };

pub const max_dabs = 4096;

pub const Params = struct {
    brush: Brush = .draw,
    radius: f32 = 0.1,
    strength: f32 = 0.5,
    subtract: bool = false,
    curve: falloff.Curve = .smooth,
    symmetry: Symmetry = .none,
    /// Distance between dabs, as a fraction of the radius.
    spacing: f32 = 0.25,
    /// Snap stroke points to the nearest vertex.
    project: bool = true,
};

pub const Stats = struct {
    dabs: usize = 0,
    /// Vertices any dab moved.
    moved: usize = 0,
};

/// Applies a stroke to `positions` (the mesh's, local space, modified in
/// place). `touched` (one bit per vertex) receives the moved vertices.
pub fn stroke(gpa: Allocator, m: *const Mesh, positions: []Vec3, xf: Xform, path: []const Vec3, p: Params, stop: ?em_mod.Stop, touched: *std.DynamicBitSetUnmanaged) (Allocator.Error || math.DeadlineError)!Stats {
    var stats: Stats = .{};
    if (path.len == 0 or positions.len == 0 or p.radius <= 0) return stats;
    var adj = try falloff.Adjacency.init(gpa, m);
    defer adj.deinit(gpa);
    const world = try gpa.alloc(Vec3, positions.len);
    defer gpa.free(world);
    const normals = try gpa.alloc(Vec3, positions.len);
    defer gpa.free(normals);
    const w = try gpa.alloc(f32, positions.len);
    defer gpa.free(w);
    const scratch = try gpa.alloc(Vec3, positions.len);
    defer gpa.free(scratch);
    var ctx: Ctx = .{ .m = m, .positions = positions, .xf = xf, .world = world, .normals = normals, .w = w, .scratch = scratch, .adj = &adj, .p = p, .touched = touched };
    ctx.refresh();

    // Snap the path to the surface, then place dabs along it.
    const pts = try gpa.alloc(Vec3, path.len);
    defer gpa.free(pts);
    for (path, pts) |q, *o| o.* = if (p.project) ctx.nearest(q) else q;
    if (p.brush == .grab) {
        // The start snaps to the surface; the drag is the path as given.
        const delta = v.sub(path[path.len - 1], path[0]);
        try ctx.dab(pts[0], delta);
        if (p.symmetry != .none) try ctx.dab(ctx.mirrorPoint(pts[0]), ctx.mirrorDir(delta));
        stats.dabs = 1;
    } else {
        const spacing = @max(p.spacing, 0.01) * p.radius;
        var dabs: std.ArrayList(Vec3) = .empty;
        defer dabs.deinit(gpa);
        try dabs.append(gpa, pts[0]);
        var carry: f32 = 0;
        for (pts[0 .. pts.len - 1], pts[1..]) |a, b| {
            const seg = v.length(v.sub(b, a));
            var t = spacing - carry;
            while (t <= seg and dabs.items.len < max_dabs) : (t += spacing) try dabs.append(gpa, v.lerp(a, b, t / seg));
            carry = if (seg > 0) seg - (t - spacing) else carry;
        }
        for (dabs.items) |c| {
            if (stop) |s| if (s.deadline.passed(s.io)) return error.DeadlineExceeded;
            try ctx.dab(c, .{ 0, 0, 0 });
            if (p.symmetry != .none) try ctx.dab(ctx.mirrorPoint(c), .{ 0, 0, 0 });
        }
        stats.dabs = dabs.items.len;
    }
    stats.moved = touched.count();
    return stats;
}

const Ctx = struct {
    m: *const Mesh,
    positions: []Vec3,
    xf: Xform,
    world: []Vec3,
    normals: []Vec3,
    w: []f32,
    scratch: []Vec3,
    adj: *const falloff.Adjacency,
    p: Params,
    touched: *std.DynamicBitSetUnmanaged,

    /// Recomputes world positions and vertex normals (world space).
    fn refresh(c: *Ctx) void {
        for (c.positions, c.world) |q, *o| o.* = c.xf.toWorld(q);
        @memset(c.normals, .{ 0, 0, 0 });
        const off = c.m.face_offsets.slice();
        const cv = c.m.corner_verts.slice();
        for (0..c.m.faceCount()) |f| {
            const cs = cv[off[f]..off[f + 1]];
            const n = math.triangulate.newellNormal(c.world, cs);
            for (cs) |x| c.normals[x] = v.add(c.normals[x], n);
        }
        for (c.normals) |*n| n.* = v.normalize(n.*);
    }

    fn nearest(c: *const Ctx, q: Vec3) Vec3 {
        var best = c.world[0];
        var bd = std.math.inf(f32);
        for (c.world) |x| {
            const d = v.sub(x, q);
            const dd = v.dot(d, d);
            if (dd < bd) {
                bd = dd;
                best = x;
            }
        }
        return best;
    }

    fn axis(c: *const Ctx) usize {
        return switch (c.p.symmetry) {
            .x, .none => 0,
            .y => 1,
            .z => 2,
        };
    }

    fn mirrorPoint(c: *const Ctx, q: Vec3) Vec3 {
        var l = c.xf.toLocal(q);
        l[c.axis()] = -l[c.axis()];
        return c.xf.toWorld(l);
    }

    fn mirrorDir(c: *const Ctx, d: Vec3) Vec3 {
        var l = c.xf.dirToLocal(d);
        l[c.axis()] = -l[c.axis()];
        return v.transformDir(c.xf.m, l);
    }

    /// One dab at `center`; `grab` is the grab brush's movement.
    fn dab(c: *Ctx, center: Vec3, grab: Vec3) Allocator.Error!void {
        const r = c.p.radius;
        const r2 = r * r;
        var any = false;
        // Weights and the area under the brush.
        var area_n: Vec3 = .{ 0, 0, 0 };
        var area_c: Vec3 = .{ 0, 0, 0 };
        var wsum: f32 = 0;
        for (c.world, c.w, c.normals) |q, *wi, n| {
            const d = v.sub(q, center);
            const dd = v.dot(d, d);
            if (dd >= r2) {
                wi.* = 0;
                continue;
            }
            wi.* = c.p.curve.eval(1 - @sqrt(dd) / r);
            if (wi.* == 0) continue;
            any = true;
            area_n = v.add(area_n, v.scale(n, wi.*));
            area_c = v.add(area_c, v.scale(q, wi.*));
            wsum += wi.*;
        }
        if (!any) return;
        area_n = v.normalize(area_n);
        area_c = v.scale(area_c, 1 / wsum);
        const sign: f32 = if (c.p.subtract) -1 else 1;
        const s = std.math.clamp(c.p.strength, 0, 1);
        const push = s * r * 0.5;
        if (c.p.brush == .smooth) {
            for (c.world, c.scratch, 0..) |q, *o, i| {
                o.* = q;
                if (c.w[i] == 0) continue;
                const ns = c.adj.of(@intCast(i));
                if (ns.len == 0) continue;
                var mean: Vec3 = .{ 0, 0, 0 };
                for (ns) |x| mean = v.add(mean, c.world[x]);
                mean = v.scale(mean, 1 / @as(f32, @floatFromInt(ns.len)));
                o.* = v.add(q, v.scale(v.sub(mean, q), s * c.w[i]));
            }
            for (c.world, c.scratch, 0..) |*q, o, i| if (c.w[i] > 0) {
                q.* = o;
            };
        } else {
            for (c.world, c.normals, c.w) |*q, n, wi| {
                if (wi == 0) continue;
                const moved = switch (c.p.brush) {
                    .draw => v.scale(area_n, sign * push * wi),
                    .inflate => v.scale(n, sign * push * wi),
                    .flatten => v.scale(area_n, -v.dot(v.sub(q.*, area_c), area_n) * s * wi),
                    .pinch => v.scale(v.sub(center, q.*), 0.3 * s * wi),
                    .crease => v.add(v.scale(v.sub(center, q.*), 0.3 * s * wi), v.scale(area_n, -sign * push * 0.5 * wi)),
                    .grab => v.scale(grab, s * wi),
                    .smooth => unreachable,
                };
                q.* = v.add(q.*, moved);
            }
        }
        for (c.world, c.positions, c.w, 0..) |q, *o, wi, i| if (wi > 0) {
            o.* = c.xf.toLocal(q);
            c.touched.set(i);
        };
        // Normals follow the surface for the next dab.
        c.refresh();
    }
};

const testing = std.testing;
const prims = @import("../primitives.zig");

test "draw raises, subtract lowers, symmetry mirrors, grab moves, smooth relaxes" {
    const gpa = testing.allocator;
    var g = try prims.generate(gpa, .grid, .{ .x_subdivisions = 20, .y_subdivisions = 20 });
    defer g.releaseRefs(gpa);
    const pos = try gpa.dupe(Vec3, g.positions.slice());
    defer gpa.free(pos);
    var touched = try std.DynamicBitSetUnmanaged.initEmpty(gpa, pos.len);
    defer touched.deinit(gpa);

    // A stroke along Y at x = 0.5, mirrored to x = -0.5.
    const s = try stroke(gpa, &g, pos, .identity, &.{ .{ 0.5, -0.5, 0 }, .{ 0.5, 0.5, 0 } }, .{ .radius = 0.2, .strength = 0.6, .symmetry = .x }, null, &touched);
    try testing.expect(s.dabs >= 20);
    var hi: f32 = 0;
    var lo: f32 = 0;
    for (pos) |q| {
        hi = @max(hi, q[2]);
        lo = @min(lo, q[2]);
    }
    try testing.expect(hi > 0.1);
    try testing.expectEqual(@as(f32, 0), lo);
    // Symmetric: each raised vertex has a twin at -x with the same height.
    for (pos) |q| if (q[2] > 0.05 and q[0] > 0) {
        var found = false;
        for (pos) |t| if (@abs(t[0] + q[0]) < 1e-4 and @abs(t[1] - q[1]) < 1e-4 and @abs(t[2] - q[2]) < 1e-3) {
            found = true;
        };
        try testing.expect(found);
    };

    // Subtract digs below the plane.
    const dug = try gpa.dupe(Vec3, g.positions.slice());
    defer gpa.free(dug);
    _ = try stroke(gpa, &g, dug, .identity, &.{.{ 0, 0, 0.3 }}, .{ .radius = 0.3, .strength = 1, .subtract = true }, null, &touched);
    var deepest: f32 = 0;
    for (dug) |q| deepest = @min(deepest, q[2]);
    try testing.expect(deepest < -0.1);

    // Grab moves the area under the first point by the stroke's length.
    const grabbed = try gpa.dupe(Vec3, g.positions.slice());
    defer gpa.free(grabbed);
    _ = try stroke(gpa, &g, grabbed, .identity, &.{ .{ 0, 0, 0 }, .{ 0, 0, 0.5 } }, .{ .brush = .grab, .radius = 0.3, .strength = 1 }, null, &touched);
    var top: f32 = 0;
    for (grabbed) |q| top = @max(top, q[2]);
    try testing.expectApproxEqAbs(@as(f32, 0.5), top, 1e-5);

    // Smooth pulls a spike down.
    const spiky = try gpa.dupe(Vec3, g.positions.slice());
    defer gpa.free(spiky);
    var centre: usize = 0;
    for (spiky, 0..) |q, i| if (@abs(q[0]) < 1e-4 and @abs(q[1]) < 1e-4) {
        centre = i;
    };
    spiky[centre][2] = 1;
    _ = try stroke(gpa, &g, spiky, .identity, &.{.{ 0, 0, 1 }}, .{ .brush = .smooth, .radius = 0.25, .strength = 1, .project = false }, null, &touched);
    try testing.expect(spiky[centre][2] < 0.5);
}
