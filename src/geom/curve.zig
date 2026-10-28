//! Curve evaluation: poly and NURBS splines swept into tubes, as Blender
//! does for a curve with a round bevel. Each spline is sampled into a
//! centre line (NURBS with clamped, uniform knots), carried along it by
//! rotation-minimising frames (Blender's default twist mode) and wrapped
//! with a ring of 4 + 2 × bevel_resolution vertices whose radius is the
//! bevel depth times the point radius times the taper.

const std = @import("std");
const math = @import("math");
const core = @import("../core/root.zig");
const build = @import("build.zig");
const prims = @import("primitives.zig");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const v = math.vec;
const Mesh = core.types.Mesh;
const tau = 2 * std.math.pi;

pub const Spline = struct {
    points: []const Vec3,
    radius: []const f32,
    /// Radians about the tangent.
    tilt: []const f32,
    nurbs: bool = false,
    /// NURBS order, 2..6 (clamped to the point count).
    order: u8 = 4,
};

pub const Settings = struct {
    bevel_depth: f32 = 0,
    bevel_resolution: u32 = 4,
    resolution_u: u32 = 12,
    fill_caps: bool = false,
    /// Radius factor at the start and the end, by arc length.
    taper_start: f32 = 1,
    taper_end: f32 = 1,
};

pub const max_resolution = 1024;
pub const max_bevel_resolution = 32;

pub const Samples = struct {
    pos: []Vec3,
    radius: []f32,
    tilt: []f32,

    pub fn deinit(s: Samples, gpa: Allocator) void {
        gpa.free(s.pos);
        gpa.free(s.radius);
        gpa.free(s.tilt);
    }
};

/// The centre line: the points themselves for a poly spline; for NURBS,
/// resolution_u samples per span between the clamped end points.
pub fn sample(gpa: Allocator, s: Spline, resolution_u: u32) Allocator.Error!Samples {
    const n = s.points.len;
    if (!s.nurbs or n < 3) {
        return .{ .pos = try gpa.dupe(Vec3, s.points), .radius = try gpa.dupe(f32, s.radius), .tilt = try gpa.dupe(f32, s.tilt) };
    }
    const k: usize = @min(@max(s.order, 2), n);
    // Clamped uniform knots: k zeros, interior steps, k ones.
    const knots = try gpa.alloc(f32, n + k);
    defer gpa.free(knots);
    const spans = n - k + 1;
    for (knots, 0..) |*t, i| {
        t.* = if (i < k) 0 else if (i >= n) 1 else @as(f32, @floatFromInt(i - k + 1)) / @as(f32, @floatFromInt(spans));
    }
    const count = @as(usize, @max(resolution_u, 1)) * (n - 1) + 1;
    var out: Samples = .{ .pos = try gpa.alloc(Vec3, count), .radius = try gpa.alloc(f32, count), .tilt = try gpa.alloc(f32, count) };
    errdefer out.deinit(gpa);
    const basis = try gpa.alloc(f32, n);
    defer gpa.free(basis);
    for (0..count) |si| {
        const u = @as(f32, @floatFromInt(si)) / @as(f32, @floatFromInt(count - 1));
        basisFunctions(knots, k, n, u, basis);
        var p: Vec3 = .{ 0, 0, 0 };
        var r: f32 = 0;
        var t: f32 = 0;
        for (basis, 0..) |b, i| {
            p = v.add(p, v.scale(s.points[i], b));
            r += s.radius[i] * b;
            t += s.tilt[i] * b;
        }
        out.pos[si] = p;
        out.radius[si] = r;
        out.tilt[si] = t;
    }
    return out;
}

/// Cox-de Boor: the n basis functions of order k at u, into `out`.
fn basisFunctions(knots: []const f32, k: usize, n: usize, u_in: f32, out: []f32) void {
    // The last span is closed at u = 1.
    const u = @min(u_in, 1 - 1e-7);
    var tmp: [64]f32 = undefined;
    const m = n + k - 1;
    for (0..m) |i| tmp[i] = if (knots[i] <= u and u < knots[i + 1]) 1 else 0;
    var d: usize = 2;
    while (d <= k) : (d += 1) {
        for (0..m - d + 1) |i| {
            const den1 = knots[i + d - 1] - knots[i];
            const den2 = knots[i + d] - knots[i + 1];
            const a = if (den1 > 0) (u - knots[i]) / den1 * tmp[i] else 0;
            const b = if (den2 > 0) (knots[i + d] - u) / den2 * tmp[i + 1] else 0;
            tmp[i] = a + b;
        }
    }
    @memcpy(out[0..n], tmp[0..n]);
}

/// Unit tangents by central differences.
fn tangents(gpa: Allocator, pos: []const Vec3) Allocator.Error![]Vec3 {
    const t = try gpa.alloc(Vec3, pos.len);
    for (t, 0..) |*o, i| {
        const a = pos[if (i == 0) 0 else i - 1];
        const b = pos[@min(i + 1, pos.len - 1)];
        const d = v.sub(b, a);
        o.* = if (v.length(d) > 1e-12) v.normalize(d) else if (i > 0) t[i - 1] else .{ 0, 0, 1 };
    }
    return t;
}

/// Rotation-minimising normals by double reflection (Wang et al. 2008).
fn frames(gpa: Allocator, pos: []const Vec3, tan: []const Vec3) Allocator.Error![]Vec3 {
    const nrm = try gpa.alloc(Vec3, pos.len);
    // Start perpendicular to the first tangent, leaning towards +Z (or +X).
    const up: Vec3 = if (@abs(tan[0][2]) < 0.99) .{ 0, 0, 1 } else .{ 1, 0, 0 };
    nrm[0] = v.normalize(v.cross(v.cross(tan[0], up), tan[0]));
    for (1..pos.len) |i| {
        const v1 = v.sub(pos[i], pos[i - 1]);
        const c1 = v.dot(v1, v1);
        if (c1 < 1e-20) {
            nrm[i] = nrm[i - 1];
            continue;
        }
        const r_l = v.sub(nrm[i - 1], v.scale(v1, 2 / c1 * v.dot(v1, nrm[i - 1])));
        const t_l = v.sub(tan[i - 1], v.scale(v1, 2 / c1 * v.dot(v1, tan[i - 1])));
        const v2 = v.sub(tan[i], t_l);
        const c2 = v.dot(v2, v2);
        const r = if (c2 < 1e-20) r_l else v.sub(r_l, v.scale(v2, 2 / c2 * v.dot(v2, r_l)));
        nrm[i] = v.normalize(r);
    }
    return nrm;
}

/// Ring vertices around each spline for a round bevel.
pub fn ringSize(bevel_resolution: u32) u32 {
    return 4 + 2 * @min(bevel_resolution, max_bevel_resolution);
}

/// Sweeps every spline into a tube; an empty mesh when bevel_depth is 0.
pub fn tube(gpa: Allocator, splines: []const Spline, s: Settings) prims.Error!Mesh {
    var b = try prims.Builder.init(gpa);
    defer b.deinit();
    if (s.bevel_depth > 0) for (splines) |sp| {
        if (sp.points.len < 2) continue;
        try sweep(&b, sp, s);
    };
    return b.finish(true);
}

fn sweep(b: *prims.Builder, sp: Spline, s: Settings) prims.Error!void {
    const gpa = b.gpa;
    const smp = try sample(gpa, sp, @min(@max(s.resolution_u, 1), max_resolution));
    defer smp.deinit(gpa);
    const n = smp.pos.len;
    const tan = try tangents(gpa, smp.pos);
    defer gpa.free(tan);
    const nrm = try frames(gpa, smp.pos, tan);
    defer gpa.free(nrm);
    // Arc length, for the taper and u.
    const arc = try gpa.alloc(f32, n);
    defer gpa.free(arc);
    arc[0] = 0;
    for (1..n) |i| arc[i] = arc[i - 1] + v.length(v.sub(smp.pos[i], smp.pos[i - 1]));
    const total = arc[n - 1];
    const ring = ringSize(s.bevel_resolution);
    const first: u32 = @intCast(b.pos.items.len);
    for (0..n) |i| {
        const f = if (total > 0) arc[i] / total else 0;
        const radius = s.bevel_depth * smp.radius[i] * (s.taper_start + (s.taper_end - s.taper_start) * f);
        // Tilt turns the frame about the tangent.
        const ct = @cos(smp.tilt[i]);
        const st = @sin(smp.tilt[i]);
        const binorm = v.cross(tan[i], nrm[i]);
        const nx = v.add(v.scale(nrm[i], ct), v.scale(binorm, st));
        const ny = v.sub(v.scale(binorm, ct), v.scale(nrm[i], st));
        for (0..ring) |j| {
            const a = tau * @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(ring));
            const off = v.add(v.scale(nx, @cos(a) * radius), v.scale(ny, @sin(a) * radius));
            _ = try b.vert(v.add(smp.pos[i], off));
        }
    }
    const ring_f: f32 = @floatFromInt(ring);
    for (0..n - 1) |i| {
        const ua = if (total > 0) arc[i] / total else 0;
        const u_1 = if (total > 0) arc[i + 1] / total else 1;
        for (0..ring) |j| {
            const j1 = (j + 1) % ring;
            const a = first + @as(u32, @intCast(i * ring + j));
            const bb = first + @as(u32, @intCast(i * ring + j1));
            const c = first + @as(u32, @intCast((i + 1) * ring + j1));
            const d = first + @as(u32, @intCast((i + 1) * ring + j));
            const w0 = @as(f32, @floatFromInt(j)) / ring_f;
            const w1 = @as(f32, @floatFromInt(j + 1)) / ring_f;
            // Wound so faces point away from the centre line.
            try b.face(&.{ a, bb, c, d }, &.{ .{ ua, w0 }, .{ ua, w1 }, .{ u_1, w1 }, .{ u_1, w0 } });
        }
    }
    if (s.fill_caps) {
        try cap(b, first, ring, true);
        try cap(b, first + @as(u32, @intCast((n - 1) * ring)), ring, false);
    }
}

fn cap(b: *prims.Builder, start: u32, ring: u32, reverse: bool) Allocator.Error!void {
    const verts = try b.gpa.alloc(u32, ring);
    defer b.gpa.free(verts);
    const uvs = try b.gpa.alloc([2]f32, ring);
    defer b.gpa.free(uvs);
    for (0..ring) |i| {
        const j = if (reverse) ring - 1 - i else i;
        verts[i] = start + @as(u32, @intCast(j));
        const a = tau * @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(ring));
        uvs[i] = .{ 0.5 + 0.5 * @cos(a), 0.5 + 0.5 * @sin(a) };
    }
    try b.face(verts, uvs);
}

/// Splines of a stored Curve, as views into its arrays.
pub fn splinesOf(gpa: Allocator, c: *const core.types.Curve) Allocator.Error![]Spline {
    const off = c.spline_offsets.slice();
    const n = if (off.len == 0) 0 else off.len - 1;
    const out = try gpa.alloc(Spline, n);
    const kinds = c.spline_type.slice();
    const orders = c.spline_order.slice();
    for (out, 0..) |*sp, i| {
        const a = off[i];
        const z = off[i + 1];
        sp.* = .{
            .points = c.points.slice()[a..z],
            .radius = c.radius.slice()[a..z],
            .tilt = c.tilt.slice()[a..z],
            .nurbs = kinds[i] == @intFromEnum(core.types.SplineType.nurbs),
            .order = orders[i],
        };
    }
    return out;
}

/// The mesh a curve evaluates to (empty when it has no bevel).
pub fn toMesh(gpa: Allocator, c: *const core.types.Curve) prims.Error!Mesh {
    const splines = try splinesOf(gpa, c);
    defer gpa.free(splines);
    return tube(gpa, splines, .{
        .bevel_depth = c.bevel_depth,
        .bevel_resolution = @intCast(@max(c.bevel_resolution, 0)),
        .resolution_u = @intCast(@max(c.resolution_u, 1)),
        .fill_caps = c.use_fill_caps,
        .taper_start = c.taper_start,
        .taper_end = c.taper_end,
    });
}

const testing = std.testing;

test "a straight poly tube: ring size, radius, caps, outward faces" {
    const gpa = testing.allocator;
    const pts = [_]Vec3{ .{ 0, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 0, 2 } };
    const radius = [_]f32{ 1, 1, 0.5 };
    const tilt = [_]f32{ 0, 0, 0 };
    var m = try tube(gpa, &.{.{ .points = &pts, .radius = &radius, .tilt = &tilt }}, .{ .bevel_depth = 0.1, .bevel_resolution = 2, .fill_caps = true });
    defer m.releaseRefs(gpa);
    // 3 rings of 8; 2 x 8 quads + 2 caps.
    try testing.expectEqual(@as(usize, 24), m.vertCount());
    try testing.expectEqual(@as(usize, 18), m.faceCount());
    try testing.expectEqual(@as(i64, 2), @as(i64, @intCast(m.vertCount())) - @as(i64, @intCast(m.edgeCount())) + @as(i64, @intCast(m.faceCount())));
    const pos = m.positions.slice();
    try testing.expectApproxEqAbs(@as(f32, 0.1), v.length(.{ pos[0][0], pos[0][1], 0 }), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.05), v.length(.{ pos[16][0], pos[16][1], 0 }), 1e-6);
    const cv = m.corner_verts.slice();
    const nrm = v.cross(v.sub(pos[cv[1]], pos[cv[0]]), v.sub(pos[cv[2]], pos[cv[0]]));
    try testing.expect(v.dot(nrm, .{ pos[cv[0]][0], pos[cv[0]][1], 0 }) > 0);
}

test "NURBS passes through its end points; frames do not twist on a helix" {
    const gpa = testing.allocator;
    const pts = [_]Vec3{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 0, 1, 1 } };
    const radius = [_]f32{ 1, 1, 1, 0.2 };
    const tilt = [_]f32{ 0, 0, 0, 0 };
    const s = try sample(gpa, .{ .points = &pts, .radius = &radius, .tilt = &tilt, .nurbs = true, .order = 4 }, 8);
    defer s.deinit(gpa);
    try testing.expectEqual(@as(usize, 25), s.pos.len);
    try testing.expectEqualSlices(f32, &pts[0], &s.pos[0]);
    for (0..3) |k| try testing.expectApproxEqAbs(pts[3][k], s.pos[24][k], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.2), s.radius[24], 1e-5);

    // A helix: consecutive normals stay close (no flips).
    var helix: [64]Vec3 = undefined;
    for (&helix, 0..) |*p, i| {
        const t = @as(f32, @floatFromInt(i)) * 0.2;
        p.* = .{ @cos(t), @sin(t), 0.1 * t };
    }
    const tan = try tangents(gpa, &helix);
    defer gpa.free(tan);
    const nrm = try frames(gpa, &helix, tan);
    defer gpa.free(nrm);
    for (1..helix.len) |i| {
        try testing.expect(v.dot(nrm[i], nrm[i - 1]) > 0.9);
        try testing.expectApproxEqAbs(@as(f32, 0), v.dot(nrm[i], tan[i]), 1e-3);
    }
}
