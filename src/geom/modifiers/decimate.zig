//! Decimate, collapse mode: quadric error metric edge collapses (Garland &
//! Heckbert, 1997) until `ratio` of the triangles remain. Each vertex
//! carries the summed squared distance to its original faces' planes;
//! open borders add steep planes so they keep their outline. An edge
//! collapses to whichever of its ends or midpoint costs least; collapses
//! that would flip a face or pinch the surface (more than two shared
//! neighbours) are refused. The result is all triangles. Face data
//! (material slot, smooth shading) follows each triangle's source face; the
//! UV map is dropped, since UV seams do not survive collapses.

const std = @import("std");
const math = @import("math");
const core = @import("../../core/root.zig");
const mods = @import("../modifiers.zig");
const em_mod = @import("../editmesh.zig");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const Mesh = core.types.Mesh;

const V3 = [3]f64;

fn sub(a: V3, b: V3) V3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
fn cross(a: V3, b: V3) V3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
fn dot(a: V3, b: V3) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
fn len(a: V3) f64 {
    return @sqrt(dot(a, a));
}

/// Symmetric 4x4 quadric, upper triangle.
const Quadric = [10]f64;

fn planeQuadric(n: V3, d: f64, w: f64) Quadric {
    const p = [4]f64{ n[0], n[1], n[2], d };
    var q: Quadric = undefined;
    var k: usize = 0;
    for (0..4) |i| for (i..4) |j| {
        q[k] = w * p[i] * p[j];
        k += 1;
    };
    return q;
}

fn addQ(a: *Quadric, b: Quadric) void {
    for (a, b) |*x, y| x.* += y;
}

fn evalQ(q: Quadric, p: V3) f64 {
    const x = [4]f64{ p[0], p[1], p[2], 1 };
    var s: f64 = 0;
    var k: usize = 0;
    for (0..4) |i| for (i..4) |j| {
        s += (if (i == j) @as(f64, 1) else 2) * q[k] * x[i] * x[j];
        k += 1;
    };
    return s;
}

const Candidate = struct {
    cost: f64,
    a: u32,
    b: u32,
    va: u32,
    vb: u32,
};

fn order(_: void, x: Candidate, y: Candidate) std.math.Order {
    return switch (std.math.order(x.cost, y.cost)) {
        .eq => switch (std.math.order(x.a, y.a)) {
            .eq => std.math.order(x.b, y.b),
            else => |o| o,
        },
        else => |o| o,
    };
}

pub fn collapse(gpa: Allocator, m: *const Mesh, ratio: f32, stop: ?em_mod.Stop) mods.Error!Mesh {
    const s = mods.Source.init(m);
    // Triangles, each with its source face.
    var tris: std.ArrayList([3]u32) = .empty;
    defer tris.deinit(gpa);
    var tri_face: std.ArrayList(u32) = .empty;
    defer tri_face.deinit(gpa);
    var flat: std.ArrayList(u32) = .empty;
    defer flat.deinit(gpa);
    for (0..s.faces()) |f| {
        flat.clearRetainingCapacity();
        const cs = s.cv[s.off[f]..s.off[f + 1]];
        try math.triangulate.triangulate(gpa, s.pos, cs, &flat);
        var i: usize = 0;
        while (i + 2 < flat.items.len) : (i += 3) {
            try tris.append(gpa, .{ cs[flat.items[i]], cs[flat.items[i + 1]], cs[flat.items[i + 2]] });
            try tri_face.append(gpa, @intCast(f));
        }
    }
    const nv = s.pos.len;
    const pos = try gpa.alloc(V3, nv);
    defer gpa.free(pos);
    for (s.pos, pos) |p, *q| q.* = .{ p[0], p[1], p[2] };

    // Quadrics from face planes, plus steep planes along open edges.
    const quad = try gpa.alloc(Quadric, nv);
    defer gpa.free(quad);
    @memset(quad, @splat(0));
    var edge_uses: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer edge_uses.deinit(gpa);
    for (tris.items) |t| {
        const n = cross(sub(pos[t[1]], pos[t[0]]), sub(pos[t[2]], pos[t[0]]));
        const area2 = len(n);
        if (area2 == 0) continue;
        const u: V3 = .{ n[0] / area2, n[1] / area2, n[2] / area2 };
        const q = planeQuadric(u, -dot(u, pos[t[0]]), area2 / 2);
        for (t) |x| addQ(&quad[x], q);
        for (0..3) |k| {
            const gop = try edge_uses.getOrPut(gpa, key(t[k], t[(k + 1) % 3]));
            gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        }
    }
    for (tris.items) |t| {
        const n = cross(sub(pos[t[1]], pos[t[0]]), sub(pos[t[2]], pos[t[0]]));
        for (0..3) |k| {
            const a = t[k];
            const b = t[(k + 1) % 3];
            if (edge_uses.get(key(a, b)).? != 1) continue;
            const e = sub(pos[b], pos[a]);
            var pn = cross(e, n);
            const l = len(pn);
            if (l == 0) continue;
            pn = .{ pn[0] / l, pn[1] / l, pn[2] / l };
            const q = planeQuadric(pn, -dot(pn, pos[a]), 1000 * dot(e, e));
            addQ(&quad[a], q);
            addQ(&quad[b], q);
        }
    }

    // Triangles around each vertex.
    const vt = try gpa.alloc(std.ArrayList(u32), nv);
    defer {
        for (vt) |*l| l.deinit(gpa);
        gpa.free(vt);
    }
    for (vt) |*l| l.* = .empty;
    for (tris.items, 0..) |t, i| for (t) |x| try vt[x].append(gpa, @intCast(i));
    const tri_dead = try gpa.alloc(bool, tris.items.len);
    defer gpa.free(tri_dead);
    @memset(tri_dead, false);
    const vert_dead = try gpa.alloc(bool, nv);
    defer gpa.free(vert_dead);
    @memset(vert_dead, false);
    const version = try gpa.alloc(u32, nv);
    defer gpa.free(version);
    @memset(version, 0);

    var heap = std.PriorityQueue(Candidate, void, order).empty;
    defer heap.deinit(gpa);
    var it = edge_uses.keyIterator();
    var keys: std.ArrayList(u64) = .empty;
    defer keys.deinit(gpa);
    while (it.next()) |k| try keys.append(gpa, k.*);
    // Hash order is not stable across runs of the map's growth; sort.
    std.mem.sort(u64, keys.items, {}, std.sort.asc(u64));
    for (keys.items) |k| try heap.push(gpa, candidate(quad, pos, version, @intCast(k >> 32), @truncate(k)));

    var live: usize = tris.items.len;
    const target: usize = @intFromFloat(@ceil(@as(f64, @floatFromInt(tris.items.len)) * std.math.clamp(ratio, 0, 1)));
    var nbr_a: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
    defer nbr_a.deinit(gpa);
    var nbr_b: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
    defer nbr_b.deinit(gpa);
    var steps: u32 = 0;
    while (live > target) {
        const cand = heap.pop() orelse break;
        steps +%= 1;
        if (steps % 1024 == 0) if (stop) |st| if (st.deadline.passed(st.io)) return error.DeadlineExceeded;
        const a = cand.a;
        const b = cand.b;
        if (vert_dead[a] or vert_dead[b] or version[a] != cand.va or version[b] != cand.vb) continue;
        // Live triangles on the edge (none: the edge is gone).
        var uses: usize = 0;
        for (vt[a].items) |t| {
            if (tri_dead[t]) continue;
            const tri = tris.items[t];
            uses += @intFromBool(tri[0] == b or tri[1] == b or tri[2] == b);
        }
        if (uses == 0 or uses > 2) continue;
        const p = bestPoint(quad, pos, a, b);
        // Link condition: the ends share only the edge's own neighbours.
        try neighbours(gpa, vt, tris.items, tri_dead, a, &nbr_a);
        try neighbours(gpa, vt, tris.items, tri_dead, b, &nbr_b);
        var shared: usize = 0;
        for (nbr_a.keys()) |x| shared += @intFromBool(nbr_b.contains(x));
        if (shared != uses) continue;
        if (flips(vt, tris.items, tri_dead, pos, a, b, p) or flips(vt, tris.items, tri_dead, pos, b, a, p)) continue;

        // Collapse b into a.
        for (vt[b].items) |t| {
            if (tri_dead[t]) continue;
            const tri = &tris.items[t];
            if (tri[0] == a or tri[1] == a or tri[2] == a) {
                tri_dead[t] = true;
                live -= 1;
            } else {
                for (tri) |*x| if (x.* == b) {
                    x.* = a;
                };
                try vt[a].append(gpa, t);
            }
        }
        vt[b].clearRetainingCapacity();
        vert_dead[b] = true;
        pos[a] = p;
        addQ(&quad[a], quad[b]);
        version[a] += 1;
        // Edges around a have new costs.
        try neighbours(gpa, vt, tris.items, tri_dead, a, &nbr_a);
        for (nbr_a.keys()) |n| try heap.push(gpa, candidate(quad, pos, version, @min(a, n), @max(a, n)));
    }

    // Compact.
    var b = mods.Builder.init(gpa, false);
    defer b.deinit();
    const remap = try gpa.alloc(u32, nv);
    defer gpa.free(remap);
    @memset(remap, std.math.maxInt(u32));
    for (tris.items, 0..) |t, i| {
        if (tri_dead[i]) continue;
        try b.beginFace();
        for (t) |x| {
            if (remap[x] == std.math.maxInt(u32)) remap[x] = try b.vert(.{ @floatCast(pos[x][0]), @floatCast(pos[x][1]), @floatCast(pos[x][2]) });
            try b.corner(remap[x], .{ 0, 0 });
        }
        const f = tri_face.items[i];
        try b.endFace(s.faceSharp(f), s.faceMat(f));
    }
    return b.finish(m);
}

fn key(a: u32, b: u32) u64 {
    return @as(u64, @min(a, b)) << 32 | @max(a, b);
}

fn bestPoint(quad: []const Quadric, pos: []const V3, a: u32, b: u32) V3 {
    var q = quad[a];
    addQ(&q, quad[b]);
    const mid: V3 = .{ (pos[a][0] + pos[b][0]) / 2, (pos[a][1] + pos[b][1]) / 2, (pos[a][2] + pos[b][2]) / 2 };
    var best = pos[a];
    var cost = evalQ(q, pos[a]);
    for ([_]V3{ mid, pos[b] }) |c| {
        const e = evalQ(q, c);
        if (e < cost - 1e-15) {
            cost = e;
            best = c;
        }
    }
    return best;
}

fn candidate(quad: []const Quadric, pos: []const V3, version: []const u32, a: u32, b: u32) Candidate {
    var q = quad[a];
    addQ(&q, quad[b]);
    return .{ .cost = evalQ(q, bestPoint(quad, pos, a, b)), .a = a, .b = b, .va = version[a], .vb = version[b] };
}

fn neighbours(gpa: Allocator, vt: []const std.ArrayList(u32), tris: []const [3]u32, dead: []const bool, x: u32, out: *std.AutoArrayHashMapUnmanaged(u32, void)) Allocator.Error!void {
    out.clearRetainingCapacity();
    for (vt[x].items) |t| {
        if (dead[t]) continue;
        for (tris[t]) |y| if (y != x) try out.put(gpa, y, {});
    }
}

/// Whether moving `x` to `p` (as b collapses into a) turns any surviving
/// triangle around `x` over or makes it degenerate.
fn flips(vt: []const std.ArrayList(u32), tris: []const [3]u32, dead: []const bool, pos: []const V3, x: u32, other: u32, p: V3) bool {
    for (vt[x].items) |t| {
        if (dead[t]) continue;
        const tri = tris[t];
        if (tri[0] == other or tri[1] == other or tri[2] == other) continue;
        var q: [3]V3 = undefined;
        for (tri, &q) |y, *o| o.* = pos[y];
        const before = cross(sub(q[1], q[0]), sub(q[2], q[0]));
        for (tri, &q) |y, *o| {
            if (y == x) o.* = p;
        }
        const after = cross(sub(q[1], q[0]), sub(q[2], q[0]));
        const lb = len(before);
        const la = len(after);
        if (la < 1e-12 * @max(lb, 1e-30)) return true;
        if (dot(before, after) < 0.2 * lb * la) return true;
    }
    return false;
}

const testing = std.testing;
const prims = @import("../primitives.zig");
const build = @import("../build.zig");

test "decimating a sphere keeps its shape and closes its surface" {
    const gpa = testing.allocator;
    var sphere = try prims.generate(gpa, .uv_sphere, .{ .segments = 32, .rings = 16 });
    defer sphere.releaseRefs(gpa);
    var half = try collapse(gpa, &sphere, 0.25, null);
    defer half.releaseRefs(gpa);
    try testing.expect(build.validate(&half) == null);
    const tris_before = sphere.triangleCount();
    try testing.expect(half.faceCount() <= tris_before / 4 + 2);
    try testing.expect(half.faceCount() > tris_before / 8);
    // Every vertex still lies near the unit sphere.
    for (half.positions.slice()) |p| try testing.expectApproxEqAbs(@as(f32, 1), math.vec.length(p), 0.08);
    // Closed: every edge joins two triangles.
    var uses: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer uses.deinit(gpa);
    const off = half.face_offsets.slice();
    const cv = half.corner_verts.slice();
    for (0..half.faceCount()) |f| for (0..3) |k| {
        const gop = try uses.getOrPut(gpa, key(cv[off[f] + k], cv[off[f] + (k + 1) % 3]));
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    };
    var it = uses.valueIterator();
    while (it.next()) |n| try testing.expectEqual(@as(u32, 2), n.*);
}
