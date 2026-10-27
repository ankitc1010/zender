//! Loop cut (Blender's Loop Cut and Slide, without the slide). A seed edge
//! picks its ring: the edges met by walking across quads from it, each
//! quad entered by one edge and left by the opposite one. Every ring edge
//! is split into `cuts + 1` equal parts and the quads between them are cut
//! across, adding `cuts` edge loops. A ring ends at a boundary, a non-quad
//! face or a non-manifold edge; faces past its end edges keep their shape
//! and take the new vertices as extra corners.
//!
//! Seeds are taken in order and each ring is cut before the next is found,
//! so crossing rings make a grid where they meet; a seed already cut by an
//! earlier ring is skipped.

const std = @import("std");
const math = @import("math");
const em_mod = @import("../editmesh.zig");
const ops = @import("../ops.zig");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const v = math.vec;
const EditMesh = em_mod.EditMesh;
const none = em_mod.none;
const Outcome = ops.Outcome;
const Error = ops.Error;

pub const max_cuts = 256;

pub const Params = struct {
    /// Edge loops added per ring.
    cuts: u32 = 1,
};

/// A ring edge, oriented so that every `s0` lies on the same side of the ring.
const Cut = struct { e: u32, s0: u32, s1: u32 };

const Ring = struct {
    edges: std.ArrayList(Cut) = .empty,
    /// quads[k] lies between edges[k] and edges[k + 1], or edges[0] for the
    /// last quad of a cyclic ring.
    quads: std.ArrayList(u32) = .empty,

    fn deinit(r: *Ring, gpa: Allocator) void {
        r.edges.deinit(gpa);
        r.quads.deinit(gpa);
    }
};

/// Cuts the rings of `seeds` (edge indices). Selected afterwards: the new
/// edges across the cut quads.
pub fn loopCut(em: *EditMesh, gpa: Allocator, seeds: []const u32, p: Params) Error!Outcome {
    var out: Outcome = .{ .domain = .edge };
    errdefer out.deinit(gpa);
    const cuts = std.math.clamp(p.cuts, 1, max_cuts);
    var result: std.DynamicBitSetUnmanaged = .{};
    defer result.deinit(gpa);
    for (seeds) |seed| {
        if (em.edges.items[seed].removed) continue;
        var ring: Ring = .{};
        defer ring.deinit(gpa);
        try findRing(em, gpa, seed, &ring);
        if (ring.quads.items.len == 0) {
            out.skipped += 1;
            continue;
        }
        try cutRing(em, gpa, &ring, cuts, &result);
        out.rings += 1;
    }
    var it = result.iterator(.{});
    while (it.next()) |e| if (!em.edges.items[e].removed) try out.selected.append(gpa, @intCast(e));
    return out;
}

/// Walks across quads from `seed` in both directions.
fn findRing(em: *EditMesh, gpa: Allocator, seed: u32, ring: *Ring) Error!void {
    const loops = em.loops.items;
    const ends = em.edges.items[seed].v;
    const start: Cut = .{ .e = seed, .s0 = ends[0], .s1 = ends[1] };
    const l1 = em.edges.items[seed].l;
    if (l1 == none) return;
    var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer visited.deinit(gpa);

    var fwd: Ring = .{};
    defer fwd.deinit(gpa);
    const closed = try walk(em, gpa, start, l1, &fwd, &visited);
    var back: Ring = .{};
    defer back.deinit(gpa);
    const l2 = loops[l1].radial_next;
    if (!closed and l2 != l1) _ = try walk(em, gpa, start, l2, &back, &visited);

    // Backward edges and quads reversed, then the seed, then forward.
    var i = back.edges.items.len;
    while (i > 0) {
        i -= 1;
        try ring.edges.append(gpa, back.edges.items[i]);
    }
    try ring.edges.append(gpa, start);
    try ring.edges.appendSlice(gpa, fwd.edges.items);
    i = back.quads.items.len;
    while (i > 0) {
        i -= 1;
        try ring.quads.append(gpa, back.quads.items[i]);
    }
    try ring.quads.appendSlice(gpa, fwd.quads.items);
}

/// Walks from `from` into the face of loop `l`, appending quads and the
/// edges that leave them. True if the walk came back to the seed.
fn walk(em: *EditMesh, gpa: Allocator, from: Cut, first: u32, out: *Ring, visited: *std.AutoHashMapUnmanaged(u32, void)) Error!bool {
    const loops = em.loops.items;
    var cur = from;
    var l = first;
    while (true) {
        try em.tick();
        const f = loops[l].f;
        if (em.faces.items[f].len != 4 or visited.contains(f)) return false;
        // The quad runs a → b → c → d with a-b the current edge; a faces d
        // and b faces c across it.
        const a = loops[l].v;
        const lc = loops[loops[l].next].next;
        const c = loops[lc].v;
        const d = loops[loops[lc].next].v;
        const e2 = loops[lc].e;
        const next: Cut = if (cur.s0 == a) .{ .e = e2, .s0 = d, .s1 = c } else .{ .e = e2, .s0 = c, .s1 = d };
        if (e2 == from.e) {
            try out.quads.append(gpa, f);
            return true;
        }
        // Stop short of a quad whose far side is already in the ring: its
        // far edge would need splitting in two directions at once.
        const r = loops[lc].radial_next;
        if (r != lc and visited.contains(loops[r].f)) return false;
        try visited.put(gpa, f, {});
        try out.quads.append(gpa, f);
        try out.edges.append(gpa, next);
        if (r == lc or loops[r].radial_next != lc) return false;
        cur = next;
        l = r;
    }
}

/// One corner of a face being rebuilt: vertex `v`, with corner data mixed
/// from loops `a` and `b` (weights 1 - t and t).
const Corner = struct { v: u32, a: u32, b: u32, t: f32, edge: u32 };

fn cutRing(em: *EditMesh, gpa: Allocator, ring: *const Ring, cuts: u32, result: *std.DynamicBitSetUnmanaged) Error!void {
    const n_edges = ring.edges.items.len;
    // Ring edge → its slot, and the new vertices of each slot from s0 to s1.
    var slot: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer slot.deinit(gpa);
    for (ring.edges.items, 0..) |cut, k| try slot.put(gpa, cut.e, @intCast(k));
    const fresh = try gpa.alloc(u32, n_edges * cuts);
    defer gpa.free(fresh);
    try em.reserve(fresh.len, 0, 0, 0);
    for (ring.edges.items, 0..) |cut, k| {
        const a = em.verts.items[cut.s0].co;
        const b = em.verts.items[cut.s1].co;
        for (0..cuts) |j| {
            const t = frac(j + 1, cuts);
            const x = try em.addVert(v.add(a, v.scale(v.sub(b, a), t)), null);
            em.interpData(.point, x, &.{ cut.s0, cut.s1 }, &.{ 1 - t, t });
            fresh[k * cuts + j] = x;
        }
    }

    // Faces to rebuild: the ring's quads, cut across, and every other face
    // on a ring edge, with the new vertices inserted.
    var in_ring: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer in_ring.deinit(gpa);
    for (ring.quads.items) |f| try in_ring.put(gpa, f, {});
    var others: std.ArrayList(u32) = .empty;
    defer others.deinit(gpa);
    for (ring.edges.items) |cut| {
        const first = em.edges.items[cut.e].l;
        var l = first;
        while (true) {
            const f = em.loops.items[l].f;
            if (!in_ring.contains(f)) {
                try in_ring.put(gpa, f, {});
                try others.append(gpa, f);
            }
            l = em.loops.items[l].radial_next;
            if (l == first) break;
        }
    }
    std.mem.sort(u32, others.items, {}, std.sort.asc(u32));

    var corners: std.ArrayList(Corner) = .empty;
    defer corners.deinit(gpa);
    var spans: std.ArrayList([3]u32) = .empty; // start, end, example face
    defer spans.deinit(gpa);
    const ctx: Ctx = .{ .em = em, .ring = ring, .slot = &slot, .fresh = fresh, .cuts = cuts };
    for (ring.quads.items, 0..) |f, k| {
        try em.tick();
        const k2 = (k + 1) % n_edges;
        // The quad's loop on ring edge k: a → b, then c → d on edge k2.
        var la = em.faces.items[f].l;
        while (em.loops.items[la].e != ring.edges.items[k].e) la = em.loops.items[la].next;
        const lb = em.loops.items[la].next;
        const lc = em.loops.items[lb].next;
        const ld = em.loops.items[lc].next;
        for (0..cuts + 1) |i| {
            const start: u32 = @intCast(corners.items.len);
            const ii: u32 = @intCast(i);
            try corners.append(gpa, ctx.along(k, la, lb, ii, ring.edges.items[k].e));
            try corners.append(gpa, ctx.along(k, la, lb, ii + 1, if (ii == cuts) em.loops.items[lb].e else none));
            try corners.append(gpa, ctx.along(k2, ld, lc, ii + 1, ring.edges.items[k2].e));
            try corners.append(gpa, ctx.along(k2, ld, lc, ii, if (ii == 0) em.loops.items[ld].e else none));
            try spans.append(gpa, .{ start, @intCast(corners.items.len), f });
        }
    }
    for (others.items) |f| {
        try em.tick();
        const start: u32 = @intCast(corners.items.len);
        const face = em.faces.items[f];
        var l = face.l;
        for (0..face.len) |_| {
            const loop = em.loops.items[l];
            const ln = loop.next;
            try corners.append(gpa, .{ .v = loop.v, .a = l, .b = l, .t = 0, .edge = loop.e });
            if (slot.get(loop.e)) |k| for (1..cuts + 1) |i| {
                try corners.append(gpa, ctx.along(k, l, ln, @intCast(i), loop.e));
            };
            l = ln;
        }
        try spans.append(gpa, .{ start, @intCast(corners.items.len), f });
    }

    for (spans.items) |s| em.removeFace(s[2]);
    var vs: std.ArrayList(u32) = .empty;
    defer vs.deinit(gpa);
    var ex_loops: std.ArrayList(u32) = .empty;
    defer ex_loops.deinit(gpa);
    var ex_edges: std.ArrayList(u32) = .empty;
    defer ex_edges.deinit(gpa);
    for (spans.items) |s| {
        const cs = corners.items[s[0]..s[1]];
        vs.clearRetainingCapacity();
        ex_loops.clearRetainingCapacity();
        ex_edges.clearRetainingCapacity();
        for (cs) |c| {
            try vs.append(gpa, c.v);
            try ex_loops.append(gpa, if (c.t == 0) c.a else none);
            try ex_edges.append(gpa, c.edge);
        }
        const nf = try em.addFace(vs.items, .{ .face = s[2], .loops = ex_loops.items, .edges = ex_edges.items });
        const first = em.faces.items[nf].l;
        for (cs, 0..) |c, i| if (c.t != 0) em.interpData(.corner, first + @as(u32, @intCast(i)), &.{ c.a, c.b }, &.{ 1 - c.t, c.t });
    }

    try result.resize(gpa, em.edges.items.len, false);
    // The new edges across each quad.
    for (0..ring.quads.items.len) |k| {
        const k2 = (k + 1) % n_edges;
        for (0..cuts) |j| result.set(em.findEdge(ctx.point(k, j, true), ctx.point(k2, j, true)).?);
    }
    // A ring edge that an earlier ring had selected passes that on to its parts.
    for (ring.edges.items, 0..) |cut, k| {
        if (cut.e < result.bit_length and result.isSet(cut.e)) {
            var prev = cut.s0;
            for (0..cuts + 1) |j| {
                const next = if (j == cuts) cut.s1 else ctx.point(k, j, true);
                result.set(em.findEdge(prev, next).?);
                prev = next;
            }
            result.unset(cut.e);
        }
        em.removeEdge(cut.e);
    }
}

fn frac(i: usize, cuts: u32) f32 {
    return @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(cuts + 1));
}

const Ctx = struct {
    em: *const EditMesh,
    ring: *const Ring,
    slot: *const std.AutoHashMapUnmanaged(u32, u32),
    fresh: []const u32,
    cuts: u32,

    /// New vertex j (0-based) of ring slot k, counted from s0 (or from s1).
    fn point(c: Ctx, k: usize, j: usize, from_s0: bool) u32 {
        const i = if (from_s0) j else c.cuts - 1 - j;
        return c.fresh[k * c.cuts + i];
    }

    /// Corner i of the chain from loop `lx`'s vertex to loop `ly`'s along
    /// ring slot k: 0 is lx's vertex, cuts + 1 is ly's.
    fn along(c: Ctx, k: usize, lx: u32, ly: u32, i: u32, edge: u32) Corner {
        const x = c.em.loops.items[lx].v;
        if (i == 0) return .{ .v = x, .a = lx, .b = lx, .t = 0, .edge = edge };
        if (i == c.cuts + 1) return .{ .v = c.em.loops.items[ly].v, .a = ly, .b = ly, .t = 0, .edge = edge };
        const from_s0 = c.ring.edges.items[k].s0 == x;
        return .{ .v = c.point(k, i - 1, from_s0), .a = lx, .b = ly, .t = frac(i, c.cuts), .edge = edge };
    }
};

const testing = std.testing;
const prims = @import("../primitives.zig");
const build = @import("../build.zig");
const Mesh = @import("../../core/root.zig").types.Mesh;

fn finish(em: *EditMesh) !Mesh {
    try testing.expect(em.check() == null);
    const m = try em.toMesh(testing.allocator, null);
    try testing.expect(build.validate(&m) == null);
    return m;
}

fn verticalEdge(em: *const EditMesh) u32 {
    for (em.edges.items, 0..) |e, i| {
        const a = em.verts.items[e.v[0]].co;
        const b = em.verts.items[e.v[1]].co;
        if (!e.removed and a[0] == b[0] and a[1] == b[1]) return @intCast(i);
    }
    unreachable;
}

test "a loop cut around a cube" {
    const gpa = testing.allocator;
    var cube = try prims.generate(gpa, .cube, .{});
    defer cube.releaseRefs(gpa);
    var em = try EditMesh.fromMesh(gpa, &cube);
    defer em.deinit();
    var out = try loopCut(&em, gpa, &.{verticalEdge(&em)}, .{});
    defer out.deinit(gpa);
    var m = try finish(&em);
    defer m.releaseRefs(gpa);
    // The 4 side quads become 8; top and bottom are untouched.
    try testing.expectEqual(@as(usize, 1), out.rings);
    try testing.expectEqual(@as(usize, 12), m.vertCount());
    try testing.expectEqual(@as(usize, 10), m.faceCount());
    try testing.expectEqual(@as(usize, 20), m.edgeCount());
    try testing.expectEqual(@as(usize, 4), out.selected.items.len);
    for (out.selected.items) |e| for (em.edges.items[e].v) |x| try testing.expectEqual(@as(f32, 0), em.verts.items[x].co[2]);
    // UVs at the new corners are halfway between the old ones.
    try testing.expectEqual(@as(usize, 40), m.attribute(Mesh.uv_name).?.data.len());
}

test "loop cuts on an open grid, with several cuts and crossing rings" {
    const gpa = testing.allocator;
    var grid = try prims.generate(gpa, .grid, .{ .x_subdivisions = 3, .y_subdivisions = 2 });
    defer grid.releaseRefs(gpa);
    var em = try EditMesh.fromMesh(gpa, &grid);
    defer em.deinit();
    // Seeds: an edge along X (its ring runs along Y) and one along Y.
    var along_x: u32 = none;
    var along_y: u32 = none;
    for (em.edges.items, 0..) |e, i| {
        const d = v.sub(em.verts.items[e.v[1]].co, em.verts.items[e.v[0]].co);
        if (along_x == none and d[1] == 0) along_x = @intCast(i);
        if (along_y == none and d[0] == 0) along_y = @intCast(i);
    }
    var out = try loopCut(&em, gpa, &.{ along_x, along_y }, .{ .cuts = 2 });
    defer out.deinit(gpa);
    var m = try finish(&em);
    defer m.releaseRefs(gpa);
    // The first ring runs up one column of 2 quads and cuts it into three
    // columns (6 faces, 10 in all). The second runs along a row, which now
    // has 5 quads, and cuts each into three (15 faces, 20 in all).
    try testing.expectEqual(@as(usize, 2), out.rings);
    try testing.expectEqual(@as(usize, 20), m.faceCount());
    try testing.expectEqual(@as(usize, 6 * 5), m.vertCount());
}

test "a ring stops at a triangle, which gains a corner" {
    const gpa = testing.allocator;
    // Two quads in a row, then a triangle on the far edge.
    var m0 = try build.fromPolygons(gpa, .{
        .positions = &.{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 1, 1, 0 }, .{ 0, 2, 0 }, .{ 1, 2, 0 }, .{ 0.5, 3, 0 } },
        .face_offsets = &.{ 0, 4, 8, 11 },
        .corner_verts = &.{ 0, 1, 3, 2, 2, 3, 5, 4, 4, 5, 6 },
    });
    defer m0.releaseRefs(gpa);
    var em = try EditMesh.fromMesh(gpa, &m0);
    defer em.deinit();
    var out = try loopCut(&em, gpa, &.{em.findEdge(0, 1).?}, .{});
    defer out.deinit(gpa);
    var m = try finish(&em);
    defer m.releaseRefs(gpa);
    // 2 quads become 4; the triangle becomes a quad with the new corner.
    try testing.expectEqual(@as(usize, 5), m.faceCount());
    try testing.expectEqual(@as(usize, 7 + 3), m.vertCount());
    try testing.expectEqual(@as(usize, 4 * 4 + 4), m.cornerCount());
    try testing.expectEqual(@as(usize, 2), out.selected.items.len);
}

test "a seed bordering no quad is skipped" {
    const gpa = testing.allocator;
    var cone = try prims.generate(gpa, .cone, .{ .segments = 6 });
    defer cone.releaseRefs(gpa);
    var em = try EditMesh.fromMesh(gpa, &cone);
    defer em.deinit();
    // A cone's side faces are triangles.
    var out = try loopCut(&em, gpa, &.{em.loops.items[em.faces.items[0].l].e}, .{});
    defer out.deinit(gpa);
    try testing.expect(em.check() == null);
    try testing.expectEqual(@as(usize, 0), out.rings);
    try testing.expectEqual(@as(usize, 1), out.skipped);
}
