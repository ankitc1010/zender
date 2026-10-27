//! Smooth vertices: each pass moves every weighted vertex toward the mean
//! of its neighbours (Laplacian smoothing). With `preserve_volume`, each
//! pass is followed by a slightly stronger step back the other way
//! (Taubin's λ|μ smoothing), which removes bumps without shrinking the
//! shape. Weights come from a selector and, optionally, a falloff, so a
//! seam can be blended into its surroundings. Boundary vertices stay put
//! unless asked otherwise, so open edges do not creep inward.
//!
//! The neighbour mean is an affine combination, so smoothing in the mesh's
//! local space gives the same result as in world space.

const std = @import("std");
const math = @import("math");
const core = @import("../../core/root.zig");
const em_mod = @import("../editmesh.zig");
const falloff = @import("falloff.zig");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const v = math.vec;
const Mesh = core.types.Mesh;

pub const max_iterations = 500;

pub const Params = struct {
    iterations: u32 = 5,
    /// Fraction of the way to the neighbour mean per pass, 0..1.
    factor: f32 = 0.5,
    preserve_volume: bool = true,
    pin_boundary: bool = true,
};

/// Smooths `positions` (the mesh's, local space) in place. `weight` is per
/// vertex: 0 leaves a vertex alone, 1 smooths it fully.
pub fn smooth(gpa: Allocator, m: *const Mesh, positions: []Vec3, weight: []const f32, p: Params, stop: ?em_mod.Stop) (Allocator.Error || math.DeadlineError)!void {
    var adj = try falloff.Adjacency.init(gpa, m);
    defer adj.deinit(gpa);
    const w = try gpa.dupe(f32, weight);
    defer gpa.free(w);
    if (p.pin_boundary) {
        // Vertices of edges with other than two faces.
        const uses = try gpa.alloc(u32, m.edgeCount());
        defer gpa.free(uses);
        @memset(uses, 0);
        for (m.corner_edges.slice()) |e| uses[e] += 1;
        for (m.edges.slice(), uses) |e, n| if (n != 2) {
            w[e[0]] = 0;
            w[e[1]] = 0;
        };
    }
    const tmp = try gpa.alloc(Vec3, positions.len);
    defer gpa.free(tmp);
    const lambda = std.math.clamp(p.factor, 0, 1);
    // Pass band 0.1: 1/λ + 1/μ = 0.1.
    const mu = -lambda / (1 - 0.1 * lambda);
    for (0..std.math.clamp(p.iterations, 1, max_iterations)) |_| {
        for ([2]f32{ lambda, mu }, 0..) |step, k| {
            if (k == 1 and !p.preserve_volume) break;
            for (positions, tmp, 0..) |q, *o, i| {
                o.* = q;
                if (w[i] == 0) continue;
                const ns = adj.of(@intCast(i));
                if (ns.len == 0) continue;
                var mean: [3]f64 = .{ 0, 0, 0 };
                for (ns) |n| for (0..3) |c| {
                    mean[c] += positions[n][c];
                };
                const inv = 1 / @as(f64, @floatFromInt(ns.len));
                const target: Vec3 = .{ @floatCast(mean[0] * inv), @floatCast(mean[1] * inv), @floatCast(mean[2] * inv) };
                o.* = v.add(q, v.scale(v.sub(target, q), step * w[i]));
            }
            @memcpy(positions, tmp);
            if (stop) |s| if (s.deadline.passed(s.io)) return error.DeadlineExceeded;
        }
    }
}

const testing = std.testing;
const prims = @import("../primitives.zig");

fn roughness(pos: []const Vec3) f32 {
    // Spread of distances from the origin: 0 for a perfect sphere.
    var lo: f32 = std.math.inf(f32);
    var hi: f32 = 0;
    for (pos) |q| {
        lo = @min(lo, v.length(q));
        hi = @max(hi, v.length(q));
    }
    return hi - lo;
}

test "smoothing removes noise; Taubin keeps the size, plain Laplacian shrinks" {
    const gpa = testing.allocator;
    var s = try prims.generate(gpa, .ico_sphere, .{ .subdivisions = 3 });
    defer s.releaseRefs(gpa);
    const base = try gpa.dupe(Vec3, s.positions.slice());
    defer gpa.free(base);
    // Deterministic bumps on alternate vertices.
    for (base, 0..) |*q, i| q.* = v.scale(q.*, if (i % 2 == 0) 1.08 else 0.92);
    const ones = try gpa.alloc(f32, base.len);
    defer gpa.free(ones);
    @memset(ones, 1);

    const taubin = try gpa.dupe(Vec3, base);
    defer gpa.free(taubin);
    try smooth(gpa, &s, taubin, ones, .{ .iterations = 10 }, null);
    const plain = try gpa.dupe(Vec3, base);
    defer gpa.free(plain);
    try smooth(gpa, &s, plain, ones, .{ .iterations = 10, .preserve_volume = false }, null);

    try testing.expect(roughness(taubin) < 0.6 * roughness(base));
    var mean_t: f32 = 0;
    var mean_p: f32 = 0;
    for (taubin, plain) |a, b| {
        mean_t += v.length(a);
        mean_p += v.length(b);
    }
    mean_t /= @floatFromInt(base.len);
    mean_p /= @floatFromInt(base.len);
    try testing.expect(mean_t > 0.97);
    try testing.expect(mean_p < mean_t);

    // Zero weight: untouched.
    const none = try gpa.alloc(f32, base.len);
    defer gpa.free(none);
    @memset(none, 0);
    const still = try gpa.dupe(Vec3, base);
    defer gpa.free(still);
    try smooth(gpa, &s, still, none, .{}, null);
    try testing.expectEqualSlices(Vec3, base, still);
}
