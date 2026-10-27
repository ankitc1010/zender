//! EditMesh: the boundary representation topology-changing operators work
//! on (TRD §7), in the manner of a BMesh: each vertex has a disk cycle of
//! the edges around it, each edge a radial cycle of the face corners
//! (loops) that use it, each face a cycle of loops. N-gons, non-manifold
//! edges, loose vertices and edges, and holes are all representable
//! (FR-GEO-2).
//!
//! Elements live in arrays and are addressed by index. Removing an element
//! only marks it; `toMesh` compacts, keeping survivors in their relative
//! order, so a Mesh → EditMesh → Mesh round trip without edits returns
//! identical arrays. Generic attributes ride along as layers per domain,
//! and operators copy or interpolate them for the elements they create.

const std = @import("std");
const math = @import("math");
const core = @import("../core/root.zig");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const v = math.vec;
const Mesh = core.types.Mesh;
const Domain = core.types.Domain;
const AttrData = core.types.AttrData;
const Name = core.Name;

pub const none = std.math.maxInt(u32);

pub const Error = Allocator.Error || error{ InvalidTopology, TooManyAttributes };

/// The wall-time limit of the tool call an operator runs in (SEC-3).
pub const Stop = struct {
    deadline: *math.Deadline,
    io: std.Io,
};

pub const Vert = struct {
    co: Vec3,
    /// An edge of the disk cycle around this vertex, or `none` when loose.
    e: u32 = none,
    removed: bool = false,
};

pub const Edge = struct {
    v: [2]u32,
    /// Disk-cycle neighbours at `v[0]` and at `v[1]`.
    prev: [2]u32 = .{ none, none },
    next: [2]u32 = .{ none, none },
    /// A loop of the radial cycle, or `none` for a loose edge.
    l: u32 = none,
    removed: bool = false,
};

pub const Loop = struct {
    v: u32,
    /// The edge from `v` to the next loop's vertex.
    e: u32,
    f: u32,
    next: u32,
    prev: u32,
    radial_next: u32,
    radial_prev: u32,
};

pub const Face = struct {
    /// First loop; the stored mesh's corner order starts here.
    l: u32,
    len: u32,
    removed: bool = false,
};

pub const LayerData = union(enum) {
    float: std.ArrayList(f32),
    float2: std.ArrayList([2]f32),
    float3: std.ArrayList([3]f32),
    color: std.ArrayList([4]f32),
    int: std.ArrayList(i32),
    boolean: std.ArrayList(bool),
};

pub const Layer = struct {
    name: Name,
    domain: Domain,
    data: LayerData,
};

/// Old index → new index (or `none` for removed elements), per domain.
pub const Maps = struct {
    verts: []u32,
    edges: []u32,
    faces: []u32,

    pub fn deinit(m: *Maps, gpa: Allocator) void {
        gpa.free(m.verts);
        gpa.free(m.edges);
        gpa.free(m.faces);
    }
};

pub const EditMesh = struct {
    gpa: Allocator,
    verts: std.ArrayList(Vert) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    loops: std.ArrayList(Loop) = .empty,
    faces: std.ArrayList(Face) = .empty,
    /// In the stored mesh's attribute order.
    layers: std.ArrayList(Layer) = .empty,
    /// Set by the caller; operators then stop part-way with
    /// error.DeadlineExceeded once it passes, leaving the EditMesh unusable.
    stop: ?Stop = null,
    ticks: u32 = 0,

    pub fn init(gpa: Allocator) EditMesh {
        return .{ .gpa = gpa };
    }

    pub fn deinit(em: *EditMesh) void {
        const gpa = em.gpa;
        em.verts.deinit(gpa);
        em.edges.deinit(gpa);
        em.loops.deinit(gpa);
        em.faces.deinit(gpa);
        for (em.layers.items) |*l| switch (l.data) {
            inline else => |*d| d.deinit(gpa),
        };
        em.layers.deinit(gpa);
        em.* = undefined;
    }

    /// Builds an EditMesh in O(n). Element indices equal the mesh's: vertex
    /// i is point i, edge i is edge i, face i is face i, loop c is corner c.
    pub fn fromMesh(gpa: Allocator, m: *const Mesh) Error!EditMesh {
        var em: EditMesh = .init(gpa);
        errdefer em.deinit();
        const pos = m.positions.slice();
        const edges = m.edges.slice();
        const off = m.face_offsets.slice();
        const cv = m.corner_verts.slice();
        const ce = m.corner_edges.slice();
        if (ce.len != cv.len) return error.InvalidTopology;

        try em.verts.ensureTotalCapacity(gpa, pos.len);
        for (pos) |p| em.verts.appendAssumeCapacity(.{ .co = p });

        try em.edges.ensureTotalCapacity(gpa, edges.len);
        for (edges, 0..) |e, i| {
            if (e[0] >= pos.len or e[1] >= pos.len or e[0] == e[1]) return error.InvalidTopology;
            em.edges.appendAssumeCapacity(.{ .v = e });
            em.diskInsert(@intCast(i), e[0]);
            em.diskInsert(@intCast(i), e[1]);
        }

        const n_faces = m.faceCount();
        try em.faces.ensureTotalCapacity(gpa, n_faces);
        try em.loops.ensureTotalCapacity(gpa, cv.len);
        for (0..n_faces) |f| {
            const start = off[f];
            const end = off[f + 1];
            if (end < start + 3 or end > cv.len) return error.InvalidTopology;
            em.faces.appendAssumeCapacity(.{ .l = start, .len = end - start });
            for (start..end) |c| {
                const nxt: u32 = if (c + 1 == end) start else @intCast(c + 1);
                const prv: u32 = if (c == start) end - 1 else @intCast(c - 1);
                const e = ce[c];
                if (cv[c] >= pos.len or e >= edges.len) return error.InvalidTopology;
                if (!edgeJoins(edges[e], cv[c], cv[nxt])) return error.InvalidTopology;
                em.loops.appendAssumeCapacity(.{ .v = cv[c], .e = e, .f = @intCast(f), .next = nxt, .prev = prv, .radial_next = none, .radial_prev = none });
                em.radialInsert(@intCast(c), e);
            }
        }

        for (m.attrs[0..m.attr_count]) |a| {
            const want: usize = switch (a.domain) {
                .point => pos.len,
                .edge => edges.len,
                .face => n_faces,
                .corner => cv.len,
            };
            if (a.data.len() != want) return error.InvalidTopology;
            const data: LayerData = switch (a.data) {
                inline else => |s, tag| blk: {
                    var list: @FieldType(LayerData, @tagName(tag)) = .empty;
                    try list.appendSlice(gpa, s.slice());
                    break :blk @unionInit(LayerData, @tagName(tag), list);
                },
            };
            em.layers.append(gpa, .{ .name = a.name, .domain = a.domain, .data = data }) catch |e| {
                var d = data;
                switch (d) {
                    inline else => |*l| l.deinit(gpa),
                }
                return e;
            };
        }
        return em;
    }

    /// Compacts into a new Mesh (name and material slots left empty for the
    /// caller). When `maps` is given it receives old → new indices.
    pub fn toMesh(em: *const EditMesh, gpa: Allocator, maps: ?*Maps) Error!Mesh {
        const vmap = try liveMap(gpa, Vert, em.verts.items);
        defer if (maps == null) gpa.free(vmap);
        errdefer if (maps != null) gpa.free(vmap);
        const emap = try liveMap(gpa, Edge, em.edges.items);
        defer if (maps == null) gpa.free(emap);
        errdefer if (maps != null) gpa.free(emap);
        const fmap = try liveMap(gpa, Face, em.faces.items);
        defer if (maps == null) gpa.free(fmap);
        errdefer if (maps != null) gpa.free(fmap);

        const n_verts = countLive(vmap);
        const n_edges = countLive(emap);
        const n_faces = countLive(fmap);
        var n_corners: usize = 0;
        for (em.faces.items) |f| if (!f.removed) {
            n_corners += f.len;
        };

        const positions = try gpa.alloc(Vec3, n_verts);
        var positions_owned = true;
        defer if (positions_owned) gpa.free(positions);
        for (em.verts.items, vmap) |vert, i| if (i != none) {
            positions[i] = vert.co;
        };
        const edges = try gpa.alloc([2]u32, n_edges);
        var edges_owned = true;
        defer if (edges_owned) gpa.free(edges);
        for (em.edges.items, emap) |e, i| if (i != none) {
            const a = vmap[e.v[0]];
            const b = vmap[e.v[1]];
            if (a == none or b == none) return error.InvalidTopology;
            edges[i] = .{ a, b };
        };
        const offsets = try gpa.alloc(u32, if (n_faces == 0) 0 else n_faces + 1);
        var offsets_owned = true;
        defer if (offsets_owned) gpa.free(offsets);
        const corner_verts = try gpa.alloc(u32, n_corners);
        var cv_owned = true;
        defer if (cv_owned) gpa.free(corner_verts);
        const corner_edges = try gpa.alloc(u32, n_corners);
        var ce_owned = true;
        defer if (ce_owned) gpa.free(corner_edges);
        // Loop index of each output corner, for corner layers.
        const corner_loops = try gpa.alloc(u32, n_corners);
        defer gpa.free(corner_loops);

        var c: u32 = 0;
        var fi: usize = 0;
        for (em.faces.items) |f| {
            if (f.removed) continue;
            offsets[fi] = c;
            fi += 1;
            var l = f.l;
            for (0..f.len) |_| {
                const loop = em.loops.items[l];
                const vi = vmap[loop.v];
                const ei = emap[loop.e];
                if (vi == none or ei == none) return error.InvalidTopology;
                corner_verts[c] = vi;
                corner_edges[c] = ei;
                corner_loops[c] = l;
                c += 1;
                l = loop.next;
            }
        }
        if (n_faces > 0) offsets[n_faces] = c;

        var m: Mesh = .{};
        errdefer m.releaseRefs(gpa);
        positions_owned = false;
        m.positions = try .fromOwned(gpa, positions);
        edges_owned = false;
        m.edges = try .fromOwned(gpa, edges);
        offsets_owned = false;
        m.face_offsets = try .fromOwned(gpa, offsets);
        cv_owned = false;
        m.corner_verts = try .fromOwned(gpa, corner_verts);
        ce_owned = false;
        m.corner_edges = try .fromOwned(gpa, corner_edges);

        for (em.layers.items) |layer| {
            const data: AttrData = switch (layer.data) {
                inline else => |list, tag| blk: {
                    const Elem = std.meta.Elem(@TypeOf(list.items));
                    const n = switch (layer.domain) {
                        .point => n_verts,
                        .edge => n_edges,
                        .face => n_faces,
                        .corner => n_corners,
                    };
                    const out = try gpa.alloc(Elem, n);
                    switch (layer.domain) {
                        .point => scatter(Elem, list.items, vmap, out),
                        .edge => scatter(Elem, list.items, emap, out),
                        .face => scatter(Elem, list.items, fmap, out),
                        .corner => for (corner_loops, out) |l, *o| {
                            o.* = list.items[l];
                        },
                    }
                    break :blk @unionInit(AttrData, @tagName(tag), try .fromOwned(gpa, out));
                },
            };
            try m.setAttribute(gpa, layer.name.slice(), layer.domain, data);
        }
        if (maps) |out| out.* = .{ .verts = vmap, .edges = emap, .faces = fmap };
        return m;
    }

    pub fn liveVerts(em: *const EditMesh) usize {
        var n: usize = 0;
        for (em.verts.items) |x| n += @intFromBool(!x.removed);
        return n;
    }
    pub fn liveEdges(em: *const EditMesh) usize {
        var n: usize = 0;
        for (em.edges.items) |x| n += @intFromBool(!x.removed);
        return n;
    }
    pub fn liveFaces(em: *const EditMesh) usize {
        var n: usize = 0;
        for (em.faces.items) |x| n += @intFromBool(!x.removed);
        return n;
    }

    /// Operators call this once per element they process (and per step of
    /// any inner loop that can run long); it reads the clock every 1024 calls.
    pub fn tick(em: *EditMesh) math.DeadlineError!void {
        const s = em.stop orelse return;
        em.ticks +%= 1;
        if (em.ticks % 1024 == 0 and s.deadline.passed(s.io)) return error.DeadlineExceeded;
    }

    // ---- element creation ------------------------------------------------

    /// Room for this many more elements of each kind, layers included, so
    /// an operator that knows its output size grows each array once.
    pub fn reserve(em: *EditMesh, verts: usize, edges: usize, loops: usize, faces: usize) Allocator.Error!void {
        const gpa = em.gpa;
        try em.verts.ensureUnusedCapacity(gpa, verts);
        try em.edges.ensureUnusedCapacity(gpa, edges);
        try em.loops.ensureUnusedCapacity(gpa, loops);
        try em.faces.ensureUnusedCapacity(gpa, faces);
        for (em.layers.items) |*layer| {
            const n = switch (layer.domain) {
                .point => verts,
                .edge => edges,
                .face => faces,
                .corner => loops,
            };
            switch (layer.data) {
                inline else => |*d| try d.ensureUnusedCapacity(gpa, n),
            }
        }
    }

    /// Adds a vertex; its layer data copies `example`'s, or is zero.
    pub fn addVert(em: *EditMesh, co: Vec3, example: ?u32) Allocator.Error!u32 {
        const i: u32 = @intCast(em.verts.items.len);
        try em.appendData(.point, example);
        try em.verts.append(em.gpa, .{ .co = co });
        return i;
    }

    /// Adds an edge without checking for an existing one; see `ensureEdge`.
    pub fn addEdge(em: *EditMesh, a: u32, b: u32, example: ?u32) Allocator.Error!u32 {
        std.debug.assert(a != b);
        const i: u32 = @intCast(em.edges.items.len);
        try em.appendData(.edge, example);
        try em.edges.append(em.gpa, .{ .v = .{ @min(a, b), @max(a, b) } });
        em.diskInsert(i, a);
        em.diskInsert(i, b);
        return i;
    }

    /// The edge joining `a` and `b`, created (with `example`'s data) if missing.
    pub fn ensureEdge(em: *EditMesh, a: u32, b: u32, example: ?u32) Allocator.Error!u32 {
        return em.findEdge(a, b) orelse em.addEdge(a, b, example);
    }

    /// Elements whose layer data a new face copies; `none` entries copy nothing.
    pub const Examples = struct {
        face: ?u32 = null,
        /// Per corner.
        loops: ?[]const u32 = null,
        /// Per side (corner k to k + 1), used only for edges the face creates.
        edges: ?[]const u32 = null,
    };

    /// Adds a face over `verts` (at least 3, all distinct), creating missing
    /// edges, with layer data copied from `ex`.
    pub fn addFace(em: *EditMesh, verts: []const u32, ex: Examples) Error!u32 {
        if (verts.len < 3) return error.InvalidTopology;
        for (verts, 0..) |a, i| {
            if (a >= em.verts.items.len or em.verts.items[a].removed) return error.InvalidTopology;
            for (verts[i + 1 ..]) |b| if (a == b) return error.InvalidTopology;
        }
        const gpa = em.gpa;
        const f: u32 = @intCast(em.faces.items.len);
        const first: u32 = @intCast(em.loops.items.len);
        const n: u32 = @intCast(verts.len);
        try em.loops.ensureUnusedCapacity(gpa, n);
        try em.faces.ensureUnusedCapacity(gpa, 1);
        for (verts, 0..) |a, k| {
            const b = verts[(k + 1) % verts.len];
            _ = try em.ensureEdge(a, b, pick(ex.edges, k));
        }
        try em.appendData(.face, ex.face);
        for (0..n) |k| try em.appendData(.corner, pick(ex.loops, k));
        em.faces.appendAssumeCapacity(.{ .l = first, .len = n });
        for (verts, 0..) |a, k| {
            const b = verts[(k + 1) % verts.len];
            const kk: u32 = @intCast(k);
            const l = first + kk;
            em.loops.appendAssumeCapacity(.{
                .v = a,
                .e = em.findEdge(a, b).?,
                .f = f,
                .next = first + (kk + 1) % n,
                .prev = first + (kk + n - 1) % n,
                .radial_next = none,
                .radial_prev = none,
            });
            em.radialInsert(l, em.loops.items[l].e);
        }
        return f;
    }

    // ---- removal ---------------------------------------------------------

    /// Removes a face; its edges and vertices stay.
    pub fn removeFace(em: *EditMesh, f: u32) void {
        const face = &em.faces.items[f];
        if (face.removed) return;
        var l = face.l;
        for (0..face.len) |_| {
            em.radialRemove(l);
            l = em.loops.items[l].next;
        }
        face.removed = true;
    }

    /// Removes an edge and the faces that use it.
    pub fn removeEdge(em: *EditMesh, e: u32) void {
        if (em.edges.items[e].removed) return;
        while (em.edges.items[e].l != none) em.removeFace(em.loops.items[em.edges.items[e].l].f);
        const ends = em.edges.items[e].v;
        em.diskRemove(e, ends[0]);
        em.diskRemove(e, ends[1]);
        em.edges.items[e].removed = true;
    }

    /// Removes a vertex with its edges and faces.
    pub fn removeVert(em: *EditMesh, vi: u32) void {
        if (em.verts.items[vi].removed) return;
        while (em.verts.items[vi].e != none) em.removeEdge(em.verts.items[vi].e);
        em.verts.items[vi].removed = true;
    }

    // ---- queries ---------------------------------------------------------

    pub fn findEdge(em: *const EditMesh, a: u32, b: u32) ?u32 {
        const first = em.verts.items[a].e;
        if (first == none) return null;
        var e = first;
        while (true) {
            if (em.edgeOther(e, a) == b) return e;
            e = em.diskNext(e, a);
            if (e == first) return null;
        }
    }

    pub fn edgeOther(em: *const EditMesh, e: u32, vi: u32) u32 {
        const ends = em.edges.items[e].v;
        return if (ends[0] == vi) ends[1] else ends[0];
    }

    pub fn diskNext(em: *const EditMesh, e: u32, vi: u32) u32 {
        return em.edges.items[e].next[em.side(e, vi)];
    }

    /// Number of faces using edge `e` (the length of its radial cycle).
    pub fn edgeFaceCount(em: *const EditMesh, e: u32) u32 {
        const first = em.edges.items[e].l;
        if (first == none) return 0;
        var n: u32 = 0;
        var l = first;
        while (true) {
            n += 1;
            l = em.loops.items[l].radial_next;
            if (l == first) return n;
        }
    }

    pub fn vertEdgeCount(em: *const EditMesh, vi: u32) u32 {
        const first = em.verts.items[vi].e;
        if (first == none) return 0;
        var n: u32 = 0;
        var e = first;
        while (true) {
            n += 1;
            e = em.diskNext(e, vi);
            if (e == first) return n;
        }
    }

    /// Appends the vertices of face `f`, in corner order, to `out`.
    pub fn faceVerts(em: *const EditMesh, f: u32, gpa: Allocator, out: *std.ArrayList(u32)) Allocator.Error!void {
        const face = em.faces.items[f];
        try out.ensureUnusedCapacity(gpa, face.len);
        var l = face.l;
        for (0..face.len) |_| {
            out.appendAssumeCapacity(em.loops.items[l].v);
            l = em.loops.items[l].next;
        }
    }

    /// Newell normal of face `f`, normalised (zero for a degenerate face).
    pub fn faceNormal(em: *const EditMesh, f: u32) Vec3 {
        const face = em.faces.items[f];
        var n: Vec3 = .{ 0, 0, 0 };
        var l = face.l;
        for (0..face.len) |_| {
            const loop = em.loops.items[l];
            const a = em.verts.items[loop.v].co;
            const b = em.verts.items[em.loops.items[loop.next].v].co;
            n[0] += (a[1] - b[1]) * (a[2] + b[2]);
            n[1] += (a[2] - b[2]) * (a[0] + b[0]);
            n[2] += (a[0] - b[0]) * (a[1] + b[1]);
            l = loop.next;
        }
        return v.normalize(n);
    }

    /// Mean of the face's corner positions (the median centre).
    pub fn faceCenter(em: *const EditMesh, f: u32) Vec3 {
        const face = em.faces.items[f];
        var c: [3]f64 = .{ 0, 0, 0 };
        var l = face.l;
        for (0..face.len) |_| {
            const p = em.verts.items[em.loops.items[l].v].co;
            for (0..3) |k| c[k] += p[k];
            l = em.loops.items[l].next;
        }
        const n: f64 = @floatFromInt(face.len);
        return .{ @floatCast(c[0] / n), @floatCast(c[1] / n), @floatCast(c[2] / n) };
    }

    /// Manifold edges whose two faces run the same way along them, i.e.
    /// places where neighbouring faces disagree on winding (FR-GEO-3).
    pub fn windingConflicts(em: *const EditMesh) usize {
        var n: usize = 0;
        for (em.edges.items) |e| {
            if (e.removed or e.l == none) continue;
            const r = em.loops.items[e.l].radial_next;
            if (r == e.l or em.loops.items[r].radial_next != e.l) continue;
            if (em.loops.items[r].v == em.loops.items[e.l].v) n += 1;
        }
        return n;
    }

    /// Live faces with (nearly) zero area relative to their size.
    pub fn degenerateFaces(em: *const EditMesh) usize {
        var n: usize = 0;
        for (em.faces.items) |face| {
            if (face.removed) continue;
            var nrm: [3]f64 = .{ 0, 0, 0 };
            var perim: f64 = 0;
            var l = face.l;
            for (0..face.len) |_| {
                const loop = em.loops.items[l];
                const a = em.verts.items[loop.v].co;
                const b = em.verts.items[em.loops.items[loop.next].v].co;
                nrm[0] += (@as(f64, a[1]) - b[1]) * (@as(f64, a[2]) + b[2]);
                nrm[1] += (@as(f64, a[2]) - b[2]) * (@as(f64, a[0]) + b[0]);
                nrm[2] += (@as(f64, a[0]) - b[0]) * (@as(f64, a[1]) + b[1]);
                perim += v.length(v.sub(b, a));
                l = loop.next;
            }
            const twice_area = @sqrt(nrm[0] * nrm[0] + nrm[1] * nrm[1] + nrm[2] * nrm[2]);
            if (twice_area <= 1e-7 * perim * perim) n += 1;
        }
        return n;
    }

    /// Checks every cycle and back-reference; returns the first problem.
    /// Linear time; used by tests and after operators in safe builds.
    pub fn check(em: *const EditMesh) ?[]const u8 {
        const nv = em.verts.items.len;
        const ne = em.edges.items.len;
        const nl = em.loops.items.len;
        for (em.verts.items, 0..) |vert, i| {
            if (vert.removed or vert.e == none) continue;
            if (vert.e >= ne or em.edges.items[vert.e].removed) return "vertex points at a missing edge";
            const vi: u32 = @intCast(i);
            var e = vert.e;
            var steps: usize = 0;
            while (true) {
                const edge = em.edges.items[e];
                if (edge.v[0] != vi and edge.v[1] != vi) return "disk cycle holds an edge not at the vertex";
                const k = em.side(e, vi);
                const n = edge.next[k];
                if (n >= ne or em.edges.items[n].removed) return "disk cycle reaches a missing edge";
                if (em.edges.items[n].prev[em.side(n, vi)] != e) return "disk cycle links disagree";
                e = n;
                steps += 1;
                if (steps > ne) return "disk cycle does not close";
                if (e == vert.e) break;
            }
        }
        for (em.edges.items, 0..) |edge, i| {
            if (edge.removed) continue;
            if (edge.v[0] >= nv or edge.v[1] >= nv or edge.v[0] == edge.v[1]) return "edge has bad vertices";
            if (em.verts.items[edge.v[0]].removed or em.verts.items[edge.v[1]].removed) return "edge uses a removed vertex";
            if (edge.l == none) continue;
            var l = edge.l;
            var steps: usize = 0;
            while (true) {
                if (l >= nl) return "radial cycle reaches a missing loop";
                const loop = em.loops.items[l];
                if (loop.e != i) return "radial cycle holds a loop of another edge";
                if (em.faces.items[loop.f].removed) return "radial cycle holds a removed face's loop";
                if (em.loops.items[loop.radial_next].radial_prev != l) return "radial links disagree";
                l = loop.radial_next;
                steps += 1;
                if (steps > nl) return "radial cycle does not close";
                if (l == edge.l) break;
            }
        }
        for (em.faces.items, 0..) |face, i| {
            if (face.removed) continue;
            if (face.len < 3) return "face with fewer than 3 corners";
            var l = face.l;
            for (0..face.len) |_| {
                if (l >= nl) return "face cycle reaches a missing loop";
                const loop = em.loops.items[l];
                if (loop.f != i) return "face cycle holds a loop of another face";
                if (em.loops.items[loop.next].prev != l) return "face links disagree";
                const nxt = em.loops.items[loop.next].v;
                if (!edgeJoins(em.edges.items[loop.e].v, loop.v, nxt)) return "loop edge does not join its corners";
                if (em.verts.items[loop.v].removed) return "face uses a removed vertex";
                l = loop.next;
            }
            if (l != face.l) return "face cycle length differs from its corner count";
        }
        for (em.layers.items) |layer| {
            const want = switch (layer.domain) {
                .point => nv,
                .edge => ne,
                .face => em.faces.items.len,
                .corner => nl,
            };
            const have = switch (layer.data) {
                inline else => |d| d.items.len,
            };
            if (have != want) return "layer length does not match its domain";
        }
        return null;
    }

    // ---- layer data ------------------------------------------------------

    pub fn layerIndex(em: *const EditMesh, name: []const u8) ?usize {
        for (em.layers.items, 0..) |l, i| if (l.name.eql(name)) return i;
        return null;
    }

    /// Appends one element's worth of data to every layer of `domain`.
    fn appendData(em: *EditMesh, domain: Domain, example: ?u32) Allocator.Error!void {
        for (em.layers.items) |*layer| {
            if (layer.domain != domain) continue;
            switch (layer.data) {
                inline else => |*d| {
                    const x = if (example) |e| d.items[e] else std.mem.zeroes(std.meta.Elem(@TypeOf(d.items)));
                    try d.append(em.gpa, x);
                },
            }
        }
    }

    /// Copies all layer data of element `src` to `dst` within `domain`.
    pub fn copyData(em: *EditMesh, domain: Domain, dst: u32, src: u32) void {
        for (em.layers.items) |*layer| {
            if (layer.domain != domain) continue;
            switch (layer.data) {
                inline else => |*d| d.items[dst] = d.items[src],
            }
        }
    }

    /// Sets `dst`'s data to the weighted mix of `srcs`. Float layers blend;
    /// integer and boolean layers take the value of the heaviest source.
    pub fn interpData(em: *EditMesh, domain: Domain, dst: u32, srcs: []const u32, weights: []const f32) void {
        std.debug.assert(srcs.len == weights.len and srcs.len > 0);
        var best: usize = 0;
        for (weights, 0..) |w, i| if (w > weights[best]) {
            best = i;
        };
        for (em.layers.items) |*layer| {
            if (layer.domain != domain) continue;
            switch (layer.data) {
                .float => |*d| {
                    var acc: f32 = 0;
                    for (srcs, weights) |s, w| acc += d.items[s] * w;
                    d.items[dst] = acc;
                },
                inline .float2, .float3, .color => |*d| {
                    const T = std.meta.Elem(@TypeOf(d.items));
                    var acc: T = @splat(0);
                    for (srcs, weights) |s, w| for (0..acc.len) |k| {
                        acc[k] += d.items[s][k] * w;
                    };
                    d.items[dst] = acc;
                },
                inline .int, .boolean => |*d| d.items[dst] = d.items[srcs[best]],
            }
        }
    }

    // ---- cycle maintenance ----------------------------------------------

    fn side(em: *const EditMesh, e: u32, vi: u32) usize {
        return if (em.edges.items[e].v[0] == vi) 0 else 1;
    }

    /// Links `e` into the disk cycle of `vi`, after the last edge.
    fn diskInsert(em: *EditMesh, e: u32, vi: u32) void {
        const k = em.side(e, vi);
        const head = em.verts.items[vi].e;
        const edges = em.edges.items;
        if (head == none) {
            edges[e].prev[k] = e;
            edges[e].next[k] = e;
            em.verts.items[vi].e = e;
            return;
        }
        const kh = em.side(head, vi);
        const tail = edges[head].prev[kh];
        const kt = em.side(tail, vi);
        edges[e].next[k] = head;
        edges[e].prev[k] = tail;
        edges[tail].next[kt] = e;
        edges[head].prev[kh] = e;
    }

    fn diskRemove(em: *EditMesh, e: u32, vi: u32) void {
        const k = em.side(e, vi);
        const edges = em.edges.items;
        const n = edges[e].next[k];
        const p = edges[e].prev[k];
        if (n == e) {
            em.verts.items[vi].e = none;
        } else {
            edges[p].next[em.side(p, vi)] = n;
            edges[n].prev[em.side(n, vi)] = p;
            if (em.verts.items[vi].e == e) em.verts.items[vi].e = n;
        }
        edges[e].next[k] = none;
        edges[e].prev[k] = none;
    }

    fn radialInsert(em: *EditMesh, l: u32, e: u32) void {
        const loops = em.loops.items;
        const head = em.edges.items[e].l;
        if (head == none) {
            loops[l].radial_next = l;
            loops[l].radial_prev = l;
            em.edges.items[e].l = l;
            return;
        }
        const tail = loops[head].radial_prev;
        loops[l].radial_next = head;
        loops[l].radial_prev = tail;
        loops[tail].radial_next = l;
        loops[head].radial_prev = l;
    }

    fn radialRemove(em: *EditMesh, l: u32) void {
        const loops = em.loops.items;
        const e = loops[l].e;
        const n = loops[l].radial_next;
        const p = loops[l].radial_prev;
        if (n == l) {
            em.edges.items[e].l = none;
        } else {
            loops[p].radial_next = n;
            loops[n].radial_prev = p;
            if (em.edges.items[e].l == l) em.edges.items[e].l = n;
        }
        loops[l].radial_next = none;
        loops[l].radial_prev = none;
    }
};

fn pick(list: ?[]const u32, k: usize) ?u32 {
    const l = list orelse return null;
    return if (l[k] == none) null else l[k];
}

fn edgeJoins(e: [2]u32, a: u32, b: u32) bool {
    return (e[0] == a and e[1] == b) or (e[0] == b and e[1] == a);
}

fn liveMap(gpa: Allocator, comptime T: type, items: []const T) Allocator.Error![]u32 {
    const map = try gpa.alloc(u32, items.len);
    var n: u32 = 0;
    for (items, map) |x, *m| {
        if (x.removed) {
            m.* = none;
        } else {
            m.* = n;
            n += 1;
        }
    }
    return map;
}

fn countLive(map: []const u32) usize {
    var n: usize = 0;
    for (map) |i| n += @intFromBool(i != none);
    return n;
}

fn scatter(comptime T: type, src: []const T, map: []const u32, out: []T) void {
    for (src, map) |x, i| if (i != none) {
        out[i] = x;
    };
}

const testing = std.testing;
const prims = @import("primitives.zig");
const build = @import("build.zig");

fn expectSameMesh(a: *const Mesh, b: *const Mesh) !void {
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(a.positions.slice()), std.mem.sliceAsBytes(b.positions.slice()));
    try testing.expectEqualSlices([2]u32, a.edges.slice(), b.edges.slice());
    try testing.expectEqualSlices(u32, a.face_offsets.slice(), b.face_offsets.slice());
    try testing.expectEqualSlices(u32, a.corner_verts.slice(), b.corner_verts.slice());
    try testing.expectEqualSlices(u32, a.corner_edges.slice(), b.corner_edges.slice());
    try testing.expectEqual(a.attr_count, b.attr_count);
    for (a.attrs[0..a.attr_count], b.attrs[0..b.attr_count]) |x, y| {
        try testing.expectEqualStrings(x.name.slice(), y.name.slice());
        try testing.expectEqual(x.domain, y.domain);
        switch (x.data) {
            inline else => |s, tag| try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(s.slice()), std.mem.sliceAsBytes(@field(y.data, @tagName(tag)).slice())),
        }
    }
}

test "round trip of every primitive is lossless" {
    const gpa = testing.allocator;
    inline for (std.meta.fields(prims.Kind)) |k| {
        var m = try prims.generate(gpa, @enumFromInt(k.value), .{ .segments = 12, .rings = 6, .x_subdivisions = 3, .y_subdivisions = 2, .major_segments = 8, .minor_segments = 4 });
        defer m.releaseRefs(gpa);
        var em = try EditMesh.fromMesh(gpa, &m);
        defer em.deinit();
        try testing.expect(em.check() == null);
        var back = try em.toMesh(gpa, null);
        defer back.releaseRefs(gpa);
        try expectSameMesh(&m, &back);
    }
}

test "non-manifold edges, loose geometry and holes" {
    const gpa = testing.allocator;
    // Three triangles share edge 0-1 (non-manifold); vertex 5 is loose.
    var m = try build.fromPolygons(gpa, .{
        .positions = &.{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 5, 5, 5 } },
        .face_offsets = &.{ 0, 3, 6, 9 },
        .corner_verts = &.{ 0, 1, 2, 1, 0, 3, 0, 1, 4 },
    });
    defer m.releaseRefs(gpa);
    var em = try EditMesh.fromMesh(gpa, &m);
    defer em.deinit();
    try testing.expectEqual(@as(u32, 3), em.edgeFaceCount(em.findEdge(0, 1).?));
    try testing.expectEqual(@as(u32, 0), em.vertEdgeCount(5));
    // A loose edge to the loose vertex, then a hole: remove the middle face.
    const loose = try em.addEdge(2, 5, null);
    em.removeFace(1);
    try testing.expect(em.check() == null);
    try testing.expectEqual(@as(u32, 2), em.edgeFaceCount(em.findEdge(0, 1).?));
    try testing.expectEqual(@as(u32, 0), em.edgeFaceCount(loose));
    var out = try em.toMesh(gpa, null);
    defer out.releaseRefs(gpa);
    try testing.expect(build.validate(&out) == null);
    try testing.expectEqual(@as(usize, 2), out.faceCount());
    try testing.expectEqual(@as(usize, 6), out.vertCount());
    try testing.expectEqual(@as(usize, 8), out.edgeCount());
}

test "removal cascades and compaction remaps indices" {
    const gpa = testing.allocator;
    var m = try prims.generate(gpa, .cube, .{});
    defer m.releaseRefs(gpa);
    var em = try EditMesh.fromMesh(gpa, &m);
    defer em.deinit();
    em.removeVert(0);
    try testing.expect(em.check() == null);
    // Vertex 0 touches three faces and three edges of the cube.
    try testing.expectEqual(@as(usize, 7), em.liveVerts());
    try testing.expectEqual(@as(usize, 9), em.liveEdges());
    try testing.expectEqual(@as(usize, 3), em.liveFaces());
    var maps: Maps = undefined;
    var out = try em.toMesh(gpa, &maps);
    defer out.releaseRefs(gpa);
    defer maps.deinit(gpa);
    try testing.expectEqual(none, maps.verts[0]);
    try testing.expectEqual(@as(u32, 0), maps.verts[1]);
    try testing.expect(build.validate(&out) == null);
    try testing.expectEqual(@as(usize, 3 * 4), out.cornerCount());
    try testing.expectEqual(@as(usize, 3 * 4), out.attribute(Mesh.uv_name).?.data.len());
}

test "new faces copy and interpolate layer data" {
    const gpa = testing.allocator;
    var m = try prims.generate(gpa, .plane, .{});
    defer m.releaseRefs(gpa);
    var em = try EditMesh.fromMesh(gpa, &m);
    defer em.deinit();
    const c = try em.addVert(.{ 0, 0, 1 }, null);
    const f = try em.addFace(&.{ 0, 1, c }, .{ .face = 0, .loops = &.{ 0, 1, none } });
    const uv = em.layerIndex(Mesh.uv_name).?;
    const loops = &em.layers.items[uv].data.float2;
    em.interpData(.corner, em.faces.items[f].l + 2, &.{ 0, 1 }, &.{ 0.5, 0.5 });
    const want = [2]f32{ (loops.items[0][0] + loops.items[1][0]) / 2, (loops.items[0][1] + loops.items[1][1]) / 2 };
    try testing.expectEqual(want, loops.items[em.faces.items[f].l + 2]);
    try testing.expect(em.check() == null);
    var out = try em.toMesh(gpa, null);
    defer out.releaseRefs(gpa);
    try testing.expect(build.validate(&out) == null);
    try testing.expectEqual(@as(usize, 2), out.faceCount());
    // sharp_face was copied from face 0.
    try testing.expectEqual(true, out.attribute("sharp_face").?.data.boolean.slice()[1]);
}
