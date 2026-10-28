//! Surfaces of revolution for mesh.revolve: a profile of (height, radius)
//! pairs swept around local Z, optionally with fluted relief (rounded
//! strips with an engraved centre line, as on armour). Like the primitives,
//! a pure function of its parameters.

const std = @import("std");
const math = @import("math");
const core = @import("../core/root.zig");
const prims = @import("primitives.zig");

const Allocator = std.mem.Allocator;
const Mesh = core.types.Mesh;
const tau = 2 * std.math.pi;

pub const Relief = struct {
    /// Strips around a full turn; 0 = none.
    count: u32 = 0,
    /// Outward height of each strip (m).
    depth: f32 = 0,
    /// Depth of the line engraved down each strip's middle (m).
    groove: f32 = 0,
};

pub const Params = struct {
    /// (height, radius) pairs from one end to the other. Listed bottom to
    /// top, faces point away from the axis.
    profile: []const [2]f32,
    segments: u32 = 32,
    /// Sweep, radians from +X towards +Y; a full turn closes the surface.
    angle_start: f32 = 0,
    angle_end: f32 = tau,
    relief: Relief = .{},
    /// Fill the first / last profile ring (full turns only).
    cap_start: bool = false,
    cap_end: bool = false,
    smooth: bool = true,
};

pub const max_profile = 4096;

pub const Error = prims.Error;

/// Radial offset of the relief at `u`, the fraction of a full turn.
pub fn reliefAt(r: Relief, u: f32) f32 {
    if (r.count == 0) return 0;
    const x = u * @as(f32, @floatFromInt(r.count));
    const t = x - @floor(x);
    const e = @abs(2 * t - 1);
    const e2 = e * e;
    const g = (t - 0.5) / 0.06;
    return r.depth * (1 - e2 * e2 * e2) - r.groove * @exp(-g * g);
}

pub fn revolve(gpa: Allocator, p: Params) Error!Mesh {
    const n = p.profile.len;
    const sweep = p.angle_end - p.angle_start;
    if (n < 2 or n > max_profile or p.segments < 3 or p.segments > prims.limits.max_segments) return error.InvalidParameter;
    if (!(sweep > 0) or sweep > tau + 1e-4) return error.InvalidParameter;
    for (p.profile, 0..) |pt, k| {
        if (!(pt[1] >= 0)) return error.InvalidParameter;
        // Only an end of the profile may sit on the axis.
        if (pt[1] == 0 and k != 0 and k != n - 1) return error.InvalidParameter;
    }
    const closed = @abs(sweep - tau) < 1e-4;
    const segs = p.segments;
    const cols: u32 = if (closed) segs else segs + 1;
    const pole_start = p.profile[0][1] == 0;
    const pole_end = p.profile[n - 1][1] == 0;

    // v of each profile point: arc length along the profile, 0..1.
    const vs = try gpa.alloc(f32, n);
    defer gpa.free(vs);
    vs[0] = 0;
    for (1..n) |k| {
        const dz = p.profile[k][0] - p.profile[k - 1][0];
        const dr = p.profile[k][1] - p.profile[k - 1][1];
        vs[k] = vs[k - 1] + @sqrt(dz * dz + dr * dr);
    }
    const total = vs[n - 1];
    for (vs) |*v| v.* = if (total > 0) v.* / total else 0;

    var b = try prims.Builder.init(gpa);
    defer b.deinit();
    // index[col * n + k]; a pole row reuses one vertex.
    const index = try gpa.alloc(u32, cols * n);
    defer gpa.free(index);
    var start_pole: u32 = 0;
    var end_pole: u32 = 0;
    if (pole_start) start_pole = try b.vert(.{ 0, 0, p.profile[0][0] });
    if (pole_end) end_pole = try b.vert(.{ 0, 0, p.profile[n - 1][0] });
    const segs_f: f32 = @floatFromInt(segs);
    for (0..cols) |j| {
        const f = @as(f32, @floatFromInt(j)) / segs_f;
        const a = p.angle_start + sweep * f;
        const h = reliefAt(p.relief, sweep * f / tau);
        const ca = @cos(a);
        const sa = @sin(a);
        for (p.profile, 0..) |pt, k| {
            index[j * n + k] = if (k == 0 and pole_start)
                start_pole
            else if (k == n - 1 and pole_end)
                end_pole
            else
                try b.vert(.{ (pt[1] + h) * ca, (pt[1] + h) * sa, pt[0] });
        }
    }
    for (0..segs) |j| {
        const j1 = if (closed) (j + 1) % segs else j + 1;
        const uu0 = @as(f32, @floatFromInt(j)) / segs_f;
        const uu1 = @as(f32, @floatFromInt(j + 1)) / segs_f;
        for (0..n - 1) |k| {
            const a = index[j * n + k];
            const bb = index[j1 * n + k];
            const c = index[j1 * n + k + 1];
            const d = index[j * n + k + 1];
            const v0 = vs[k];
            const v1 = vs[k + 1];
            if (k == 0 and pole_start) {
                try b.face(&.{ a, c, d }, &.{ .{ (uu0 + uu1) / 2, v0 }, .{ uu1, v1 }, .{ uu0, v1 } });
            } else if (k == n - 2 and pole_end) {
                try b.face(&.{ a, bb, c }, &.{ .{ uu0, v0 }, .{ uu1, v0 }, .{ (uu0 + uu1) / 2, v1 } });
            } else {
                try b.face(&.{ a, bb, c, d }, &.{ .{ uu0, v0 }, .{ uu1, v0 }, .{ uu1, v1 }, .{ uu0, v1 } });
            }
        }
    }
    if (closed) {
        if (p.cap_start and !pole_start) try cap(&b, index, n, 0, segs, true);
        if (p.cap_end and !pole_end) try cap(&b, index, n, n - 1, segs, false);
    }
    return b.finish(p.smooth);
}

/// An n-gon over profile ring `k`: facing down for the start ring, up for
/// the end ring (when the profile runs bottom to top). Planar UVs.
fn cap(b: *prims.Builder, index: []const u32, n: usize, k: usize, segs: u32, reverse: bool) Allocator.Error!void {
    const verts = try b.gpa.alloc(u32, segs);
    defer b.gpa.free(verts);
    const uvs = try b.gpa.alloc([2]f32, segs);
    defer b.gpa.free(uvs);
    for (0..segs) |i| {
        const j = if (reverse) segs - 1 - i else i;
        verts[i] = index[j * n + k];
        const a = tau * @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(segs));
        uvs[i] = .{ 0.5 + 0.5 * @cos(a), 0.5 + 0.5 * @sin(a) };
    }
    try b.face(verts, uvs);
}

const testing = std.testing;

test "a closed revolve of two points is an open tube; caps close it" {
    const gpa = testing.allocator;
    var tube = try revolve(gpa, .{ .profile = &.{ .{ 0, 1 }, .{ 2, 1 } }, .segments = 8 });
    defer tube.releaseRefs(gpa);
    try testing.expectEqual(@as(usize, 16), tube.vertCount());
    try testing.expectEqual(@as(usize, 8), tube.faceCount());
    // Faces point away from the axis: the first quad's normal is outward.
    const pos = tube.positions.slice();
    const cv = tube.corner_verts.slice();
    const e1 = math.vec.sub(pos[cv[1]], pos[cv[0]]);
    const e2 = math.vec.sub(pos[cv[2]], pos[cv[0]]);
    const nrm = math.vec.cross(e1, e2);
    const mid = math.vec.scale(math.vec.add(pos[cv[0]], pos[cv[2]]), 0.5);
    try testing.expect(nrm[0] * mid[0] + nrm[1] * mid[1] > 0);

    var can = try revolve(gpa, .{ .profile = &.{ .{ 0, 1 }, .{ 2, 1 } }, .segments = 8, .cap_start = true, .cap_end = true });
    defer can.releaseRefs(gpa);
    try testing.expectEqual(@as(usize, 10), can.faceCount());
    // A closed surface: V - E + F = 2.
    try testing.expectEqual(@as(i64, 2), @as(i64, @intCast(can.vertCount())) - @as(i64, @intCast(can.edgeCount())) + @as(i64, @intCast(can.faceCount())));
}

test "poles become fans and a half turn keeps its seam open" {
    const gpa = testing.allocator;
    var cone = try revolve(gpa, .{ .profile = &.{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 0 } }, .segments = 6 });
    defer cone.releaseRefs(gpa);
    // Two poles + one ring of 6; 12 triangles.
    try testing.expectEqual(@as(usize, 8), cone.vertCount());
    try testing.expectEqual(@as(usize, 12), cone.faceCount());
    try testing.expectEqual(@as(i64, 2), @as(i64, @intCast(cone.vertCount())) - @as(i64, @intCast(cone.edgeCount())) + @as(i64, @intCast(cone.faceCount())));

    var half = try revolve(gpa, .{ .profile = &.{ .{ 0, 1 }, .{ 1, 1 } }, .segments = 4, .angle_end = std.math.pi });
    defer half.releaseRefs(gpa);
    try testing.expectEqual(@as(usize, 10), half.vertCount());
    try testing.expectEqual(@as(usize, 4), half.faceCount());

    try testing.expectError(error.InvalidParameter, revolve(gpa, .{ .profile = &.{ .{ 0, 1 }, .{ 1, 0 }, .{ 2, 1 } } }));
}

test "fluted relief: strip crest, engraved centre, seamless around" {
    const r: Relief = .{ .count = 4, .depth = 0.05, .groove = 0.01 };
    // Strip edges sit on the base surface; the middle is raised minus the groove.
    try testing.expectApproxEqAbs(@as(f32, 0), reliefAt(r, 0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.04), reliefAt(r, 0.125), 1e-6);
    try testing.expectApproxEqAbs(reliefAt(r, 0.03), reliefAt(r, 0.28), 1e-6);
    const gpa = testing.allocator;
    var m = try revolve(gpa, .{ .profile = &.{ .{ 0, 1 }, .{ 1, 1 } }, .segments = 32, .relief = r });
    defer m.releaseRefs(gpa);
    const pos = m.positions.slice();
    // Vertex 2 is column 1 (u = 1/32), vertex 8 is column 4 (a strip middle).
    try testing.expectApproxEqAbs(@as(f32, 1.04), @sqrt(pos[8][0] * pos[8][0] + pos[8][1] * pos[8][1]), 1e-5);
}
