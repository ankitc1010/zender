//! Triangulate faces. Quads split along one diagonal chosen by `QuadMethod`;
//! larger faces are ear-clipped and, with the beauty method, then improved
//! by edge flips. Beauty prefers well-shaped triangles: it maximises the
//! summed shape quality 4√3·area / (a² + b² + c²), which is 1 for an
//! equilateral triangle and 0 for a sliver. (The smallest angle cannot
//! serve: on a regular polygon every triangulation has the same one.)
//! Triangles keep their face's data and their corners' data.

const std = @import("std");
const math = @import("math");
const em_mod = @import("../editmesh.zig");
const ops = @import("../ops.zig");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const v = math.vec;
const EditMesh = em_mod.EditMesh;
const Outcome = ops.Outcome;
const Error = ops.Error;

pub const QuadMethod = enum { beauty, fixed, alternate, shortest_diagonal, longest_diagonal };
pub const NgonMethod = enum { beauty, clip };

pub const Params = struct {
    quad: QuadMethod = .beauty,
    ngon: NgonMethod = .beauty,
};

const Tri = [3]u32;

/// Triangulates `faces`; every resulting triangle is selected afterwards,
/// including faces that were triangles already.
pub fn triangulate(em: *EditMesh, gpa: Allocator, faces: []const u32, p: Params) Error!Outcome {
    var out: Outcome = .{ .domain = .face };
    errdefer out.deinit(gpa);
    var verts: std.ArrayList(u32) = .empty;
    defer verts.deinit(gpa);
    var loops: std.ArrayList(u32) = .empty;
    defer loops.deinit(gpa);
    var pos: std.ArrayList(Vec3) = .empty;
    defer pos.deinit(gpa);
    var tris: std.ArrayList(Tri) = .empty;
    defer tris.deinit(gpa);

    for (faces) |f| {
        try em.tick();
        const face = em.faces.items[f];
        if (face.len == 3) {
            try out.selected.append(gpa, f);
            continue;
        }
        verts.clearRetainingCapacity();
        loops.clearRetainingCapacity();
        pos.clearRetainingCapacity();
        var l = face.l;
        for (0..face.len) |_| {
            const loop = em.loops.items[l];
            try verts.append(gpa, loop.v);
            try loops.append(gpa, l);
            try pos.append(gpa, em.verts.items[loop.v].co);
            l = loop.next;
        }
        tris.clearRetainingCapacity();
        const normal = em.faceNormal(f);
        if (face.len == 4) {
            const two = quadSplit(pos.items, normal, p.quad);
            try tris.appendSlice(gpa, &two);
        } else {
            try polygon(em, gpa, pos.items, normal, p.ngon, &tris);
        }
        em.removeFace(f);
        for (tris.items) |t| {
            const tv = [3]u32{ verts.items[t[0]], verts.items[t[1]], verts.items[t[2]] };
            const tl = [3]u32{ loops.items[t[0]], loops.items[t[1]], loops.items[t[2]] };
            try out.selected.append(gpa, try em.addFace(&tv, .{ .face = f, .loops = &tl }));
        }
    }
    return out;
}

/// The two triangles of a quad (corners 0..3 in order).
fn quadSplit(p: []const Vec3, n: Vec3, method: QuadMethod) [2]Tri {
    const a: [2]Tri = .{ .{ 0, 1, 2 }, .{ 0, 2, 3 } };
    const b: [2]Tri = .{ .{ 0, 1, 3 }, .{ 1, 2, 3 } };
    const d02 = v.length(v.sub(p[2], p[0]));
    const d13 = v.length(v.sub(p[3], p[1]));
    return switch (method) {
        .fixed => a,
        .alternate => b,
        .shortest_diagonal => if (d13 < d02) b else a,
        .longest_diagonal => if (d13 > d02) b else a,
        .beauty => {
            // A concave quad has one diagonal inside it; otherwise take the
            // better-shaped split.
            const ok_a = facing(p, a[0], n) and facing(p, a[1], n);
            const ok_b = facing(p, b[0], n) and facing(p, b[1], n);
            if (ok_a != ok_b) return if (ok_a) a else b;
            const qa = quality(p, a[0]) + quality(p, a[1]);
            const qb = quality(p, b[0]) + quality(p, b[1]);
            return if (qb > qa + 1e-6) b else a;
        },
    };
}

fn polygon(em: *EditMesh, gpa: Allocator, p: []const Vec3, n: Vec3, method: NgonMethod, tris: *std.ArrayList(Tri)) Error!void {
    const corners = try gpa.alloc(u32, p.len);
    defer gpa.free(corners);
    for (corners, 0..) |*c, i| c.* = @intCast(i);
    var flat: std.ArrayList(u32) = .empty;
    defer flat.deinit(gpa);
    try math.triangulate.triangulate(gpa, p, corners, &flat);
    var i: usize = 0;
    while (i + 2 < flat.items.len) : (i += 3) try tris.append(gpa, .{ flat.items[i], flat.items[i + 1], flat.items[i + 2] });
    if (method == .beauty) try beautify(em, gpa, p, n, tris.items);
}

/// Lawson flips: for each interior edge shared by two triangles, flip it
/// when that raises the pair's summed quality and keeps both triangles
/// facing the polygon's way. Every flip raises the total, so the loop ends;
/// the budget only bounds pathological input.
fn beautify(em: *EditMesh, gpa: Allocator, p: []const Vec3, n: Vec3, tris: []Tri) Error!void {
    const Key = u64;
    const key = struct {
        fn of(a: u32, b: u32) Key {
            return (@as(u64, @min(a, b)) << 32) | @max(a, b);
        }
    }.of;
    // Edge → the (up to two) triangles that use it.
    var adj: std.AutoHashMapUnmanaged(Key, [2]u32) = .empty;
    defer adj.deinit(gpa);
    var stack: std.ArrayList(Key) = .empty;
    defer stack.deinit(gpa);
    const empty = std.math.maxInt(u32);
    for (tris, 0..) |t, ti| for (0..3) |k| {
        const kk = key(t[k], t[(k + 1) % 3]);
        const gop = try adj.getOrPut(gpa, kk);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ @intCast(ti), empty };
        } else {
            gop.value_ptr[1] = @intCast(ti);
            try stack.append(gpa, kk);
        }
    };
    var budget = 8 * tris.len * tris.len + 64;
    while (stack.pop()) |kk| {
        try em.tick();
        if (budget == 0) break;
        budget -= 1;
        const pair = adj.get(kk) orelse continue;
        if (pair[1] == empty) continue;
        const e0: u32 = @intCast(kk >> 32);
        const e1: u32 = @truncate(kk);
        const t0 = tris[pair[0]];
        const t1 = tris[pair[1]];
        const x = opposite(t0, e0, e1);
        const y = opposite(t1, e0, e1);
        // t0 runs e_a → e_b → x; keep that winding in the flipped pair.
        const ea, const eb = ordered(t0, e0, e1);
        const n0: Tri = .{ x, ea, y };
        const n1: Tri = .{ y, eb, x };
        if (adj.contains(key(x, y))) continue;
        if (!facing(p, n0, n) or !facing(p, n1, n)) continue;
        const before = quality(p, t0) + quality(p, t1);
        const after = quality(p, n0) + quality(p, n1);
        if (after <= before + 1e-5) continue;
        tris[pair[0]] = n0;
        tris[pair[1]] = n1;
        _ = adj.remove(kk);
        try adj.put(gpa, key(x, y), pair);
        // The outer edges now belong to possibly different triangles.
        for ([_]Tri{ n0, n1 }, [_]u32{ pair[0], pair[1] }) |t, ti| for (0..3) |k| {
            const ok = key(t[k], t[(k + 1) % 3]);
            if (ok == key(x, y)) continue;
            const slot = adj.getPtr(ok).?;
            if (slot[0] == pair[0] or slot[0] == pair[1]) slot[0] = ti else if (slot[1] == pair[0] or slot[1] == pair[1]) slot[1] = ti;
            if (slot[1] != empty) try stack.append(gpa, ok);
        };
    }
}

fn opposite(t: Tri, a: u32, b: u32) u32 {
    for (t) |c| if (c != a and c != b) return c;
    unreachable;
}

/// The shared edge's corners in the order the triangle visits them.
fn ordered(t: Tri, a: u32, b: u32) struct { u32, u32 } {
    for (0..3) |k| if (t[k] == a and t[(k + 1) % 3] == b) return .{ a, b };
    return .{ b, a };
}

fn facing(p: []const Vec3, t: Tri, n: Vec3) bool {
    const c = v.cross(v.sub(p[t[1]], p[t[0]]), v.sub(p[t[2]], p[t[0]]));
    return v.dot(c, n) > 0;
}

/// 4√3·area / (sum of squared side lengths): 1 when equilateral.
fn quality(p: []const Vec3, t: Tri) f32 {
    const ab = v.sub(p[t[1]], p[t[0]]);
    const bc = v.sub(p[t[2]], p[t[1]]);
    const ca = v.sub(p[t[0]], p[t[2]]);
    const sq = v.dot(ab, ab) + v.dot(bc, bc) + v.dot(ca, ca);
    if (sq == 0) return 0;
    return 2 * @sqrt(3.0) * v.length(v.cross(ab, ca)) / sq;
}

const testing = std.testing;
const prims = @import("../primitives.zig");
const build = @import("../build.zig");

test "triangulating a cube and a cylinder keeps area and data" {
    const gpa = testing.allocator;
    var cube = try prims.generate(gpa, .cube, .{});
    defer cube.releaseRefs(gpa);
    var em = try EditMesh.fromMesh(gpa, &cube);
    defer em.deinit();
    var out = try triangulate(&em, gpa, &.{ 0, 1, 2, 3, 4, 5 }, .{});
    defer out.deinit(gpa);
    try testing.expectEqual(@as(usize, 12), out.selected.items.len);
    try testing.expect(em.check() == null);
    var m = try em.toMesh(gpa, null);
    defer m.releaseRefs(gpa);
    try testing.expect(build.validate(&m) == null);
    try testing.expectEqual(@as(usize, 12), m.faceCount());
    try testing.expectEqual(@as(usize, 18), m.edgeCount());
    try testing.expectEqual(@as(usize, 36), m.attribute(Mesh.uv_name).?.data.len());

    // The 32-gon caps of a cylinder: 30 triangles each, better shaped
    // than the fan the ear clipper gives.
    var cyl = try prims.generate(gpa, .cylinder, .{});
    defer cyl.releaseRefs(gpa);
    var em2 = try EditMesh.fromMesh(gpa, &cyl);
    defer em2.deinit();
    var caps: std.ArrayList(u32) = .empty;
    defer caps.deinit(gpa);
    for (em2.faces.items, 0..) |f, i| if (f.len > 4) try caps.append(gpa, @intCast(i));
    try testing.expectEqual(@as(usize, 2), caps.items.len);
    var fan = try triangulate(&em2, gpa, caps.items, .{ .ngon = .clip });
    defer fan.deinit(gpa);
    var em3 = try EditMesh.fromMesh(gpa, &cyl);
    defer em3.deinit();
    var nice = try triangulate(&em3, gpa, caps.items, .{});
    defer nice.deinit(gpa);
    try testing.expectEqual(@as(usize, 60), nice.selected.items.len);
    try testing.expect(em3.check() == null);
    const total = struct {
        fn of(e: *const EditMesh, faces: []const u32) f32 {
            var q: f32 = 0;
            for (faces) |f| {
                var p: [3]Vec3 = undefined;
                var l = e.faces.items[f].l;
                for (&p) |*x| {
                    x.* = e.verts.items[e.loops.items[l].v].co;
                    l = e.loops.items[l].next;
                }
                q += quality(&p, .{ 0, 1, 2 });
            }
            return q;
        }
    }.of;
    // About 14.0 against 9.7 on the phone.
    try testing.expect(total(&em3, nice.selected.items) > 1.3 * total(&em2, fan.selected.items));
}

test "quad methods pick the stated diagonal; concave quads stay inside" {
    const sq = [_]Vec3{ .{ 0, 0, 0 }, .{ 2, 0, 0 }, .{ 2, 1, 0 }, .{ 0, 1, 0 } };
    const n: Vec3 = .{ 0, 0, 1 };
    try testing.expectEqual([2]Tri{ .{ 0, 1, 2 }, .{ 0, 2, 3 } }, quadSplit(&sq, n, .fixed));
    try testing.expectEqual([2]Tri{ .{ 0, 1, 3 }, .{ 1, 2, 3 } }, quadSplit(&sq, n, .alternate));
    // A dart: corner 2 is pushed in past the 1-3 diagonal.
    const dart = [_]Vec3{ .{ 0, 0, 0 }, .{ 2, 0, 0 }, .{ 0.4, 0.4, 0 }, .{ 0, 2, 0 } };
    try testing.expectEqual([2]Tri{ .{ 0, 1, 2 }, .{ 0, 2, 3 } }, quadSplit(&dart, n, .beauty));
}

const Mesh = @import("../../core/root.zig").types.Mesh;
