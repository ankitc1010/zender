//! Bevel edges (Blender's Bevel Edges, offset width, round profile).
//!
//! Around each vertex of a bevelled edge the faces are cut back. Where two
//! bevelled edges meet in a face, the face's corner moves to the point
//! `width` from both; where a bevelled edge meets an unbevelled one, the
//! corner slides along the unbevelled edge until it is `width` from the
//! bevelled one. Each bevelled edge becomes a strip of `segments` quads
//! whose cross-section is a quarter ellipse tangent to both faces (a circle
//! where they meet at 90°). The hole left at a vertex where bevelled edges
//! meet is closed with a polygon when segments is 1, and otherwise with
//! rings on the sphere through the strip ends; at the end of a single
//! bevelled edge the profile joins the end face instead. Widths that would
//! make the cuts of neighbouring edges cross are reduced.
//!
//! Bevelled edges need two faces, and their vertices a single closed fan of
//! consistently wound faces.

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

pub const max_segments = 64;

pub const Params = struct {
    /// Distance from each bevelled edge to its new edges, measured in its
    /// faces (world m).
    width: f32 = 0.1,
    /// Faces across each bevel; 1 is a flat chamfer.
    segments: u32 = 1,
};

/// Position k of the fan around a bevelled vertex: face k, entered by edge
/// E(k - 1) and left by edge E(k) = `edge`.
const Slot = struct {
    loop: u32,
    edge: u32,
    bevel: bool,
    /// World direction and length of E(k) from the vertex.
    dir: Vec3 = .{ 0, 0, 0 },
    len: f32 = 0,
    /// Unit world normal of face k.
    normal: Vec3 = .{ 0, 0, 0 },
    /// For unbevelled E(k): the vertex on it the faces now use, which is
    /// the old vertex unless a neighbouring edge is bevelled.
    edge_pt: u32 = none,
    /// Offset of the new point for a width of 1 m (world).
    edge_off: Vec3 = .{ 0, 0, 0 },
    /// When E(k - 1) and E(k) are both bevelled: the new corner of face k.
    face_pt: u32 = none,
    face_off: Vec3 = .{ 0, 0, 0 },
};

const Fan = struct {
    v: u32,
    /// World position of the vertex.
    pos: Vec3,
    start: u32,
    len: u32,
};

/// A corner of a face being built: vertex `v`, with corner data mixed from
/// up to three old loops.
const Corner = struct {
    v: u32,
    src: [3]u32 = .{ none, none, none },
    w: [3]f32 = .{ 1, 0, 0 },
    n: u8 = 0,
    /// Example for the edge from this corner to the next one.
    edge: u32 = none,

    fn copy(vert: u32, l: u32, edge: u32) Corner {
        return .{ .v = vert, .src = .{ l, none, none }, .n = 1, .edge = edge };
    }
};

const Profile = struct {
    start: u32,
    /// World corner of the quarter ellipse, on the bevelled edge's line.
    corner: Vec3,
};

const Bevel = struct {
    em: *EditMesh,
    gpa: Allocator,
    xf: Xform,
    segments: u32,
    is_bev: std.DynamicBitSetUnmanaged = .{},
    fans: std.ArrayList(Fan) = .empty,
    slots: std.ArrayList(Slot) = .empty,
    /// Vertex → index into `fans`.
    fan_of: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Loop → index into `slots`.
    slot_of: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// (fan, low vertex, high vertex) → its points in `profile_verts`.
    profiles: std.AutoHashMapUnmanaged([3]u32, Profile) = .empty,
    profile_verts: std.ArrayList(u32) = .empty,
    /// Old face → its rebuilt face.
    rebuilt: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Scratch space reused from face to face, so building a face
    /// allocates nothing once these have grown.
    vs: std.ArrayList(u32) = .empty,
    ls: std.ArrayList(u32) = .empty,
    es: std.ArrayList(u32) = .empty,
    ring: std.ArrayList(u32) = .empty,
    prof_buf: std.ArrayList(u32) = .empty,
    corner_buf: std.ArrayList(Corner) = .empty,
    outer: std.ArrayList(u32) = .empty,
    inner: std.ArrayList(u32) = .empty,

    fn deinit(b: *Bevel) void {
        const gpa = b.gpa;
        inline for (.{ "vs", "ls", "es", "ring", "prof_buf", "corner_buf", "outer", "inner" }) |f| @field(b, f).deinit(gpa);
        b.is_bev.deinit(gpa);
        b.fans.deinit(gpa);
        b.slots.deinit(gpa);
        b.fan_of.deinit(gpa);
        b.slot_of.deinit(gpa);
        b.profiles.deinit(gpa);
        b.profile_verts.deinit(gpa);
        b.rebuilt.deinit(gpa);
    }

    fn fanSlots(b: *const Bevel, fi: usize) []Slot {
        const f = b.fans.items[fi];
        return b.slots.items[f.start..][0..f.len];
    }

    fn world(b: *const Bevel, x: u32) Vec3 {
        return b.xf.toWorld(b.em.verts.items[x].co);
    }

    /// The vertex face k uses for edge E(k - 1).
    fn inPt(s: []const Slot, k: usize) u32 {
        const prev = (k + s.len - 1) % s.len;
        if (s[prev].bevel) return if (s[k].bevel) s[k].face_pt else s[k].edge_pt;
        return s[prev].edge_pt;
    }

    /// The vertex face k uses for edge E(k).
    fn outPt(s: []const Slot, k: usize) u32 {
        const prev = (k + s.len - 1) % s.len;
        if (s[k].bevel) return if (s[prev].bevel) s[k].face_pt else s[prev].edge_pt;
        return s[k].edge_pt;
    }
};

/// Bevels `edges`. Selected afterwards: the new faces (strips and corner
/// patches). `out.width_used` is the width after any reduction.
pub fn bevel(em: *EditMesh, gpa: Allocator, edges: []const u32, xf: Xform, p: Params) Error!Outcome {
    var out: Outcome = .{ .domain = .face };
    errdefer out.deinit(gpa);
    var b: Bevel = .{ .em = em, .gpa = gpa, .xf = xf, .segments = std.math.clamp(p.segments, 1, max_segments) };
    defer b.deinit();

    b.is_bev = try .initEmpty(gpa, em.edges.items.len);
    var bev_list: std.ArrayList(u32) = .empty;
    defer bev_list.deinit(gpa);
    for (edges) |e| {
        if (b.is_bev.isSet(e)) continue;
        if (em.edgeFaceCount(e) != 2) {
            out.skipped += 1;
            continue;
        }
        b.is_bev.set(e);
        try bev_list.append(gpa, e);
    }
    if (bev_list.items.len == 0) return out;
    std.mem.sort(u32, bev_list.items, {}, std.sort.asc(u32));

    var verts: std.ArrayList(u32) = .empty;
    defer verts.deinit(gpa);
    for (bev_list.items) |e| for (em.edges.items[e].v) |x| try verts.append(gpa, x);
    std.mem.sort(u32, verts.items, {}, std.sort.asc(u32));
    var vi: usize = 0;
    for (verts.items) |x| {
        if (vi > 0 and verts.items[vi - 1] == x) continue;
        verts.items[vi] = x;
        vi += 1;
    }
    verts.items.len = vi;

    try b.fan_of.ensureTotalCapacity(gpa, @intCast(verts.items.len));
    try b.slot_of.ensureTotalCapacity(gpa, @intCast(6 * verts.items.len));
    try b.slots.ensureTotalCapacity(gpa, 6 * verts.items.len);
    try b.profiles.ensureTotalCapacity(gpa, @intCast(2 * bev_list.items.len));
    for (verts.items) |x| try buildFan(&b, x);
    for (0..b.fans.items.len) |fi| measure(&b, fi);
    const width = clampWidth(&b, @max(p.width, 0));
    out.width_used = width;
    for (0..b.fans.items.len) |fi| try placePoints(&b, fi, width);
    // Each bevelled edge's two faces, before the rebuild removes them.
    const sides = try gpa.alloc([2]u32, bev_list.items.len);
    defer gpa.free(sides);
    for (bev_list.items, sides) |e, *fs| {
        const l = em.edges.items[e].l;
        fs.* = .{ em.loops.items[l].f, em.loops.items[em.loops.items[l].radial_next].f };
    }
    try rebuildFaces(&b);
    for (bev_list.items, sides) |e, fs| try strip(&b, e, fs, &out);
    for (0..b.fans.items.len) |fi| try cornerPatch(&b, fi, &out);

    // The bevelled edges and the old edges cut back from them are left
    // without faces; vertices left without edges go too.
    for (bev_list.items) |e| em.removeEdge(e);
    var loose: std.ArrayList(u32) = .empty;
    defer loose.deinit(gpa);
    for (b.fans.items) |f| {
        loose.clearRetainingCapacity();
        const first = em.verts.items[f.v].e;
        if (first != none) {
            var e = first;
            while (true) {
                if (em.edges.items[e].l == none) try loose.append(gpa, e);
                e = em.diskNext(e, f.v);
                if (e == first) break;
            }
        }
        for (loose.items) |e| em.removeEdge(e);
        if (em.verts.items[f.v].e == none) em.removeVert(f.v);
    }
    return out;
}

/// Records the faces around `x` in rotation order.
fn buildFan(b: *Bevel, x: u32) Error!void {
    const em = b.em;
    const loops = em.loops.items;
    // Start from a loop at x on one of its bevelled edges.
    var start: u32 = none;
    const first_e = em.verts.items[x].e;
    var e = first_e;
    while (true) {
        if (b.is_bev.isSet(e)) {
            const r = em.edges.items[e].l;
            start = if (loops[r].v == x) r else loops[r].next;
            break;
        }
        e = em.diskNext(e, x);
        if (e == first_e) break;
    }
    const fan_start: u32 = @intCast(b.slots.items.len);
    var l = start;
    var n: u32 = 0;
    const valence = em.vertEdgeCount(x);
    while (true) {
        try em.tick();
        if (loops[l].v != x or n >= valence) return error.NonManifold;
        const edge = loops[l].e;
        try b.slots.append(b.gpa, .{ .loop = l, .edge = edge, .bevel = b.is_bev.isSet(edge) });
        try b.slot_of.put(b.gpa, l, fan_start + n);
        n += 1;
        // Across E(k) to the next face: its loop on E(k) runs the other way.
        const r = loops[l].radial_next;
        if (r == l or loops[r].radial_next != l or loops[r].v == x) return error.NonManifold;
        l = loops[r].next;
        if (l == start) break;
    }
    if (n != valence) return error.NonManifold;
    try b.fan_of.put(b.gpa, x, @intCast(b.fans.items.len));
    try b.fans.append(b.gpa, .{ .v = x, .pos = b.world(x), .start = fan_start, .len = n });
}

/// Directions, normals and the unit-width offsets of the new points.
fn measure(b: *Bevel, fi: usize) void {
    const em = b.em;
    const fan = b.fans.items[fi];
    const s = b.fanSlots(fi);
    const m = s.len;
    for (s) |*slot| {
        const d = v.sub(b.world(em.edgeOther(slot.edge, fan.v)), fan.pos);
        slot.len = v.length(d);
        slot.dir = if (slot.len > 0) v.scale(d, 1 / slot.len) else d;
        slot.normal = b.xf.normalToWorld(em.faceNormal(em.loops.items[slot.loop].f));
    }
    for (s, 0..) |*slot, k| {
        const prev = s[(k + m - 1) % m];
        const next = s[(k + 1) % m];
        // Inward (into face k) sides of E(k) and E(k - 1).
        const q_out = v.normalize(v.cross(slot.normal, slot.dir));
        const q_in = v.scale(v.normalize(v.cross(slot.normal, prev.dir)), -1);
        if (prev.bevel and slot.bevel) {
            // The point 1 m from both lines in face k.
            const den = v.dot(slot.dir, q_in);
            slot.face_off = if (@abs(den) < 1e-4)
                v.scale(v.add(q_out, q_in), 0.5)
            else
                v.add(q_out, v.scale(slot.dir, (1 - v.dot(q_out, q_in)) / den));
        }
        if (!slot.bevel and (prev.bevel or next.bevel)) {
            // Slide along E(k) until 1 m from the bevelled neighbour(s).
            var t: f32 = 0;
            var count: f32 = 0;
            var fallback: Vec3 = .{ 0, 0, 0 };
            if (prev.bevel) {
                const den = v.dot(slot.dir, q_in);
                if (den > 1e-3) {
                    t += 1 / den;
                    count += 1;
                } else fallback = q_in;
            }
            if (next.bevel) {
                // In face k + 1, E(k) comes in and E(k + 1) goes out.
                const q_next = v.normalize(v.cross(next.normal, next.dir));
                const den = v.dot(slot.dir, q_next);
                if (den > 1e-3) {
                    t += 1 / den;
                    count += 1;
                } else fallback = q_next;
            }
            slot.edge_off = if (count > 0) v.scale(slot.dir, t / count) else fallback;
        }
    }
}

/// The largest width (up to `want`) at which no two cuts along an edge
/// cross, with a small margin.
fn clampWidth(b: *Bevel, want: f32) f32 {
    var limit: f32 = std.math.inf(f32);
    // Along each edge: how far the new points at its ends reach, per side.
    var reach: std.AutoHashMapUnmanaged([2]u32, f32) = .empty;
    defer reach.deinit(b.gpa);
    for (0..b.fans.items.len) |fi| {
        const s = b.fanSlots(fi);
        const m = s.len;
        for (s, 0..) |slot, k| {
            const prev = s[(k + m - 1) % m];
            const next = s[(k + 1) % m];
            if (slot.bevel) {
                const a = if (prev.bevel) slot.face_off else prev.edge_off;
                const c = if (next.bevel) next.face_off else next.edge_off;
                const fa = b.em.loops.items[slot.loop].f;
                const fc = b.em.loops.items[next.loop].f;
                addReach(b, &reach, slot.edge, fa, v.dot(a, slot.dir));
                addReach(b, &reach, slot.edge, fc, v.dot(c, slot.dir));
            } else if (prev.bevel or next.bevel) {
                addReach(b, &reach, slot.edge, none, v.dot(slot.edge_off, slot.dir));
            }
        }
    }
    var it = reach.iterator();
    while (it.next()) |kv| {
        const e = b.em.edges.items[kv.key_ptr[0]].v;
        const len = v.length(v.sub(b.world(e[1]), b.world(e[0])));
        if (kv.value_ptr.* > 1e-6) limit = @min(limit, len / kv.value_ptr.*);
    }
    return @min(want, 0.99 * limit);
}

fn addReach(b: *Bevel, reach: *std.AutoHashMapUnmanaged([2]u32, f32), e: u32, f: u32, x: f32) void {
    const gop = reach.getOrPut(b.gpa, .{ e, f }) catch return;
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* += @max(x, 0);
}

fn placePoints(b: *Bevel, fi: usize, width: f32) Error!void {
    const em = b.em;
    const fan = b.fans.items[fi];
    const s = b.fanSlots(fi);
    const m = s.len;
    for (s, 0..) |*slot, k| {
        const prev = s[(k + m - 1) % m];
        const next = s[(k + 1) % m];
        if (!slot.bevel) {
            if (prev.bevel or next.bevel) {
                const off = v.scale(slot.edge_off, width);
                const x = try em.addVert(b.xf.toLocal(v.add(fan.pos, off)), null);
                const t = if (slot.len > 0) std.math.clamp(v.length(off) / slot.len, 0, 1) else 0;
                em.interpData(.point, x, &.{ fan.v, em.edgeOther(slot.edge, fan.v) }, &.{ 1 - t, t });
                slot.edge_pt = x;
            } else slot.edge_pt = fan.v;
        }
        if (prev.bevel and slot.bevel) {
            slot.face_pt = try em.addVert(b.xf.toLocal(v.add(fan.pos, v.scale(slot.face_off, width))), fan.v);
        }
    }
}

/// Corner data for new point `x` at the corner of loop `l` (vertex P):
/// written as P + α·(next - P) + β·(prev - P) in the face, which mixes the
/// corner data of l, its next and its previous loop.
fn cornerAt(b: *const Bevel, x: u32, l: u32, edge: u32) Corner {
    const em = b.em;
    const loops = em.loops.items;
    if (x == loops[l].v) return Corner.copy(x, l, edge);
    const p = b.world(loops[l].v);
    const a = v.sub(b.world(loops[loops[l].next].v), p);
    const c = v.sub(b.world(loops[loops[l].prev].v), p);
    const d = v.sub(b.world(x), p);
    const aa = v.dot(a, a);
    const ac = v.dot(a, c);
    const cc = v.dot(c, c);
    const det = aa * cc - ac * ac;
    if (@abs(det) < 1e-12) return Corner.copy(x, l, edge);
    const alpha = std.math.clamp((cc * v.dot(a, d) - ac * v.dot(c, d)) / det, 0, 1);
    const beta = std.math.clamp((aa * v.dot(c, d) - ac * v.dot(a, d)) / det, 0, 1);
    return .{ .v = x, .src = .{ l, loops[l].next, loops[l].prev }, .w = .{ 1 - alpha - beta, alpha, beta }, .n = 3, .edge = edge };
}

/// Rebuilds every face around a bevelled vertex with its corners moved.
fn rebuildFaces(b: *Bevel) Error!void {
    const em = b.em;
    const gpa = b.gpa;
    var faces: std.ArrayList(u32) = .empty;
    defer faces.deinit(gpa);
    for (b.slots.items) |slot| try faces.append(gpa, em.loops.items[slot.loop].f);
    std.mem.sort(u32, faces.items, {}, std.sort.asc(u32));
    var n: usize = 0;
    for (faces.items) |f| {
        if (n > 0 and faces.items[n - 1] == f) continue;
        faces.items[n] = f;
        n += 1;
    }
    faces.items.len = n;

    var corners: std.ArrayList(Corner) = .empty;
    defer corners.deinit(gpa);
    var spans: std.ArrayList([2]u32) = .empty;
    defer spans.deinit(gpa);
    for (faces.items) |f| {
        try em.tick();
        const start: u32 = @intCast(corners.items.len);
        const face = em.faces.items[f];
        var l = face.l;
        for (0..face.len) |_| {
            const loop = em.loops.items[l];
            if (b.slot_of.get(l)) |si| {
                const fi = b.fan_of.get(loop.v).?;
                const s = b.fanSlots(fi);
                const k = si - b.fans.items[fi].start;
                const a = Bevel.inPt(s, k);
                const c = Bevel.outPt(s, k);
                if (a != c) try corners.append(gpa, cornerAt(b, a, l, none));
                try corners.append(gpa, cornerAt(b, c, l, loop.e));
            } else {
                try corners.append(gpa, Corner.copy(loop.v, l, loop.e));
            }
            l = loop.next;
        }
        try spans.append(gpa, .{ start, @intCast(corners.items.len) });
    }
    for (faces.items) |f| em.removeFace(f);
    for (faces.items, spans.items) |f, span| {
        const nf = try addFace(b, corners.items[span[0]..span[1]], f, false);
        try b.rebuilt.put(gpa, f, nf);
    }
}

/// Adds a face over `cs` (reversed first when `flip`), copying face data
/// from `example` and mixing corner data as each corner says.
fn addFace(b: *Bevel, cs: []Corner, example: u32, flip: bool) Error!u32 {
    const em = b.em;
    const gpa = b.gpa;
    if (flip) std.mem.reverse(Corner, cs);
    b.vs.clearRetainingCapacity();
    b.ls.clearRetainingCapacity();
    b.es.clearRetainingCapacity();
    for (cs, 0..) |c, i| {
        try b.vs.append(gpa, c.v);
        try b.ls.append(gpa, if (c.n == 1) c.src[0] else none);
        // After a flip the side from corner i runs to what was corner i - 1.
        try b.es.append(gpa, if (flip) cs[(i + 1) % cs.len].edge else c.edge);
    }
    const f = try em.addFace(b.vs.items, .{ .face = example, .loops = b.ls.items, .edges = b.es.items });
    const first = em.faces.items[f].l;
    for (cs, 0..) |c, i| if (c.n > 1) em.interpData(.corner, first + @as(u32, @intCast(i)), c.src[0..c.n], c.w[0..c.n]);
    return f;
}

/// True when a face over `verts` would run the same way as its neighbours
/// along shared edges, so it must be reversed to match them.
fn runsBackwards(em: *const EditMesh, verts: []const u32) bool {
    var votes: i32 = 0;
    for (verts, 0..) |a, i| {
        const c = verts[(i + 1) % verts.len];
        const e = em.findEdge(a, c) orelse continue;
        const first = em.edges.items[e].l;
        if (first == none) continue;
        var l = first;
        while (true) {
            votes += if (em.loops.items[l].v == a) 1 else -1;
            l = em.loops.items[l].radial_next;
            if (l == first) break;
        }
    }
    return votes > 0;
}

/// Adds a face over `cs`, wound to agree with the faces it touches.
fn addOriented(b: *Bevel, cs: []Corner, example: u32) Error!u32 {
    b.vs.clearRetainingCapacity();
    for (cs) |c| try b.vs.append(b.gpa, c.v);
    return addFace(b, cs, example, runsBackwards(b.em, b.vs.items));
}

/// The profile at fan `fi` from vertex `from` to vertex `to` across the
/// edge running along `dir`: segments + 1 vertices, created on first use
/// and shared by every strip and patch that ends there. Returns its corner.
///
/// The curve is P(θ) = L + R - C - (R - C) cos θ - (L - C) sin θ for θ in
/// [0, π/2], with C on the edge's line, so it is tangent to both faces at
/// its ends. C sits at the nearer of L and R measured along the edge, which
/// is the old vertex when an end lies on an unbevelled edge across it (so
/// two strips meeting there agree on the curve).
fn profile(b: *Bevel, fi: usize, from: u32, to: u32, dir: Vec3, out: []u32) Error!Vec3 {
    const n = b.segments;
    const lo = @min(from, to);
    const hi = @max(from, to);
    const gop = try b.profiles.getOrPut(b.gpa, .{ @intCast(fi), lo, hi });
    if (!gop.found_existing) {
        const q = b.fans.items[fi].pos;
        const l = b.world(lo);
        const r = b.world(hi);
        const along = @min(v.dot(v.sub(l, q), dir), v.dot(v.sub(r, q), dir));
        const c = v.add(q, v.scale(dir, along));
        gop.value_ptr.* = .{ .start = @intCast(b.profile_verts.items.len), .corner = c };
        const o = v.sub(v.add(l, r), c);
        try b.profile_verts.append(b.gpa, lo);
        for (1..n) |j| {
            const th = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(n)) * (std.math.pi / 2.0);
            const pt = v.sub(v.sub(o, v.scale(v.sub(r, c), @cos(th))), v.scale(v.sub(l, c), @sin(th)));
            try b.profile_verts.append(b.gpa, try b.em.addVert(b.xf.toLocal(pt), b.fans.items[fi].v));
        }
        try b.profile_verts.append(b.gpa, hi);
    }
    const ids = b.profile_verts.items[gop.value_ptr.start..][0 .. n + 1];
    if (from == lo) {
        @memcpy(out, ids);
    } else {
        for (out, 0..) |*o, i| o.* = ids[n - i];
    }
    return gop.value_ptr.corner;
}

/// The loop of rebuilt face `f` (an old face index) at vertex `x`.
fn loopAt(b: *const Bevel, f: u32, x: u32) u32 {
    const em = b.em;
    const nf = b.rebuilt.get(f).?;
    var l = em.faces.items[nf].l;
    for (0..em.faces.items[nf].len) |_| {
        if (em.loops.items[l].v == x) return l;
        l = em.loops.items[l].next;
    }
    return em.faces.items[nf].l;
}

/// The strip of quads that replaces bevelled edge `e`.
fn strip(b: *Bevel, e: u32, faces: [2]u32, out: *Outcome) Error!void {
    const em = b.em;
    const gpa = b.gpa;
    try em.tick();
    const f1 = faces[0];
    const f2 = faces[1];
    const n = b.segments;
    const ends = em.edges.items[e].v;
    try b.prof_buf.resize(gpa, 2 * (n + 1));
    const buf = b.prof_buf.items;
    const prof = [2][]u32{ buf[0 .. n + 1], buf[n + 1 ..] };
    for (ends, 0..) |x, i| {
        const fi = b.fan_of.get(x).?;
        const s = b.fanSlots(fi);
        var k: usize = 0;
        while (s[k].edge != e) k += 1;
        const in_k = em.loops.items[s[k].loop].f;
        const pa = Bevel.outPt(s, k);
        const pb = Bevel.inPt(s, (k + 1) % s.len);
        const from, const to = if (in_k == f1) .{ pa, pb } else .{ pb, pa };
        _ = try profile(b, fi, from, to, s[k].dir, prof[i]);
    }
    // Corner data runs from face f1's side to face f2's.
    const c0 = [2]u32{ loopAt(b, f1, prof[0][0]), loopAt(b, f2, prof[0][n]) };
    const c1 = [2]u32{ loopAt(b, f1, prof[1][0]), loopAt(b, f2, prof[1][n]) };
    for (0..n) |j| {
        var cs = [4]Corner{
            mixed(prof[0][j], c0, j, n),
            mixed(prof[0][j + 1], c0, j + 1, n),
            mixed(prof[1][j + 1], c1, j + 1, n),
            mixed(prof[1][j], c1, j, n),
        };
        try out.selected.append(gpa, try addOriented(b, &cs, f1));
    }
}

fn mixed(x: u32, src: [2]u32, j: usize, n: u32) Corner {
    const t = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(n));
    return .{ .v = x, .src = .{ src[0], src[1], none }, .w = .{ 1 - t, t, 0 }, .n = 2 };
}

/// Closes the hole at fan `fi`, if any.
fn cornerPatch(b: *Bevel, fi: usize, out: *Outcome) Error!void {
    const em = b.em;
    const gpa = b.gpa;
    const s = b.fanSlots(fi);
    const n = b.segments;
    const ring = &b.ring;
    ring.clearRetainingCapacity();
    var arcs: usize = 0;
    var plain = false;
    var centres: Vec3 = .{ 0, 0, 0 };
    try b.prof_buf.resize(gpa, n + 1);
    const buf = b.prof_buf.items;
    for (s, 0..) |slot, k| {
        if (slot.bevel) {
            const from = Bevel.outPt(s, k);
            const to = Bevel.inPt(s, (k + 1) % s.len);
            const c = try profile(b, fi, from, to, slot.dir, buf);
            try ring.appendSlice(gpa, buf);
            arcs += 1;
            centres = v.add(centres, v.sub(v.add(b.world(from), b.world(to)), c));
        } else {
            try ring.append(gpa, slot.edge_pt);
            plain = true;
        }
    }
    reduce(ring);
    const w = ring.items.len;
    if (w < 3) return;

    const example = em.loops.items[s[0].loop].f;
    const corner_src = s[0].loop;
    if (arcs == 1 and w == n + 1) {
        // The end of a lone bevelled edge: the profile joins the face that
        // already spans its two ends.
        try joinEndFace(b, ring.items);
        return;
    }
    if (n == 1 or plain) {
        try b.corner_buf.resize(gpa, w);
        const cs = b.corner_buf.items;
        for (ring.items, cs) |x, *c| c.* = Corner.copy(x, corner_src, none);
        try out.selected.append(gpa, try addOriented(b, cs, example));
        return;
    }

    // Rings on the sphere through the strip ends, then a fan to its pole.
    const m = v.scale(centres, 1 / @as(f32, @floatFromInt(arcs)));
    var radius: f32 = 0;
    var mean: Vec3 = .{ 0, 0, 0 };
    for (ring.items) |x| {
        radius += v.length(v.sub(b.world(x), m));
        mean = v.add(mean, b.world(x));
    }
    const count: f32 = @floatFromInt(w);
    radius /= count;
    mean = v.scale(mean, 1 / count);
    var up = v.sub(mean, m);
    if (v.length(up) < 1e-9) up = v.sub(mean, b.fans.items[fi].pos);
    const pole_pos = v.add(m, v.scale(v.normalize(up), radius));
    const rings = @max(1, n / 2);
    b.outer.clearRetainingCapacity();
    try b.outer.appendSlice(gpa, ring.items);
    try b.inner.resize(gpa, w);
    var outer = b.outer.items;
    var inner = b.inner.items;
    for (1..rings) |t| {
        const f = @as(f32, @floatFromInt(t)) / @as(f32, @floatFromInt(rings));
        for (ring.items, inner) |x, *y| {
            const q = v.lerp(b.world(x), pole_pos, f);
            y.* = try em.addVert(b.xf.toLocal(v.add(m, v.scale(v.normalize(v.sub(q, m)), radius))), b.fans.items[fi].v);
        }
        for (0..w) |i| {
            var cs = [4]Corner{
                Corner.copy(outer[i], corner_src, none),
                Corner.copy(outer[(i + 1) % w], corner_src, none),
                Corner.copy(inner[(i + 1) % w], corner_src, none),
                Corner.copy(inner[i], corner_src, none),
            };
            try out.selected.append(gpa, try addOriented(b, &cs, example));
        }
        std.mem.swap([]u32, &outer, &inner);
    }
    const pole = try em.addVert(b.xf.toLocal(pole_pos), b.fans.items[fi].v);
    for (0..w) |i| {
        var cs = [3]Corner{
            Corner.copy(outer[i], corner_src, none),
            Corner.copy(outer[(i + 1) % w], corner_src, none),
            Corner.copy(pole, corner_src, none),
        };
        try out.selected.append(gpa, try addOriented(b, &cs, example));
    }
}

/// Drops repeated points where neighbours share one, and out-and-back runs
/// where two strips share a profile, around the cyclic `ring`.
fn reduce(ring: *std.ArrayList(u32)) void {
    var n: usize = 0;
    const r = ring.items;
    for (r) |x| {
        if (n >= 1 and r[n - 1] == x) continue;
        if (n >= 2 and r[n - 2] == x) {
            n -= 1;
            continue;
        }
        r[n] = x;
        n += 1;
    }
    // The same where the ring wraps around.
    while (true) {
        if (n >= 2 and r[n - 1] == r[0]) {
            n -= 1;
        } else if (n >= 3 and r[n - 2] == r[0]) {
            n -= 1;
        } else if (n >= 3 and r[1] == r[n - 1]) {
            std.mem.copyForwards(u32, r[0 .. n - 1], r[1..n]);
            n -= 1;
        } else break;
    }
    ring.items.len = n;
}

/// Inserts the inner profile points of `arc` into the face that has an
/// edge between the arc's two ends.
fn joinEndFace(b: *Bevel, arc: []const u32) Error!void {
    const em = b.em;
    const gpa = b.gpa;
    const a = arc[0];
    const z = arc[arc.len - 1];
    const e = em.findEdge(a, z) orelse return;
    const l0 = em.edges.items[e].l;
    if (l0 == none) return;
    const f = em.loops.items[l0].f;
    // The face runs a → z or z → a along the edge; insert in its direction.
    const forward = em.loops.items[l0].v == a;
    var cs: std.ArrayList(Corner) = .empty;
    defer cs.deinit(gpa);
    var l = em.faces.items[f].l;
    for (0..em.faces.items[f].len) |_| {
        const loop = em.loops.items[l];
        try cs.append(gpa, Corner.copy(loop.v, l, if (l == l0) none else loop.e));
        if (l == l0) {
            const inner = arc[1 .. arc.len - 1];
            for (0..inner.len) |i| {
                const x = if (forward) inner[i] else inner[inner.len - 1 - i];
                const t = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(inner.len + 1));
                try cs.append(gpa, .{ .v = x, .src = .{ l, loop.next, none }, .w = .{ 1 - t, t, 0 }, .n = 2 });
            }
        }
        l = loop.next;
    }
    em.removeFace(f);
    em.removeEdge(e);
    _ = try addFace(b, cs.items, f, false);
}

const testing = std.testing;
const prims = @import("../primitives.zig");
const build = @import("../build.zig");
const Mesh = @import("../../core/root.zig").types.Mesh;

fn finish(em: *EditMesh) !Mesh {
    try testing.expect(em.check() == null);
    try testing.expectEqual(@as(usize, 0), em.windingConflicts());
    const m = try em.toMesh(testing.allocator, null);
    try testing.expect(build.validate(&m) == null);
    return m;
}

fn allEdges(em: *const EditMesh, buf: []u32) []u32 {
    for (buf, 0..) |*x, i| x.* = @intCast(i);
    return buf[0..em.edges.items.len];
}

/// Euler characteristic and closedness of a cube-like result.
fn expectClosed(m: *const Mesh) !void {
    const chi = @as(i64, @intCast(m.vertCount())) - @as(i64, @intCast(m.edgeCount())) + @as(i64, @intCast(m.faceCount()));
    try testing.expectEqual(@as(i64, 2), chi);
    var em = try EditMesh.fromMesh(testing.allocator, m);
    defer em.deinit();
    for (em.edges.items, 0..) |_, e| try testing.expectEqual(@as(u32, 2), em.edgeFaceCount(@intCast(e)));
}

fn topFrontEdge(em: *const EditMesh) u32 {
    for (em.edges.items, 0..) |e, i| {
        const a = em.verts.items[e.v[0]].co;
        const c = em.verts.items[e.v[1]].co;
        if (a[1] == -1 and c[1] == -1 and a[2] == 1 and c[2] == 1) return @intCast(i);
    }
    unreachable;
}

test "chamfering one edge of a cube" {
    const gpa = testing.allocator;
    var cube = try prims.generate(gpa, .cube, .{});
    defer cube.releaseRefs(gpa);
    var em = try EditMesh.fromMesh(gpa, &cube);
    defer em.deinit();
    var out = try bevel(&em, gpa, &.{topFrontEdge(&em)}, .identity, .{ .width = 0.25 });
    defer out.deinit(gpa);
    var m = try finish(&em);
    defer m.releaseRefs(gpa);
    try testing.expectEqual(@as(usize, 10), m.vertCount());
    try testing.expectEqual(@as(usize, 7), m.faceCount());
    try expectClosed(&m);
    try testing.expectEqual(@as(f32, 0.25), out.width_used);
    // The chamfer runs from z = 0.75 on the front to y = -0.75 on top.
    const cf = em.faces.items[out.selected.items[0]];
    var l = cf.l;
    for (0..4) |_| {
        const p = em.verts.items[em.loops.items[l].v].co;
        try testing.expect((p[1] == -1 and p[2] == 0.75) or (p[1] == -0.75 and p[2] == 1));
        l = em.loops.items[l].next;
    }
}

test "bevelling every edge of a cube: chamfer and rounded" {
    const gpa = testing.allocator;
    var cube = try prims.generate(gpa, .cube, .{});
    defer cube.releaseRefs(gpa);
    var buf: [64]u32 = undefined;

    var em = try EditMesh.fromMesh(gpa, &cube);
    defer em.deinit();
    var out = try bevel(&em, gpa, allEdges(&em, &buf), .identity, .{ .width = 0.2 });
    defer out.deinit(gpa);
    var m = try finish(&em);
    defer m.releaseRefs(gpa);
    // 8 corners x 3 points; 6 faces + 12 strips + 8 corner triangles.
    try testing.expectEqual(@as(usize, 24), m.vertCount());
    try testing.expectEqual(@as(usize, 26), m.faceCount());
    try expectClosed(&m);

    var em2 = try EditMesh.fromMesh(gpa, &cube);
    defer em2.deinit();
    var out2 = try bevel(&em2, gpa, allEdges(&em2, &buf), .identity, .{ .width = 0.2, .segments = 4 });
    defer out2.deinit(gpa);
    var m2 = try finish(&em2);
    defer m2.releaseRefs(gpa);
    try expectClosed(&m2);
    // Every new vertex of a corner patch is 0.2 from the corner's centre
    // (0.8, 0.8, 0.8 for the +++ corner): the patch is round.
    for (em2.verts.items) |x| {
        if (x.removed) continue;
        const p = x.co;
        if (p[0] > 0.8 and p[1] > 0.8 and p[2] > 0.8) {
            try testing.expectApproxEqAbs(@as(f32, 0.2), v.length(v.sub(p, .{ 0.8, 0.8, 0.8 })), 1e-4);
        }
    }
}

test "a lone edge with segments joins its profile to the end faces" {
    const gpa = testing.allocator;
    var cube = try prims.generate(gpa, .cube, .{});
    defer cube.releaseRefs(gpa);
    var em = try EditMesh.fromMesh(gpa, &cube);
    defer em.deinit();
    var out = try bevel(&em, gpa, &.{topFrontEdge(&em)}, .identity, .{ .width = 0.3, .segments = 3 });
    defer out.deinit(gpa);
    var m = try finish(&em);
    defer m.releaseRefs(gpa);
    try testing.expectEqual(@as(usize, 3), out.selected.items.len);
    try testing.expectEqual(@as(usize, 6 + 3), m.faceCount());
    try testing.expectEqual(@as(usize, 8 - 2 + 4 + 4), m.vertCount());
    try expectClosed(&m);
}

test "bevelling the rim of a cylinder, and the width limit" {
    const gpa = testing.allocator;
    var cyl = try prims.generate(gpa, .cylinder, .{ .segments = 8 });
    defer cyl.releaseRefs(gpa);
    var em = try EditMesh.fromMesh(gpa, &cyl);
    defer em.deinit();
    var rim: std.ArrayList(u32) = .empty;
    defer rim.deinit(gpa);
    for (em.edges.items, 0..) |e, i| if (em.verts.items[e.v[0]].co[2] == 1 and em.verts.items[e.v[1]].co[2] == 1) try rim.append(gpa, @intCast(i));
    try testing.expectEqual(@as(usize, 8), rim.items.len);
    // Far too wide: the top cap's cuts would cross, so the width shrinks.
    var out = try bevel(&em, gpa, rim.items, .identity, .{ .width = 5, .segments = 2 });
    defer out.deinit(gpa);
    try testing.expect(out.width_used < 1);
    var m = try finish(&em);
    defer m.releaseRefs(gpa);
    try expectClosed(&m);
    try testing.expectEqual(@as(usize, 2 + 8 + 16), m.faceCount());
}

test "bevel refuses open or non-manifold vertices" {
    const gpa = testing.allocator;
    var plane = try prims.generate(gpa, .grid, .{ .x_subdivisions = 2, .y_subdivisions = 2 });
    defer plane.releaseRefs(gpa);
    var em = try EditMesh.fromMesh(gpa, &plane);
    defer em.deinit();
    // An interior edge of the grid ends on the boundary.
    var inner: u32 = none;
    for (em.edges.items, 0..) |_, i| if (em.edgeFaceCount(@intCast(i)) == 2) {
        inner = @intCast(i);
        break;
    };
    try testing.expectError(error.NonManifold, bevel(&em, gpa, &.{inner}, .identity, .{}));
}
