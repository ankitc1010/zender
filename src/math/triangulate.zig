//! Polygon triangulation by ear clipping, deterministic for a given input.
//!
//! The polygon is projected onto the plane of its Newell normal. Convex
//! polygons (every primitive face) come out as a fan from the first corner,
//! which is also what ear clipping produces for them; concave n-gons get
//! proper ears. Degenerate polygons fall back to a fan so no corner is lost.

const std = @import("std");
const vec = @import("vec.zig");
const Vec3 = vec.Vec3;

/// Newell's method: robust normal for planar or slightly non-planar polygons.
/// Not normalised; its length is twice the projected area.
pub fn newellNormal(positions: []const Vec3, corners: []const u32) Vec3 {
    var n: Vec3 = .{ 0, 0, 0 };
    for (corners, 0..) |vi, k| {
        const a = positions[vi];
        const b = positions[corners[(k + 1) % corners.len]];
        n[0] += (a[1] - b[1]) * (a[2] + b[2]);
        n[1] += (a[2] - b[2]) * (a[0] + b[0]);
        n[2] += (a[0] - b[0]) * (a[1] + b[1]);
    }
    return n;
}

/// Appends `(corners.len - 2) * 3` local corner indices (0-based offsets into
/// `corners`) to `out`, three per triangle, winding preserved.
pub fn triangulate(
    gpa: std.mem.Allocator,
    positions: []const Vec3,
    corners: []const u32,
    out: *std.ArrayList(u32),
) !void {
    const n = corners.len;
    if (n < 3) return;
    if (n == 3) {
        try out.appendSlice(gpa, &.{ 0, 1, 2 });
        return;
    }
    const normal = newellNormal(positions, corners);
    if (n == 4 or isConvex(positions, corners, normal)) return fan(gpa, n, out);

    // Project to 2D on the dominant axis of the normal.
    const ax = dominantAxis(normal);
    const flip = normal[ax] < 0;
    var pts = try gpa.alloc([2]f32, n);
    defer gpa.free(pts);
    for (corners, 0..) |vi, k| pts[k] = project(positions[vi], ax, flip);

    var remaining = try std.ArrayList(u32).initCapacity(gpa, n);
    defer remaining.deinit(gpa);
    for (0..n) |k| remaining.appendAssumeCapacity(@intCast(k));

    var guard: usize = 0;
    var i: usize = 0;
    while (remaining.items.len > 3) {
        const m = remaining.items.len;
        const ia = remaining.items[(i + m - 1) % m];
        const ib = remaining.items[i % m];
        const ic = remaining.items[(i + 1) % m];
        if (isEar(pts, remaining.items, ia, ib, ic)) {
            try out.appendSlice(gpa, &.{ ia, ib, ic });
            _ = remaining.orderedRemove(i % m);
            guard = 0;
            if (i >= remaining.items.len) i = 0;
            continue;
        }
        i = (i + 1) % m;
        guard += 1;
        if (guard > m) {
            // No ear found (self-intersecting or degenerate): fan the rest.
            const rest = remaining.items;
            for (1..rest.len - 1) |k| try out.appendSlice(gpa, &.{ rest[0], rest[k], rest[k + 1] });
            return;
        }
    }
    try out.appendSlice(gpa, &.{ remaining.items[0], remaining.items[1], remaining.items[2] });
}

fn fan(gpa: std.mem.Allocator, n: usize, out: *std.ArrayList(u32)) !void {
    for (1..n - 1) |k| try out.appendSlice(gpa, &.{ 0, @intCast(k), @intCast(k + 1) });
}

fn isConvex(positions: []const Vec3, corners: []const u32, normal: Vec3) bool {
    const n = corners.len;
    for (0..n) |k| {
        const a = positions[corners[k]];
        const b = positions[corners[(k + 1) % n]];
        const c = positions[corners[(k + 2) % n]];
        if (vec.dot(vec.cross(vec.sub(b, a), vec.sub(c, b)), normal) < 0) return false;
    }
    return true;
}

fn dominantAxis(n: Vec3) usize {
    const ax = @abs(n[0]);
    const ay = @abs(n[1]);
    const az = @abs(n[2]);
    if (az >= ax and az >= ay) return 2;
    if (ay >= ax) return 1;
    return 0;
}

fn project(p: Vec3, ax: usize, flip: bool) [2]f32 {
    const uv: [2]f32 = switch (ax) {
        0 => .{ p[1], p[2] },
        1 => .{ p[2], p[0] },
        else => .{ p[0], p[1] },
    };
    return if (flip) .{ uv[1], uv[0] } else uv;
}

fn cross2(o: [2]f32, a: [2]f32, b: [2]f32) f32 {
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
}

fn isEar(pts: []const [2]f32, ring: []const u32, ia: u32, ib: u32, ic: u32) bool {
    const a = pts[ia];
    const b = pts[ib];
    const c = pts[ic];
    if (cross2(a, b, c) <= 0) return false; // reflex or degenerate corner
    for (ring) |k| {
        if (k == ia or k == ib or k == ic) continue;
        const p = pts[k];
        if (cross2(a, b, p) >= 0 and cross2(b, c, p) >= 0 and cross2(c, a, p) >= 0) return false;
    }
    return true;
}

test "concave L-shape triangulates into 4 triangles covering its area" {
    const gpa = std.testing.allocator;
    const pos = [_]Vec3{ .{ 0, 0, 0 }, .{ 2, 0, 0 }, .{ 2, 1, 0 }, .{ 1, 1, 0 }, .{ 1, 2, 0 }, .{ 0, 2, 0 } };
    const corners = [_]u32{ 0, 1, 2, 3, 4, 5 };
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(gpa);
    try triangulate(gpa, &pos, &corners, &out);
    try std.testing.expectEqual(@as(usize, 12), out.items.len);
    var area: f32 = 0;
    var t: usize = 0;
    while (t < out.items.len) : (t += 3) {
        const a = pos[out.items[t]];
        const b = pos[out.items[t + 1]];
        const c = pos[out.items[t + 2]];
        const z = vec.cross(vec.sub(b, a), vec.sub(c, a))[2];
        try std.testing.expect(z > 0); // winding kept
        area += z / 2;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 3), area, 1e-5);
}
