//! Extrude and inset. Both cut a region of faces loose from the rest of
//! the mesh along its boundary and join it back with a ring of quads:
//! extrude gives the region new copies of all its vertices and moves them;
//! inset copies only the boundary vertices and pulls them inward. In
//! individual mode every face is its own region.

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

pub const Mode = enum { region, individual };

const Dup = enum { all, boundary };

/// One boundary side of the region: the old loop from `a` to `b`.
const Side = struct { f: u32, l: u32, a: u32, b: u32 };

/// The result of `split`: which old vertices got copies, and the caps.
const Split = struct {
    /// Old vertex → its copy, or none. Sized to the vertices before the split.
    vmap: []u32,
    /// (old, copy) pairs in order of creation.
    dups: std.ArrayList([2]u32) = .empty,
    caps: std.ArrayList(u32) = .empty,

    fn init(gpa: Allocator, em: *const EditMesh) Allocator.Error!Split {
        const vmap = try gpa.alloc(u32, em.verts.items.len);
        @memset(vmap, none);
        return .{ .vmap = vmap };
    }

    fn deinit(s: *Split, gpa: Allocator) void {
        gpa.free(s.vmap);
        s.dups.deinit(gpa);
        s.caps.deinit(gpa);
    }

    fn copyOf(s: *const Split, x: u32) ?u32 {
        return if (x < s.vmap.len and s.vmap[x] != none) s.vmap[x] else null;
    }

    fn map(s: *const Split, x: u32) u32 {
        return s.copyOf(x) orelse x;
    }

    fn dup(s: *Split, em: *EditMesh, gpa: Allocator, x: u32) Allocator.Error!void {
        if (s.vmap[x] != none) return;
        const y = try em.addVert(em.verts.items[x].co, x);
        s.vmap[x] = y;
        try s.dups.append(gpa, .{ x, y });
    }
};

/// The sides of `faces` not shared with another face of the region.
fn boundary(em: *const EditMesh, gpa: Allocator, faces: []const u32, in_region: []const bool, out: *std.ArrayList(Side)) Allocator.Error!void {
    for (faces) |f| {
        const face = em.faces.items[f];
        var l = face.l;
        for (0..face.len) |_| {
            const loop = em.loops.items[l];
            var n: u32 = 0;
            var r = l;
            while (true) {
                const g = em.loops.items[r].f;
                if (g < in_region.len and in_region[g]) n += 1;
                r = em.loops.items[r].radial_next;
                if (r == l) break;
            }
            if (n == 1) try out.append(gpa, .{ .f = f, .l = l, .a = loop.v, .b = em.loops.items[loop.next].v });
            l = loop.next;
        }
    }
}

/// Replaces `faces` by caps over remapped vertices (copied as `dup` says)
/// and joins each boundary side to its copy with a quad. Old edges and
/// vertices the region no longer uses are removed.
fn split(em: *EditMesh, gpa: Allocator, faces: []const u32, sides: []const Side, dup: Dup, out: *Split) Error!void {
    // Copies, created in face and corner order so results are reproducible.
    switch (dup) {
        .all => for (faces) |f| {
            const face = em.faces.items[f];
            var l = face.l;
            for (0..face.len) |_| {
                try out.dup(em, gpa, em.loops.items[l].v);
                l = em.loops.items[l].next;
            }
        },
        .boundary => for (sides) |s| {
            try out.dup(em, gpa, s.a);
            try out.dup(em, gpa, s.b);
        },
    }

    // Old corners, for the caps' layer data and the cleanup afterwards.
    var loops: std.ArrayList(u32) = .empty;
    defer loops.deinit(gpa);
    var edges: std.ArrayList(u32) = .empty;
    defer edges.deinit(gpa);
    var spans: std.ArrayList([2]u32) = .empty;
    defer spans.deinit(gpa);
    var old_verts: std.ArrayList(u32) = .empty;
    defer old_verts.deinit(gpa);
    var old_edges: std.ArrayList(u32) = .empty;
    defer old_edges.deinit(gpa);
    var seen_v = try std.DynamicBitSetUnmanaged.initEmpty(gpa, em.verts.items.len);
    defer seen_v.deinit(gpa);
    var seen_e = try std.DynamicBitSetUnmanaged.initEmpty(gpa, em.edges.items.len);
    defer seen_e.deinit(gpa);
    for (faces) |f| {
        const face = em.faces.items[f];
        const start: u32 = @intCast(loops.items.len);
        var l = face.l;
        for (0..face.len) |_| {
            const loop = em.loops.items[l];
            try loops.append(gpa, l);
            try edges.append(gpa, loop.e);
            if (!seen_v.isSet(loop.v)) {
                seen_v.set(loop.v);
                try old_verts.append(gpa, loop.v);
            }
            if (!seen_e.isSet(loop.e)) {
                seen_e.set(loop.e);
                try old_edges.append(gpa, loop.e);
            }
            l = loop.next;
        }
        try spans.append(gpa, .{ start, @intCast(loops.items.len) });
    }

    for (faces) |f| em.removeFace(f);

    var verts: std.ArrayList(u32) = .empty;
    defer verts.deinit(gpa);
    for (faces, spans.items) |f, span| {
        try em.tick();
        verts.clearRetainingCapacity();
        for (loops.items[span[0]..span[1]]) |l| try verts.append(gpa, out.map(em.loops.items[l].v));
        try out.caps.append(gpa, try em.addFace(verts.items, .{
            .face = f,
            .loops = loops.items[span[0]..span[1]],
            .edges = edges.items[span[0]..span[1]],
        }));
    }
    for (sides) |s| try wall(em, s.f, s.l, s.a, s.b, out.map(s.a), out.map(s.b));

    for (old_edges.items) |e| if (!em.edges.items[e].removed and em.edges.items[e].l == none) em.removeEdge(e);
    for (old_verts.items) |x| if (!em.verts.items[x].removed and em.verts.items[x].e == none) em.removeVert(x);
}

/// The quad joining old side a → b (loop `l` of face `f`) to its copy
/// a2 → b2, wound so it agrees with both the cap and the old neighbour.
fn wall(em: *EditMesh, f: u32, l: u32, a: u32, b: u32, a2: u32, b2: u32) Error!void {
    const ln = em.loops.items[l].next;
    const e = em.loops.items[l].e;
    _ = try em.addFace(&.{ a, b, b2, a2 }, .{
        .face = f,
        .loops = &.{ l, ln, ln, l },
        .edges = &.{ e, none, e, none },
    });
}

/// How individual mode places a face's copied corners.
const Place = union(enum) {
    /// Extrude: by this world offset, or by `distance` along the face normal.
    extrude: struct { offset: ?Vec3, distance: f32 },
    inset: InsetParams,
};

/// Individual mode: each face gets its own copies of its corners, a cap
/// over them and a wall on every side. Nothing is shared between faces,
/// so there are no lookups and nothing to clean up. The result equals
/// running the region code on one face at a time.
fn individual(em: *EditMesh, gpa: Allocator, faces: []const u32, xf: Xform, place: Place, out: *Outcome) Error!void {
    var vs: std.ArrayList(u32) = .empty;
    defer vs.deinit(gpa);
    var ls: std.ArrayList(u32) = .empty;
    defer ls.deinit(gpa);
    var es: std.ArrayList(u32) = .empty;
    defer es.deinit(gpa);
    var pos: std.ArrayList(Vec3) = .empty;
    defer pos.deinit(gpa);
    var inw: std.ArrayList(Vec3) = .empty;
    defer inw.deinit(gpa);
    var copies: std.ArrayList(u32) = .empty;
    defer copies.deinit(gpa);
    // Per face of n corners: n copies, n + n edges, 5n corners, n + 1 faces.
    var corners: usize = 0;
    for (faces) |f| corners += em.faces.items[f].len;
    try em.reserve(corners, 2 * corners, 5 * corners, corners + faces.len);
    try out.selected.ensureUnusedCapacity(gpa, faces.len);
    for (faces) |f| {
        try em.tick();
        vs.clearRetainingCapacity();
        ls.clearRetainingCapacity();
        es.clearRetainingCapacity();
        pos.clearRetainingCapacity();
        inw.clearRetainingCapacity();
        copies.clearRetainingCapacity();
        const face = em.faces.items[f];
        var l = face.l;
        for (0..face.len) |_| {
            const loop = em.loops.items[l];
            try vs.append(gpa, loop.v);
            try ls.append(gpa, l);
            try es.append(gpa, loop.e);
            l = loop.next;
        }
        const n = vs.items.len;
        const nf = xf.normalToWorld(em.faceNormal(f));
        switch (place) {
            .extrude => |x| {
                const offset_w = x.offset orelse blk: {
                    if (v.length(nf) < 1e-6) return error.NoNormal;
                    break :blk v.scale(v.normalize(nf), x.distance);
                };
                const d = xf.dirToLocal(offset_w);
                for (vs.items) |a| try pos.append(gpa, v.add(em.verts.items[a].co, d));
            },
            .inset => |p| {
                for (0..n) |k| {
                    const a = xf.toWorld(em.verts.items[vs.items[k]].co);
                    const b = xf.toWorld(em.verts.items[vs.items[(k + 1) % n]].co);
                    try inw.append(gpa, v.normalize(v.cross(nf, v.sub(b, a))));
                }
                const nrm = v.normalize(nf);
                for (0..n) |k| {
                    const before = inw.items[(k + n - 1) % n];
                    const after = inw.items[k];
                    const dir = v.add(before, after);
                    const nd = v.normalize(dir);
                    const cos = @min(@min(@as(f32, 1), v.dot(nd, before)), v.dot(nd, after));
                    var w = xf.toWorld(em.verts.items[vs.items[k]].co);
                    if (v.length(dir) > 1e-9) w = v.add(w, v.scale(nd, p.thickness / @max(cos, 0.1)));
                    w = v.add(w, v.scale(nrm, p.depth));
                    try pos.append(gpa, xf.toLocal(w));
                }
            },
        }
        for (vs.items, pos.items) |a, q| try copies.append(gpa, try em.addVert(q, a));
        em.removeFace(f);
        try out.selected.append(gpa, try em.addFace(copies.items, .{ .face = f, .loops = ls.items, .edges = es.items }));
        for (0..n) |k| try wall(em, f, ls.items[k], vs.items[k], vs.items[(k + 1) % n], copies.items[k], copies.items[(k + 1) % n]);
    }
}

pub const ExtrudeParams = struct {
    /// World-space offset; null moves along the normal by `distance`.
    offset: ?Vec3 = null,
    distance: f32 = 0,
    mode: Mode = .region,
};

/// Extrudes faces (Blender's Extrude Region, or Extrude Individual Faces).
/// Selected afterwards: the moved caps.
pub fn extrudeFaces(em: *EditMesh, gpa: Allocator, faces: []const u32, xf: Xform, p: ExtrudeParams) Error!Outcome {
    var out: Outcome = .{ .domain = .face };
    errdefer out.deinit(gpa);
    if (p.mode == .individual) {
        try individual(em, gpa, faces, xf, .{ .extrude = .{ .offset = p.offset, .distance = p.distance } }, &out);
        return out;
    }
    const offset_w = p.offset orelse blk: {
        var n: Vec3 = .{ 0, 0, 0 };
        for (faces) |f| n = v.add(n, xf.normalToWorld(em.faceNormal(f)));
        if (v.length(n) < 1e-6) return error.NoNormal;
        break :blk v.scale(v.normalize(n), p.distance);
    };
    const d = xf.dirToLocal(offset_w);

    const in_region = try regionMask(em, gpa, faces);
    defer gpa.free(in_region);
    var sides: std.ArrayList(Side) = .empty;
    defer sides.deinit(gpa);
    try boundary(em, gpa, faces, in_region, &sides);
    var s = try Split.init(gpa, em);
    defer s.deinit(gpa);
    try reserveRegion(em, faces, sides.items.len);
    try split(em, gpa, faces, sides.items, .all, &s);
    for (s.dups.items) |pair| em.verts.items[pair[1]].co = v.add(em.verts.items[pair[1]].co, d);
    try out.selected.appendSlice(gpa, s.caps.items);
    return out;
}

/// At most: a copy per corner, the caps' edges plus two per side, the caps'
/// corners plus four per side, and a face per cap and per side.
fn reserveRegion(em: *EditMesh, faces: []const u32, sides: usize) Allocator.Error!void {
    var corners: usize = 0;
    for (faces) |f| corners += em.faces.items[f].len;
    try em.reserve(corners, corners + 2 * sides, corners + 4 * sides, faces.len + sides);
}

fn regionMask(em: *const EditMesh, gpa: Allocator, faces: []const u32) Allocator.Error![]bool {
    const in_region = try gpa.alloc(bool, em.faces.items.len);
    @memset(in_region, false);
    for (faces) |f| in_region[f] = true;
    return in_region;
}

/// Extrudes edges into quads; the new edges are selected afterwards.
/// Along the normal means along the mean normal of the faces at the edges.
pub fn extrudeEdges(em: *EditMesh, gpa: Allocator, edges: []const u32, xf: Xform, p: ExtrudeParams) Error!Outcome {
    var out: Outcome = .{ .domain = .edge };
    errdefer out.deinit(gpa);
    const offset_w = p.offset orelse blk: {
        var n: Vec3 = .{ 0, 0, 0 };
        for (edges) |e| {
            const first = em.edges.items[e].l;
            if (first == none) continue;
            var l = first;
            while (true) {
                n = v.add(n, xf.normalToWorld(em.faceNormal(em.loops.items[l].f)));
                l = em.loops.items[l].radial_next;
                if (l == first) break;
            }
        }
        if (v.length(n) < 1e-6) return error.NoNormal;
        break :blk v.scale(v.normalize(n), p.distance);
    };
    const d = xf.dirToLocal(offset_w);

    var dups: std.AutoArrayHashMapUnmanaged(u32, u32) = .empty;
    defer dups.deinit(gpa);
    for (edges) |e| for (em.edges.items[e].v) |x| {
        if (!dups.contains(x)) try dups.put(gpa, x, try em.addVert(v.add(em.verts.items[x].co, d), x));
    };
    for (edges) |e| {
        try em.tick();
        const ends = em.edges.items[e].v;
        const l = em.edges.items[e].l;
        // Wind the new quad against the edge's first face so the two join
        // with consistent normals.
        var a = ends[0];
        var b = ends[1];
        var ex: EditMesh.Examples = .{};
        var ex_loops: [4]u32 = undefined;
        if (l != none) {
            const loop = em.loops.items[l];
            a = em.loops.items[loop.next].v;
            b = loop.v;
            ex_loops = .{ loop.next, l, l, loop.next };
            ex = .{ .face = loop.f, .loops = &ex_loops };
        }
        const a2 = dups.get(a).?;
        const b2 = dups.get(b).?;
        const ex_edges = [4]u32{ e, none, e, none };
        ex.edges = &ex_edges;
        _ = try em.addFace(&.{ a, b, b2, a2 }, ex);
        try out.selected.append(gpa, em.findEdge(a2, b2).?);
    }
    return out;
}

/// Extrudes vertices into new edges; the new vertices are selected afterwards.
pub fn extrudeVerts(em: *EditMesh, gpa: Allocator, verts: []const u32, xf: Xform, p: ExtrudeParams) Error!Outcome {
    var out: Outcome = .{ .domain = .vert };
    errdefer out.deinit(gpa);
    for (verts) |x| {
        try em.tick();
        const offset_w = p.offset orelse blk: {
            const n = vertNormal(em, x, xf);
            if (v.length(n) < 0.5) return error.NoNormal;
            break :blk v.scale(n, p.distance);
        };
        const y = try em.addVert(v.add(em.verts.items[x].co, xf.dirToLocal(offset_w)), x);
        _ = try em.addEdge(x, y, null);
        try out.selected.append(gpa, y);
    }
    return out;
}

/// Unit world normal at a vertex: the mean of its faces' normals.
fn vertNormal(em: *const EditMesh, x: u32, xf: Xform) Vec3 {
    var n: Vec3 = .{ 0, 0, 0 };
    const first = em.verts.items[x].e;
    if (first == none) return n;
    var e = first;
    while (true) {
        const lf = em.edges.items[e].l;
        if (lf != none) {
            var l = lf;
            while (true) {
                // Count each face once: at the loop that starts at x.
                if (em.loops.items[l].v == x) n = v.add(n, xf.normalToWorld(em.faceNormal(em.loops.items[l].f)));
                l = em.loops.items[l].radial_next;
                if (l == lf) break;
            }
        }
        e = em.diskNext(e, x);
        if (e == first) break;
    }
    return v.normalize(n);
}

pub const InsetParams = struct {
    /// Distance the inner boundary moves in from the outer one (world m).
    thickness: f32 = 0.1,
    /// Distance the inset faces move along their normals (world m).
    depth: f32 = 0,
    mode: Mode = .region,
};

/// Insets faces (Blender's Inset Faces with even thickness); the inner
/// faces are selected afterwards.
pub fn inset(em: *EditMesh, gpa: Allocator, faces: []const u32, xf: Xform, p: InsetParams) Error!Outcome {
    var out: Outcome = .{ .domain = .face };
    errdefer out.deinit(gpa);
    if (p.mode == .individual) {
        try individual(em, gpa, faces, xf, .{ .inset = p }, &out);
        return out;
    }
    const in_region = try regionMask(em, gpa, faces);
    defer gpa.free(in_region);
    var sides: std.ArrayList(Side) = .empty;
    defer sides.deinit(gpa);
    try boundary(em, gpa, faces, in_region, &sides);

    // Per region vertex, in order of first use: the region normal, and the
    // inward directions of the boundary sides meeting there (world space).
    const Acc = struct { vert: u32, dir: Vec3 = .{ 0, 0, 0 }, cos: f32 = 1, normal: Vec3 = .{ 0, 0, 0 } };
    var acc: std.ArrayList(Acc) = .empty;
    defer acc.deinit(gpa);
    const slot = try gpa.alloc(u32, em.verts.items.len);
    defer gpa.free(slot);
    @memset(slot, none);
    for (faces) |f| {
        try em.tick();
        const n = xf.normalToWorld(em.faceNormal(f));
        const face = em.faces.items[f];
        var l = face.l;
        for (0..face.len) |_| {
            const x = em.loops.items[l].v;
            if (slot[x] == none) {
                slot[x] = @intCast(acc.items.len);
                try acc.append(gpa, .{ .vert = x });
            }
            const a = &acc.items[slot[x]];
            a.normal = v.add(a.normal, n);
            l = em.loops.items[l].next;
        }
    }
    for (sides.items) |s| {
        const in_dir = inward(em, s, xf);
        for ([_]u32{ s.a, s.b }) |x| {
            const a = &acc.items[slot[x]];
            a.dir = v.add(a.dir, in_dir);
        }
    }
    for (sides.items) |s| {
        const in_dir = inward(em, s, xf);
        for ([_]u32{ s.a, s.b }) |x| {
            const a = &acc.items[slot[x]];
            a.cos = @min(a.cos, v.dot(v.normalize(a.dir), in_dir));
        }
    }

    var sp = try Split.init(gpa, em);
    defer sp.deinit(gpa);
    try reserveRegion(em, faces, sides.items.len);
    try split(em, gpa, faces, sides.items, .boundary, &sp);
    for (acc.items) |a| {
        const n = v.normalize(a.normal);
        const moved = sp.copyOf(a.vert);
        if (moved == null and p.depth == 0) continue;
        var w = xf.toWorld(em.verts.items[a.vert].co);
        if (moved != null and v.length(a.dir) > 1e-9) {
            // Even thickness: stay `thickness` away from every side,
            // within reason at very sharp corners.
            w = v.add(w, v.scale(v.normalize(a.dir), p.thickness / @max(a.cos, 0.1)));
        }
        w = v.add(w, v.scale(n, p.depth));
        em.verts.items[moved orelse a.vert].co = xf.toLocal(w);
    }
    try out.selected.appendSlice(gpa, sp.caps.items);
    return out;
}

/// Unit world direction, in the plane of the side's face, pointing into it.
fn inward(em: *const EditMesh, s: Side, xf: Xform) Vec3 {
    const n = xf.normalToWorld(em.faceNormal(s.f));
    const a = xf.toWorld(em.verts.items[s.a].co);
    const b = xf.toWorld(em.verts.items[s.b].co);
    return v.normalize(v.cross(n, v.sub(b, a)));
}

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

fn topFace(em: *const EditMesh) u32 {
    for (em.faces.items, 0..) |f, i| if (!f.removed and em.faceNormal(@intCast(i))[2] > 0.99) return @intCast(i);
    unreachable;
}

/// Edges whose two faces run the same way along them (inconsistent winding).
fn windingConflicts(m: *const Mesh) usize {
    var em = EditMesh.fromMesh(testing.allocator, m) catch unreachable;
    defer em.deinit();
    var n: usize = 0;
    for (em.edges.items) |e| {
        if (e.l == none) continue;
        const r = em.loops.items[e.l].radial_next;
        if (r != e.l and em.loops.items[r].radial_next == e.l and em.loops.items[r].v == em.loops.items[e.l].v) n += 1;
    }
    return n;
}

test "extruding the top face of a cube" {
    const gpa = testing.allocator;
    var cube = try prims.generate(gpa, .cube, .{});
    defer cube.releaseRefs(gpa);
    var em = try EditMesh.fromMesh(gpa, &cube);
    defer em.deinit();
    var out = try extrudeFaces(&em, gpa, &.{topFace(&em)}, .identity, .{ .distance = 0.5 });
    defer out.deinit(gpa);
    var m = try finish(&em);
    defer m.releaseRefs(gpa);
    try testing.expectEqual(@as(usize, 12), m.vertCount());
    try testing.expectEqual(@as(usize, 20), m.edgeCount());
    try testing.expectEqual(@as(usize, 10), m.faceCount());
    try testing.expectEqual(@as(usize, 0), windingConflicts(&m));
    const cap = em.faces.items[out.selected.items[0]];
    try testing.expectEqual(@as(f32, 1.5), em.verts.items[em.loops.items[cap.l].v].co[2]);
}

test "extruding a whole open grid region keeps one cap" {
    const gpa = testing.allocator;
    var grid = try prims.generate(gpa, .grid, .{ .x_subdivisions = 3, .y_subdivisions = 3 });
    defer grid.releaseRefs(gpa);
    var em = try EditMesh.fromMesh(gpa, &grid);
    defer em.deinit();
    var all: [9]u32 = undefined;
    for (&all, 0..) |*f, i| f.* = @intCast(i);
    var out = try extrudeFaces(&em, gpa, &all, .identity, .{ .offset = .{ 0, 0, 1 } });
    defer out.deinit(gpa);
    var m = try finish(&em);
    defer m.releaseRefs(gpa);
    // 9 caps + 12 boundary walls; the 4 interior grid vertices move with
    // the cap, so only the 12 boundary vertices remain below.
    try testing.expectEqual(@as(usize, 21), m.faceCount());
    try testing.expectEqual(@as(usize, 16 + 12), m.vertCount());
    try testing.expectEqual(@as(usize, 0), windingConflicts(&m));

    var em2 = try EditMesh.fromMesh(gpa, &grid);
    defer em2.deinit();
    var out2 = try extrudeFaces(&em2, gpa, &all, .identity, .{ .offset = .{ 0, 0, 1 }, .mode = .individual });
    defer out2.deinit(gpa);
    var m2 = try finish(&em2);
    defer m2.releaseRefs(gpa);
    try testing.expectEqual(@as(usize, 9 * 5), m2.faceCount());
    try testing.expectEqual(@as(usize, 0), windingConflicts(&m2));
}

test "extruding edges and vertices" {
    const gpa = testing.allocator;
    var plane = try prims.generate(gpa, .plane, .{});
    defer plane.releaseRefs(gpa);
    var em = try EditMesh.fromMesh(gpa, &plane);
    defer em.deinit();
    var out = try extrudeEdges(&em, gpa, &.{0}, .identity, .{ .offset = .{ 0, 0, 1 } });
    defer out.deinit(gpa);
    var outv = try extrudeVerts(&em, gpa, &.{2}, .identity, .{ .distance = 2 });
    defer outv.deinit(gpa);
    var m = try finish(&em);
    defer m.releaseRefs(gpa);
    try testing.expectEqual(@as(usize, 2), m.faceCount());
    try testing.expectEqual(@as(usize, 7), m.vertCount());
    try testing.expectEqual(@as(usize, 0), windingConflicts(&m));
    // Vertex 2 had the plane's +Z normal.
    try testing.expectEqual(@as(f32, 2), em.verts.items[outv.selected.items[0]].co[2]);
    try testing.expectError(error.NoNormal, extrudeVerts(&em, gpa, &.{outv.selected.items[0]}, .identity, .{ .distance = 1 }));
}

test "inset keeps thickness even and region interior shared" {
    const gpa = testing.allocator;
    var cube = try prims.generate(gpa, .cube, .{});
    defer cube.releaseRefs(gpa);
    var em = try EditMesh.fromMesh(gpa, &cube);
    defer em.deinit();
    var out = try inset(&em, gpa, &.{topFace(&em)}, .identity, .{ .thickness = 0.25, .depth = -0.1 });
    defer out.deinit(gpa);
    var m = try finish(&em);
    defer m.releaseRefs(gpa);
    try testing.expectEqual(@as(usize, 10), m.faceCount());
    try testing.expectEqual(@as(usize, 0), windingConflicts(&m));
    const cap = em.faces.items[out.selected.items[0]];
    var l = cap.l;
    for (0..4) |_| {
        const p = em.verts.items[em.loops.items[l].v].co;
        try testing.expectApproxEqAbs(@as(f32, 0.75), @abs(p[0]), 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 0.75), @abs(p[1]), 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 0.9), p[2], 1e-6);
        l = em.loops.items[l].next;
    }

    // A 2x2 grid region insets as one: 4 faces + 8 rim quads, the centre
    // vertex stays shared.
    var grid = try prims.generate(gpa, .grid, .{ .x_subdivisions = 2, .y_subdivisions = 2 });
    defer grid.releaseRefs(gpa);
    var em2 = try EditMesh.fromMesh(gpa, &grid);
    defer em2.deinit();
    var out2 = try inset(&em2, gpa, &.{ 0, 1, 2, 3 }, .identity, .{ .thickness = 0.1 });
    defer out2.deinit(gpa);
    var m2 = try finish(&em2);
    defer m2.releaseRefs(gpa);
    try testing.expectEqual(@as(usize, 12), m2.faceCount());
    try testing.expectEqual(@as(usize, 9 + 8), m2.vertCount());
    try testing.expectEqual(@as(usize, 0), windingConflicts(&m2));
}

test "world-space offsets on a scaled object" {
    const gpa = testing.allocator;
    var cube = try prims.generate(gpa, .cube, .{});
    defer cube.releaseRefs(gpa);
    var em = try EditMesh.fromMesh(gpa, &cube);
    defer em.deinit();
    const xf = Xform.init(v.compose(.{ 0, 0, 0 }, v.quat_identity, .{ 1, 1, 0.5 })).?;
    var out = try extrudeFaces(&em, gpa, &.{topFace(&em)}, xf, .{ .distance = 1 });
    defer out.deinit(gpa);
    // 1 m in the world is 2 local units under a Z scale of 0.5.
    const cap = em.faces.items[out.selected.items[0]];
    try testing.expectApproxEqAbs(@as(f32, 3), em.verts.items[em.loops.items[cap.l].v].co[2], 1e-6);
}
