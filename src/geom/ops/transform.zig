//! Element transforms: move, rotate and scale selected vertices in world
//! space about a pivot, without changing topology.

const std = @import("std");
const math = @import("math");
const select = @import("../select.zig");
const ops = @import("../ops.zig");

const Vec3 = math.Vec3;
const Quat = math.Quat;
const v = math.vec;
const Xform = ops.Xform;
const Bits = select.Bits;

pub const Params = struct {
    translate: Vec3 = .{ 0, 0, 0 },
    rotate: Quat = v.quat_identity,
    scale: Vec3 = .{ 1, 1, 1 },
    /// World-space point that rotation and scale keep fixed.
    pivot: Vec3 = .{ 0, 0, 0 },
};

/// Scales, then rotates, about the pivot, then translates each selected
/// vertex, all along world axes. Unselected vertices are not touched.
pub fn apply(positions: []Vec3, verts: *const Bits, xf: Xform, p: Params) void {
    const r = v.quatToMat(v.quatNormalize(p.rotate));
    var it = verts.iterator(.{});
    while (it.next()) |i| {
        const w = xf.toWorld(positions[i]);
        const local = v.mul(v.sub(w, p.pivot), p.scale);
        const moved = v.add(v.add(p.pivot, v.transformDir(r, local)), p.translate);
        positions[i] = xf.toLocal(moved);
    }
}

/// Mean world position of the selected vertices (Blender's median point).
pub fn median(positions: []const Vec3, verts: *const Bits, xf: Xform) Vec3 {
    var acc: [3]f64 = .{ 0, 0, 0 };
    var n: f64 = 0;
    var it = verts.iterator(.{});
    while (it.next()) |i| {
        const w = xf.toWorld(positions[i]);
        for (0..3) |k| acc[k] += w[k];
        n += 1;
    }
    if (n == 0) return xf.toWorld(.{ 0, 0, 0 });
    return .{ @floatCast(acc[0] / n), @floatCast(acc[1] / n), @floatCast(acc[2] / n) };
}

/// World bounds of the selected vertices, or null when none are selected.
pub fn bounds(positions: []const Vec3, verts: *const Bits, xf: Xform) ?[2]Vec3 {
    var it = verts.iterator(.{});
    const first = it.next() orelse return null;
    var lo = xf.toWorld(positions[first]);
    var hi = lo;
    while (it.next()) |i| {
        const w = xf.toWorld(positions[i]);
        lo = v.min3(lo, w);
        hi = v.max3(hi, w);
    }
    return .{ lo, hi };
}

test "scale and rotate about the median, translate in world space" {
    const gpa = std.testing.allocator;
    var pos = [_]Vec3{ .{ 0, 0, 0 }, .{ 2, 0, 0 }, .{ 2, 2, 0 }, .{ 9, 9, 9 } };
    var sel = try Bits.initEmpty(gpa, 4);
    defer sel.deinit(gpa);
    sel.setRangeValue(.{ .start = 0, .end = 3 }, true);
    // The object sits at x = 10, so local x = 0 is world x = 10.
    const xf = Xform.init(v.compose(.{ 10, 0, 0 }, v.quat_identity, .{ 1, 1, 1 })).?;
    const pivot = median(&pos, &sel, xf);
    try std.testing.expectApproxEqAbs(@as(f32, 11.333333), pivot[0], 1e-5);
    apply(&pos, &sel, xf, .{ .scale = .{ 2, 2, 2 }, .rotate = v.quatAxisAngle(.{ 0, 0, 1 }, std.math.pi), .translate = .{ 0, 0, 1 }, .pivot = pivot });
    // Half a turn about the pivot after doubling: p' = pivot - 2 (p - pivot).
    try std.testing.expectApproxEqAbs(@as(f32, 4), pos[0][0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), pos[0][1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), pos[0][2], 1e-6);
    try std.testing.expectEqual(Vec3{ 9, 9, 9 }, pos[3]);
}
