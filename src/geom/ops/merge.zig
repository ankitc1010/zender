//! Merge vertices: all into one at their centre, each connected group into
//! its centre (collapse), or those within a distance of each other (merge
//! by distance). Faces are rebuilt over the surviving vertices; faces that
//! collapse below three distinct corners are removed.

const std = @import("std");
const math = @import("math");
const em_mod = @import("../editmesh.zig");
const ops = @import("../ops.zig");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const v = math.vec;
const EditMesh = em_mod.EditMesh;
const none = em_mod.none;
const Xform = ops.Xform;
const Outcome = ops.Outcome;
const Error = ops.Error;

pub const Mode = enum { center, collapse, distance };

pub const Params = struct {
    mode: Mode = .center,
    /// For `distance`: world-space merge distance (Blender's default).
    threshold: f32 = 0.0001,
};

/// Merges among `verts` (ascending, live). The surviving input vertices
/// are selected afterwards.
pub fn merge(em: *EditMesh, gpa: Allocator, verts: []const u32, xf: Xform, p: Params) Error!Outcome {
    var out: Outcome = .{ .domain = .vert };
    errdefer out.deinit(gpa);
    // Merged-away vertex → the vertex it joins.
    var target: std.AutoArrayHashMapUnmanaged(u32, u32) = .empty;
    defer target.deinit(gpa);

    switch (p.mode) {
        .center => if (verts.len > 1) try collapseGroup(em, gpa, verts, &target),
        .collapse => {
            // Union-find over edges whose both ends are selected; the
            // smallest index of each group is its root.
            var slot: std.AutoHashMapUnmanaged(u32, u32) = .empty;
            defer slot.deinit(gpa);
            for (verts, 0..) |x, i| try slot.put(gpa, x, @intCast(i));
            const parent = try gpa.alloc(u32, verts.len);
            defer gpa.free(parent);
            for (parent, 0..) |*q, i| q.* = @intCast(i);
            for (verts, 0..) |x, i| {
                const first = em.verts.items[x].e;
                if (first == none) continue;
                var e = first;
                while (true) {
                    if (slot.get(em.edgeOther(e, x))) |j| unite(parent, @intCast(i), j);
                    e = em.diskNext(e, x);
                    if (e == first) break;
                }
            }
            var group: std.ArrayList(u32) = .empty;
            defer group.deinit(gpa);
            for (0..verts.len) |i| {
                if (find(parent, @intCast(i)) != i) continue;
                group.clearRetainingCapacity();
                for (verts, 0..) |x, j| if (find(parent, @intCast(j)) == i) try group.append(gpa, x);
                if (group.items.len > 1) try collapseGroup(em, gpa, group.items, &target);
            }
        },
        .distance => try byDistance(em, gpa, verts, xf, @max(p.threshold, 0), &target),
    }

    out.merged_verts = target.count();
    out.degenerate_faces = try weld(em, gpa, &target);
    for (verts) |x| if (!target.contains(x)) try out.selected.append(gpa, x);
    return out;
}

fn find(parent: []u32, i: u32) u32 {
    var r = i;
    while (parent[r] != r) r = parent[r];
    var x = i;
    while (parent[x] != r) {
        const n = parent[x];
        parent[x] = r;
        x = n;
    }
    return r;
}

fn unite(parent: []u32, a: u32, b: u32) void {
    const ra = find(parent, a);
    const rb = find(parent, b);
    if (ra < rb) parent[rb] = ra else if (rb < ra) parent[ra] = rb;
}

/// Merges `group` into its first vertex, placed at the group's centre
/// with its layer data the mean of theirs.
fn collapseGroup(em: *EditMesh, gpa: Allocator, group: []const u32, target: *std.AutoArrayHashMapUnmanaged(u32, u32)) Allocator.Error!void {
    var acc: [3]f64 = .{ 0, 0, 0 };
    for (group) |x| for (0..3) |k| {
        acc[k] += em.verts.items[x].co[k];
    };
    const n: f64 = @floatFromInt(group.len);
    const keep = group[0];
    em.verts.items[keep].co = .{ @floatCast(acc[0] / n), @floatCast(acc[1] / n), @floatCast(acc[2] / n) };
    const w = try gpa.alloc(f32, group.len);
    defer gpa.free(w);
    @memset(w, @floatCast(1 / n));
    em.interpData(.point, keep, group, w);
    for (group[1..]) |x| try target.put(gpa, x, keep);
}

/// Each vertex, in index order, absorbs the not-yet-merged vertices within
/// `threshold` of it (world space), as Blender's Merge by Distance does.
fn byDistance(em: *EditMesh, gpa: Allocator, verts: []const u32, xf: Xform, threshold: f32, target: *std.AutoArrayHashMapUnmanaged(u32, u32)) Allocator.Error!void {
    const Cell = [3]i64;
    const cell_size: f64 = @max(threshold, 1e-6);
    const world = try gpa.alloc(Vec3, verts.len);
    defer gpa.free(world);
    const cells = try gpa.alloc(Cell, verts.len);
    defer gpa.free(cells);
    for (verts, 0..) |x, i| {
        world[i] = xf.toWorld(em.verts.items[x].co);
        for (0..3) |k| cells[i][k] = @intFromFloat(std.math.clamp(@floor(world[i][k] / cell_size), -9e15, 9e15));
    }
    // Slots sorted by cell, then a map from each cell to its run.
    const order = try gpa.alloc(u32, verts.len);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const ByCell = struct {
        cells: []const Cell,
        fn lt(c: @This(), a: u32, b: u32) bool {
            const x = c.cells[a];
            const y = c.cells[b];
            for (0..3) |k| if (x[k] != y[k]) return x[k] < y[k];
            return a < b;
        }
    };
    std.mem.sort(u32, order, ByCell{ .cells = cells }, ByCell.lt);
    var runs: std.AutoHashMapUnmanaged(Cell, [2]u32) = .empty;
    defer runs.deinit(gpa);
    try runs.ensureTotalCapacity(gpa, @intCast(verts.len));
    var start: usize = 0;
    while (start < order.len) {
        var end = start + 1;
        while (end < order.len and std.mem.eql(i64, &cells[order[end]], &cells[order[start]])) end += 1;
        runs.putAssumeCapacity(cells[order[start]], .{ @intCast(start), @intCast(end) });
        start = end;
    }

    const taken = try gpa.alloc(bool, verts.len);
    defer gpa.free(taken);
    @memset(taken, false);
    const t2 = threshold * threshold;
    for (verts, 0..) |x, i| {
        if (taken[i]) continue;
        taken[i] = true;
        for ([_]i64{ -1, 0, 1 }) |dx| for ([_]i64{ -1, 0, 1 }) |dy| for ([_]i64{ -1, 0, 1 }) |dz| {
            const run = runs.get(.{ cells[i][0] + dx, cells[i][1] + dy, cells[i][2] + dz }) orelse continue;
            for (order[run[0]..run[1]]) |j| {
                if (taken[j]) continue;
                const off = v.sub(world[j], world[i]);
                if (v.dot(off, off) <= t2) {
                    taken[j] = true;
                    try target.put(gpa, verts[j], x);
                }
            }
        };
    }
}

/// Rebuilds the faces and loose edges at merged-away vertices over their
/// targets, then removes those vertices. Returns the faces dropped for
/// having fewer than three distinct corners.
fn weld(em: *EditMesh, gpa: Allocator, target: *const std.AutoArrayHashMapUnmanaged(u32, u32)) Error!usize {
    if (target.count() == 0) return 0;
    const mapOf = struct {
        fn f(t: *const std.AutoArrayHashMapUnmanaged(u32, u32), x: u32) u32 {
            return t.get(x) orelse x;
        }
    }.f;

    var touched: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
    defer touched.deinit(gpa);
    for (target.keys()) |x| {
        const first = em.verts.items[x].e;
        if (first == none) continue;
        var e = first;
        while (true) {
            const lf = em.edges.items[e].l;
            if (lf != none) {
                var l = lf;
                while (true) {
                    try touched.put(gpa, em.loops.items[l].f, {});
                    l = em.loops.items[l].radial_next;
                    if (l == lf) break;
                }
            }
            e = em.diskNext(e, x);
            if (e == first) break;
        }
    }
    const faces = touched.keys();
    std.mem.sort(u32, faces, {}, std.sort.asc(u32));

    const Corner = struct { v: u32, l: u32, e: u32 };
    var corners: std.ArrayList(Corner) = .empty;
    defer corners.deinit(gpa);
    // Per face: its corner span in `corners`, or none for a dropped face.
    var spans: std.ArrayList([2]u32) = .empty;
    defer spans.deinit(gpa);
    var degenerate: usize = 0;
    for (faces) |f| {
        const start: u32 = @intCast(corners.items.len);
        const face = em.faces.items[f];
        var l = face.l;
        for (0..face.len) |_| {
            const loop = em.loops.items[l];
            const m = mapOf(target, loop.v);
            if (corners.items.len > start and corners.items[corners.items.len - 1].v == m) {
                // A run of corners on one vertex leaves by its last edge.
                corners.items[corners.items.len - 1].e = loop.e;
            } else {
                try corners.append(gpa, .{ .v = m, .l = l, .e = loop.e });
            }
            l = loop.next;
        }
        var run = corners.items[start..];
        if (run.len > 1 and run[0].v == run[run.len - 1].v) {
            corners.items.len -= 1;
            run = corners.items[start..];
        }
        var ok = run.len >= 3;
        for (run, 0..) |a, i| for (run[i + 1 ..]) |b| if (a.v == b.v) {
            ok = false;
        };
        if (ok) {
            try spans.append(gpa, .{ start, @intCast(corners.items.len) });
        } else {
            corners.items.len = start;
            try spans.append(gpa, .{ none, none });
            degenerate += 1;
        }
    }

    for (faces) |f| em.removeFace(f);
    var vs: std.ArrayList(u32) = .empty;
    defer vs.deinit(gpa);
    var ls: std.ArrayList(u32) = .empty;
    defer ls.deinit(gpa);
    var es: std.ArrayList(u32) = .empty;
    defer es.deinit(gpa);
    for (faces, spans.items) |f, span| {
        if (span[0] == none) continue;
        vs.clearRetainingCapacity();
        ls.clearRetainingCapacity();
        es.clearRetainingCapacity();
        for (corners.items[span[0]..span[1]]) |c| {
            try vs.append(gpa, c.v);
            try ls.append(gpa, c.l);
            try es.append(gpa, c.e);
        }
        _ = try em.addFace(vs.items, .{ .face = f, .loops = ls.items, .edges = es.items });
    }

    // Loose edges follow their ends.
    for (target.keys()) |x| {
        const first = em.verts.items[x].e;
        if (first == none) continue;
        var e = first;
        while (true) {
            if (em.edges.items[e].l == none) {
                const a = mapOf(target, x);
                const b = mapOf(target, em.edgeOther(e, x));
                if (a != b) _ = try em.ensureEdge(a, b, e);
            }
            e = em.diskNext(e, x);
            if (e == first) break;
        }
    }
    for (target.keys()) |x| em.removeVert(x);
    return degenerate;
}

const testing = std.testing;
const prims = @import("../primitives.zig");
const build = @import("../build.zig");

test "merging a cube's top face to its centre makes a pyramid top" {
    const gpa = testing.allocator;
    var cube = try prims.generate(gpa, .cube, .{});
    defer cube.releaseRefs(gpa);
    var em = try EditMesh.fromMesh(gpa, &cube);
    defer em.deinit();
    var top: std.ArrayList(u32) = .empty;
    defer top.deinit(gpa);
    for (em.verts.items, 0..) |x, i| if (x.co[2] > 0) try top.append(gpa, @intCast(i));
    var out = try merge(&em, gpa, top.items, .identity, .{});
    defer out.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), out.merged_verts);
    try testing.expectEqual(@as(usize, 1), out.degenerate_faces);
    try testing.expect(em.check() == null);
    var m = try em.toMesh(gpa, null);
    defer m.releaseRefs(gpa);
    try testing.expect(build.validate(&m) == null);
    // Bottom quad + 4 side triangles, 5 vertices, 8 edges.
    try testing.expectEqual(@as(usize, 5), m.faceCount());
    try testing.expectEqual(@as(usize, 5), m.vertCount());
    try testing.expectEqual(@as(usize, 8), m.edgeCount());
    try testing.expectEqual([3]f32{ 0, 0, 1 }, em.verts.items[out.selected.items[0]].co);
}

test "merge by distance welds split seams; collapse works per group" {
    const gpa = testing.allocator;
    // Two quads side by side that do not share their middle vertices.
    var m = try build.fromPolygons(gpa, .{
        .positions = &.{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 0, 1, 0 }, .{ 1, 0, 0 }, .{ 2, 0, 0 }, .{ 2, 1, 0 }, .{ 1.00001, 1, 0 } },
        .face_offsets = &.{ 0, 4, 8 },
        .corner_verts = &.{ 0, 1, 2, 3, 4, 5, 6, 7 },
    });
    defer m.releaseRefs(gpa);
    var em = try EditMesh.fromMesh(gpa, &m);
    defer em.deinit();
    var out = try merge(&em, gpa, &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, .identity, .{ .mode = .distance, .threshold = 0.001 });
    defer out.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), out.merged_verts);
    try testing.expectEqual(@as(usize, 0), out.degenerate_faces);
    var welded = try em.toMesh(gpa, null);
    defer welded.releaseRefs(gpa);
    try testing.expectEqual(@as(usize, 6), welded.vertCount());
    try testing.expectEqual(@as(usize, 7), welded.edgeCount());

    // Collapse the two short edges of a 1x1 grid strip separately.
    var grid = try prims.generate(gpa, .grid, .{ .x_subdivisions = 2, .y_subdivisions = 1 });
    defer grid.releaseRefs(gpa);
    var em2 = try EditMesh.fromMesh(gpa, &grid);
    defer em2.deinit();
    // Vertices 0-3 (left column) and 2-5 (right column).
    var out2 = try merge(&em2, gpa, &.{ 0, 2, 3, 5 }, .identity, .{ .mode = .collapse });
    defer out2.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), out2.merged_verts);
    try testing.expect(em2.check() == null);
    var m2 = try em2.toMesh(gpa, null);
    defer m2.releaseRefs(gpa);
    try testing.expectEqual(@as(usize, 2), m2.faceCount());
    try testing.expectEqual(@as(usize, 4), m2.vertCount());
}
