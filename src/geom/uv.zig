//! UV unwrapping (TRD §7, mesh.uv_unwrap). Faces are grouped into charts,
//! each chart is flattened with least-squares conformal maps (LSCM, Lévy et
//! al. 2002: the conformal method of Blender's Unwrap), and the charts are
//! scaled to one texel density and packed into the unit square.
//!
//! Charts end at seams and at mesh boundaries. The smart method also ends
//! a chart where a face's normal turns more than `angle_limit` from the
//! chart's first face, so any mesh unwraps without seams; the conformal
//! method follows seams alone, and a chart that closes on itself (a sphere
//! with no seam) is split as smart would split it. A vertex where a seam
//! runs through a chart gets one UV per side.
//!
//! Positions are taken in world space, so non-uniform object scale does
//! not stretch the texture.

const std = @import("std");
const math = @import("math");
const core = @import("../core/root.zig");
const Stop = @import("editmesh.zig").Stop;

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const v = math.vec;
const Mesh = core.types.Mesh;

pub const Method = enum { smart, conformal };

pub const Params = struct {
    method: Method = .smart,
    /// Smart: the largest angle between a face's normal and its chart's
    /// first face (radians).
    angle_limit: f32 = 66.0 * std.math.pi / 180.0,
    /// Gap around each chart, as a fraction of the packed square.
    margin: f32 = 0.01,
};

pub const Result = struct {
    /// One UV per corner of the mesh; corners of faces not unwrapped keep
    /// the values of `keep` (or zero).
    uvs: [][2]f32,
    charts: usize = 0,
    /// Conformal charts with no boundary, split by normal angle instead.
    closed: usize = 0,

    pub fn deinit(r: *Result, gpa: Allocator) void {
        gpa.free(r.uvs);
    }
};

pub const Error = Allocator.Error || math.DeadlineError;

const none = std.math.maxInt(u32);

const Ctx = struct {
    gpa: Allocator,
    m: *const Mesh,
    pos: []const Vec3,
    off: []const u32,
    cv: []const u32,
    ce: []const u32,
    /// Selected faces sharing each edge (CSR over edges).
    edge_start: []u32,
    edge_faces: []u32,
    normals: []Vec3,
    chart: []u32,
    stop: ?Stop,
    ticks: u32 = 0,

    fn tick(c: *Ctx) math.DeadlineError!void {
        const s = c.stop orelse return;
        c.ticks +%= 1;
        if (c.ticks % 1024 == 0 and s.deadline.passed(s.io)) return error.DeadlineExceeded;
    }

    fn facesOf(c: *const Ctx, e: u32) []const u32 {
        return c.edge_faces[c.edge_start[e]..c.edge_start[e + 1]];
    }

    /// The selected face across edge `e` from `f`, if the edge joins
    /// exactly two of them and is no seam.
    fn across(c: *const Ctx, e: u32, f: u32, seams: ?*const std.DynamicBitSetUnmanaged) ?u32 {
        if (seams) |s| if (s.isSet(e)) return null;
        const fs = c.facesOf(e);
        if (fs.len != 2) return null;
        return if (fs[0] == f) fs[1] else fs[0];
    }

    /// The corner of face `f` at vertex `x`.
    fn cornerOf(c: *const Ctx, f: u32, x: u32) u32 {
        for (c.off[f]..c.off[f + 1]) |k| if (c.cv[k] == x) return @intCast(k);
        unreachable;
    }
};

/// Unwraps `faces` (ascending) of `m`, whose world matrix is `world`.
/// `seams` marks edges (by index) to cut along; `keep` are UVs to start
/// from for corners not unwrapped.
pub fn unwrap(gpa: Allocator, m: *const Mesh, faces: []const u32, world: math.Mat4, seams: ?*const std.DynamicBitSetUnmanaged, keep: ?[]const [2]f32, stop: ?Stop, p: Params) Error!Result {
    const n_corners = m.cornerCount();
    const uvs = try gpa.alloc([2]f32, n_corners);
    errdefer gpa.free(uvs);
    if (keep) |k| @memcpy(uvs, k) else @memset(uvs, .{ 0, 0 });
    var result: Result = .{ .uvs = uvs };

    const pos = try gpa.alloc(Vec3, m.vertCount());
    defer gpa.free(pos);
    for (m.positions.slice(), pos) |q, *w| w.* = v.transformPoint(world, q);
    var c: Ctx = .{
        .gpa = gpa,
        .m = m,
        .pos = pos,
        .off = m.face_offsets.slice(),
        .cv = m.corner_verts.slice(),
        .ce = m.corner_edges.slice(),
        .edge_start = try gpa.alloc(u32, m.edgeCount() + 1),
        .edge_faces = &.{},
        .normals = try gpa.alloc(Vec3, m.faceCount()),
        .chart = try gpa.alloc(u32, m.faceCount()),
        .stop = stop,
    };
    defer gpa.free(c.edge_start);
    defer gpa.free(c.normals);
    defer gpa.free(c.chart);
    @memset(c.edge_start, 0);
    for (faces) |f| for (c.ce[c.off[f]..c.off[f + 1]]) |e| {
        c.edge_start[e + 1] += 1;
    };
    for (1..c.edge_start.len) |i| c.edge_start[i] += c.edge_start[i - 1];
    c.edge_faces = try gpa.alloc(u32, c.edge_start[c.edge_start.len - 1]);
    defer gpa.free(c.edge_faces);
    const fill = try gpa.dupe(u32, c.edge_start[0 .. c.edge_start.len - 1]);
    defer gpa.free(fill);
    for (faces) |f| for (c.ce[c.off[f]..c.off[f + 1]]) |e| {
        c.edge_faces[fill[e]] = f;
        fill[e] += 1;
    };
    for (faces) |f| c.normals[f] = v.normalize(math.triangulate.newellNormal(pos, c.cv[c.off[f]..c.off[f + 1]]));
    @memset(c.chart, none);

    // Charts, in order of their first face.
    var charts: std.ArrayList(std.ArrayList(u32)) = .empty;
    defer {
        for (charts.items) |*ch| ch.deinit(gpa);
        charts.deinit(gpa);
    }
    const cos_limit = @cos(p.angle_limit);
    for (faces) |f| {
        if (c.chart[f] != none) continue;
        var ch: std.ArrayList(u32) = .empty;
        defer ch.deinit(gpa);
        try grow(&c, f, @intCast(charts.items.len), p.method == .smart, cos_limit, seams, &ch);
        if (p.method == .smart or try hasBoundary(&c, ch.items, seams)) {
            try charts.append(gpa, ch);
            ch = .empty;
            continue;
        }
        // A closed chart cannot be flattened: split it by angle instead.
        result.closed += 1;
        for (ch.items) |g| c.chart[g] = none;
        for (ch.items) |g| {
            if (c.chart[g] != none) continue;
            var sub: std.ArrayList(u32) = .empty;
            errdefer sub.deinit(gpa);
            try grow(&c, g, @intCast(charts.items.len), true, cos_limit, seams, &sub);
            try charts.append(gpa, sub);
        }
    }
    result.charts = charts.items.len;

    // Flatten each chart, then pack.
    var placed: std.ArrayList(Placed) = .empty;
    defer {
        for (placed.items) |*x| x.deinit(gpa);
        placed.deinit(gpa);
    }
    for (charts.items) |ch| try placed.append(gpa, try flatten(&c, ch.items, seams));
    try pack(gpa, placed.items, p.margin);
    for (placed.items) |pl| for (pl.corners, pl.slot) |corner, s| {
        uvs[corner] = .{ @floatCast(pl.uv[s][0]), @floatCast(pl.uv[s][1]) };
    };
    return result;
}

/// Floods chart `id` from face `seed` across non-seam manifold edges
/// (within the angle limit of the seed's normal when `by_angle`).
fn grow(c: *Ctx, seed: u32, id: u32, by_angle: bool, cos_limit: f32, seams: ?*const std.DynamicBitSetUnmanaged, out: *std.ArrayList(u32)) Error!void {
    const n0 = c.normals[seed];
    c.chart[seed] = id;
    try out.append(c.gpa, seed);
    var i: usize = 0;
    while (i < out.items.len) : (i += 1) {
        try c.tick();
        const f = out.items[i];
        for (c.ce[c.off[f]..c.off[f + 1]]) |e| {
            const g = c.across(e, f, seams) orelse continue;
            if (c.chart[g] != none) continue;
            if (by_angle and v.dot(c.normals[g], n0) < cos_limit) continue;
            c.chart[g] = id;
            try out.append(c.gpa, g);
        }
    }
}

fn hasBoundary(c: *Ctx, faces: []const u32, seams: ?*const std.DynamicBitSetUnmanaged) Error!bool {
    for (faces) |f| for (c.ce[c.off[f]..c.off[f + 1]]) |e| {
        if (c.across(e, f, seams) == null) return true;
    };
    return false;
}

/// A flattened chart: one UV per slot (a group of corners that share a
/// vertex and are joined inside the chart), and each corner's slot.
const Placed = struct {
    corners: []u32,
    slot: []u32,
    uv: [][2]f64,
    /// Surface area, and the area of the flattened chart.
    area3: f64,
    area2: f64,
    lo: [2]f64 = .{ 0, 0 },
    hi: [2]f64 = .{ 0, 0 },

    fn deinit(pl: *Placed, gpa: Allocator) void {
        gpa.free(pl.corners);
        gpa.free(pl.slot);
        gpa.free(pl.uv);
    }
};

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

const Tri = struct { s: [3]u32, c: [3][2]f64 };

fn flatten(c: *Ctx, faces: []const u32, seams: ?*const std.DynamicBitSetUnmanaged) Error!Placed {
    const gpa = c.gpa;
    // Corners of the chart, and union-find joining corners at the same
    // vertex across chart-internal edges.
    var corners: std.ArrayList(u32) = .empty;
    errdefer corners.deinit(gpa);
    var local: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer local.deinit(gpa);
    for (faces) |f| for (c.off[f]..c.off[f + 1]) |k| {
        try local.put(gpa, @intCast(k), @intCast(corners.items.len));
        try corners.append(gpa, @intCast(k));
    };
    const parent = try gpa.alloc(u32, corners.items.len);
    defer gpa.free(parent);
    for (parent, 0..) |*q, i| q.* = @intCast(i);
    for (faces) |f| for (c.off[f]..c.off[f + 1]) |k| {
        const e = c.ce[k];
        const g = c.across(e, f, seams) orelse continue;
        if (g < f or c.chart[g] != c.chart[f]) continue;
        const ends = c.m.edges.slice()[e];
        for (ends) |x| {
            const a = find(parent, local.get(c.cornerOf(f, x)).?);
            const b = find(parent, local.get(c.cornerOf(g, x)).?);
            if (a != b) parent[@max(a, b)] = @min(a, b);
        }
    };
    const slot = try gpa.alloc(u32, corners.items.len);
    errdefer gpa.free(slot);
    var n_slots: u32 = 0;
    const slot_of_root = try gpa.alloc(u32, corners.items.len);
    defer gpa.free(slot_of_root);
    @memset(slot_of_root, none);
    for (0..corners.items.len) |i| {
        const r = find(parent, @intCast(i));
        if (slot_of_root[r] == none) {
            slot_of_root[r] = n_slots;
            n_slots += 1;
        }
        slot[i] = slot_of_root[r];
    }
    // World position per slot.
    const sp = try gpa.alloc(Vec3, n_slots);
    defer gpa.free(sp);
    for (corners.items, slot) |k, s| sp[s] = c.pos[c.cv[k]];

    // Triangles in each triangle's own orthonormal frame.
    var tris: std.ArrayList(Tri) = .empty;
    defer tris.deinit(gpa);
    var flat: std.ArrayList(u32) = .empty;
    defer flat.deinit(gpa);
    var area3: f64 = 0;
    var normal: Vec3 = .{ 0, 0, 0 };
    for (faces) |f| {
        try c.tick();
        const start = c.off[f];
        flat.clearRetainingCapacity();
        try math.triangulate.triangulate(gpa, c.pos, c.cv[start..c.off[f + 1]], &flat);
        normal = v.add(normal, c.normals[f]);
        var i: usize = 0;
        while (i + 2 < flat.items.len) : (i += 3) {
            var t: Tri = undefined;
            var q: [3]Vec3 = undefined;
            for (0..3) |j| {
                const k = start + flat.items[i + j];
                t.s[j] = slot[local.get(k).?];
                q[j] = c.pos[c.cv[k]];
            }
            const e1 = v.sub(q[1], q[0]);
            const e2 = v.sub(q[2], q[0]);
            const l1 = v.length(e1);
            const nrm = v.cross(e1, e2);
            const twice = v.length(nrm);
            if (l1 < 1e-12 or twice < 1e-12) continue;
            const x = v.scale(e1, 1 / l1);
            const y = v.normalize(v.cross(nrm, e1));
            t.c = .{ .{ 0, 0 }, .{ l1, 0 }, .{ v.dot(e2, x), v.dot(e2, y) } };
            area3 += twice / 2;
            try tris.append(gpa, t);
        }
    }

    // Start from the projection onto the chart's mean plane; pin the two
    // slots farthest apart along its longer extent.
    const nrm = if (v.length(normal) > 1e-9) v.normalize(normal) else Vec3{ 0, 0, 1 };
    const tu = v.normalize(if (@abs(nrm[0]) < 0.9) v.cross(nrm, .{ 1, 0, 0 }) else v.cross(nrm, .{ 0, 1, 0 }));
    const tv = v.cross(nrm, tu);
    const uv = try gpa.alloc([2]f64, n_slots);
    errdefer gpa.free(uv);
    for (sp, uv) |q, *w| w.* = .{ v.dot(q, tu), v.dot(q, tv) };
    var lo = uv[0];
    var hi = uv[0];
    var arg_lo: [2]u32 = .{ 0, 0 };
    var arg_hi: [2]u32 = .{ 0, 0 };
    for (uv, 0..) |w, i| for (0..2) |k| {
        if (w[k] < lo[k]) {
            lo[k] = w[k];
            arg_lo[k] = @intCast(i);
        }
        if (w[k] > hi[k]) {
            hi[k] = w[k];
            arg_hi[k] = @intCast(i);
        }
    };
    const axis: usize = if (hi[0] - lo[0] >= hi[1] - lo[1]) 0 else 1;
    const pins = [2]u32{ arg_lo[axis], arg_hi[axis] };
    if (pins[0] != pins[1] and tris.items.len > 0) try lscm(c, tris.items, uv, pins);

    // Unmirror: the chart must keep the faces' winding.
    var signed: f64 = 0;
    for (tris.items) |t| {
        const a = uv[t.s[0]];
        const b = uv[t.s[1]];
        const d = uv[t.s[2]];
        signed += (b[0] - a[0]) * (d[1] - a[1]) - (d[0] - a[0]) * (b[1] - a[1]);
    }
    if (signed < 0) for (uv) |*w| {
        w[0] = -w[0];
    };
    return .{ .corners = try corners.toOwnedSlice(gpa), .slot = slot, .uv = uv, .area3 = area3, .area2 = @abs(signed) / 2 };
}

/// Minimises the conformal energy Σ |Σ_j W_j (u_j + i v_j)|² / 2A over the
/// chart's triangles with the two pinned slots fixed. The normal equations
/// M x = b (M = AᵀA over the free slots, u and v interleaved) are
/// assembled once and solved by conjugate gradients preconditioned with an
/// incomplete Cholesky factor of M (IC(0), on M's own sparsity), from the
/// projection in `uv`, which receives the result. The residual stops at
/// 1e-6 of the right-hand side, far below a texel. Plain CG needed several
/// times more iterations on large curved charts; a sparse direct solver
/// (nested-dissection Cholesky) would be faster still and is the next step.
fn lscm(c: *Ctx, tris: []const Tri, uv: [][2]f64, pins: [2]u32) Error!void {
    const gpa = c.gpa;
    const n = uv.len;
    // Per triangle: the complex coefficients W_j / sqrt(2A).
    const coef = try gpa.alloc([3][2]f64, tris.len);
    defer gpa.free(coef);
    for (tris, coef) |t, *w| {
        const q = t.c;
        const twice = q[1][0] * q[2][1] - q[2][0] * q[1][1];
        const s = 1 / @sqrt(@abs(twice));
        for (0..3) |j| {
            const a = q[(j + 1) % 3];
            const b = q[(j + 2) % 3];
            w[j] = .{ (b[0] - a[0]) * s, (b[1] - a[1]) * s };
        }
    }
    // Free slots get consecutive indices; the system has two rows each.
    const none_: u32 = std.math.maxInt(u32);
    const free = try gpa.alloc(u32, n);
    defer gpa.free(free);
    var nf: u32 = 0;
    for (free, 0..) |*f, i| {
        if (i == pins[0] or i == pins[1]) {
            f.* = none_;
        } else {
            f.* = nf;
            nf += 1;
        }
    }
    if (nf == 0) return;
    var m = try Sparse.assemble(gpa, tris, coef, free, nf);
    defer m.deinit(gpa);

    // Right-hand side from the pinned slots: b = -M_fp x_p.
    const dim = 2 * @as(usize, nf);
    const b = try gpa.alloc(f64, dim);
    defer gpa.free(b);
    @memset(b, 0);
    for (tris, coef) |t, w| for (0..3) |j| {
        const fj = free[t.s[j]];
        if (fj == none_) continue;
        for (0..3) |k| {
            if (free[t.s[k]] != none_) continue;
            const blk = block(w[j], w[k]);
            const xu = uv[t.s[k]][0];
            const xv = uv[t.s[k]][1];
            b[2 * fj] -= blk[0] * xu + blk[1] * xv;
            b[2 * fj + 1] -= -blk[1] * xu + blk[0] * xv;
        }
    };

    const x = try gpa.alloc(f64, dim);
    defer gpa.free(x);
    for (free, 0..) |f, i| if (f != none_) {
        x[2 * f] = uv[i][0];
        x[2 * f + 1] = uv[i][1];
    };
    var l = try m.incompleteCholesky(gpa);
    defer l.deinit(gpa);

    const r = try gpa.alloc(f64, dim);
    defer gpa.free(r);
    const z = try gpa.alloc(f64, dim);
    defer gpa.free(z);
    const p = try gpa.alloc(f64, dim);
    defer gpa.free(p);
    const q = try gpa.alloc(f64, dim);
    defer gpa.free(q);
    m.mul(x, r);
    for (r, b) |*ri, bi| ri.* = bi - ri.*;
    const b_norm = @sqrt(dot(b, b)) + @sqrt(dot(x, x)) * 1e-30;
    l.solve(r, z);
    @memcpy(p, z);
    var rz = dot(r, z);
    const max_iter = 50 + 4 * std.math.sqrt(dim);
    var it: usize = 0;
    while (it < max_iter) : (it += 1) {
        try c.tick();
        if (@sqrt(dot(r, r)) <= 1e-6 * @max(b_norm, 1e-300)) break;
        m.mul(p, q);
        const pq = dot(p, q);
        if (pq <= 0) break;
        const alpha = rz / pq;
        for (x, p) |*xi, pi| xi.* += alpha * pi;
        for (r, q) |*ri, qi| ri.* -= alpha * qi;
        l.solve(r, z);
        const rz2 = dot(r, z);
        const beta = rz2 / rz;
        rz = rz2;
        for (p, z) |*pi, zi| pi.* = zi + beta * pi.*;
    }
    for (free, 0..) |f, i| if (f != none_) {
        uv[i] = .{ x[2 * f], x[2 * f + 1] };
    };
}

/// The 2x2 block of AᵀA coupling slots j and k: [[a, b], [-b, a]], from
/// their complex coefficients.
fn block(cj: [2]f64, ck: [2]f64) [2]f64 {
    return .{ cj[0] * ck[0] + cj[1] * ck[1], cj[1] * ck[0] - cj[0] * ck[1] };
}

/// A symmetric matrix as its lower triangle in compressed rows, columns
/// ascending, the diagonal last in each row.
const Sparse = struct {
    start: []u32,
    col: []u32,
    val: []f64,

    fn deinit(m: *Sparse, gpa: Allocator) void {
        gpa.free(m.start);
        gpa.free(m.col);
        gpa.free(m.val);
    }

    fn assemble(gpa: Allocator, tris: []const Tri, coef: []const [3][2]f64, free: []const u32, nf: u32) Allocator.Error!Sparse {
        const none_: u32 = std.math.maxInt(u32);
        const dim = 2 * @as(usize, nf);
        // Slot pairs that share a triangle, lower triangle (J >= K).
        var pairs: std.ArrayList(u64) = .empty;
        defer pairs.deinit(gpa);
        for (tris) |t| for (0..3) |j| for (0..3) |k| {
            const fj = free[t.s[j]];
            const fk = free[t.s[k]];
            if (fj == none_ or fk == none_ or fj < fk) continue;
            try pairs.append(gpa, @as(u64, fj) << 32 | fk);
        };
        std.mem.sort(u64, pairs.items, {}, std.sort.asc(u64));
        var u: usize = 0;
        for (pairs.items) |x| {
            if (u > 0 and pairs.items[u - 1] == x) continue;
            pairs.items[u] = x;
            u += 1;
        }
        pairs.items.len = u;
        // Entries per row of the 2nf system: a block pair (J > K) gives
        // two entries to each of rows 2J and 2J+1; a diagonal block gives
        // (2J, 2J) and (2J+1, 2J), (2J+1, 2J+1).
        const start = try gpa.alloc(u32, dim + 1);
        errdefer gpa.free(start);
        @memset(start, 0);
        for (pairs.items) |x| {
            const jj: usize = @intCast(x >> 32);
            const kk: usize = @intCast(x & 0xffffffff);
            if (jj == kk) {
                start[2 * jj + 1] += 1;
                start[2 * jj + 2] += 2;
            } else {
                start[2 * jj + 1] += 2;
                start[2 * jj + 2] += 2;
            }
        }
        for (1..start.len) |i| start[i] += start[i - 1];
        const nnz = start[dim];
        const col = try gpa.alloc(u32, nnz);
        errdefer gpa.free(col);
        const val = try gpa.alloc(f64, nnz);
        errdefer gpa.free(val);
        @memset(val, 0);
        const fill = try gpa.dupe(u32, start[0..dim]);
        defer gpa.free(fill);
        // Pairs are sorted by (J, K), so columns come out ascending.
        for (pairs.items) |x| {
            const jj: u32 = @intCast(x >> 32);
            const kk: u32 = @intCast(x & 0xffffffff);
            if (jj == kk) {
                col[fill[2 * jj]] = 2 * jj;
                fill[2 * jj] += 1;
                col[fill[2 * jj + 1]] = 2 * jj;
                col[fill[2 * jj + 1] + 1] = 2 * jj + 1;
                fill[2 * jj + 1] += 2;
            } else {
                for ([2]u32{ 2 * jj, 2 * jj + 1 }) |row| {
                    col[fill[row]] = 2 * kk;
                    col[fill[row] + 1] = 2 * kk + 1;
                    fill[row] += 2;
                }
            }
        }
        var m: Sparse = .{ .start = start, .col = col, .val = val };
        for (tris, coef) |t, w| for (0..3) |j| for (0..3) |k| {
            const fj = free[t.s[j]];
            const fk = free[t.s[k]];
            if (fj == none_ or fk == none_ or fj < fk) continue;
            const blk = block(w[j], w[k]);
            if (fj == fk) {
                m.add(2 * fj, 2 * fj, blk[0]);
                m.add(2 * fj + 1, 2 * fj + 1, blk[0]);
            } else {
                m.add(2 * fj, 2 * fk, blk[0]);
                m.add(2 * fj, 2 * fk + 1, blk[1]);
                m.add(2 * fj + 1, 2 * fk, -blk[1]);
                m.add(2 * fj + 1, 2 * fk + 1, blk[0]);
            }
        };
        return m;
    }

    fn find(m: *const Sparse, row: usize, c: u32) usize {
        const cols = m.col[m.start[row]..m.start[row + 1]];
        var lo: usize = 0;
        var hi: usize = cols.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (cols[mid] < c) lo = mid + 1 else hi = mid;
        }
        return m.start[row] + lo;
    }

    fn add(m: *Sparse, row: usize, c: u32, x: f64) void {
        m.val[m.find(row, c)] += x;
    }

    /// y = M x, with M symmetric and stored as its lower triangle.
    fn mul(m: *const Sparse, x: []const f64, y: []f64) void {
        @memset(y, 0);
        for (0..y.len) |i| {
            for (m.start[i]..m.start[i + 1]) |e| {
                const j = m.col[e];
                y[i] += m.val[e] * x[j];
                if (j != i) y[j] += m.val[e] * x[i];
            }
        }
    }

    /// IC(0): L with L Lᵀ ≈ M on M's sparsity. A pivot that is not positive
    /// restarts the factorisation with the diagonal raised a little.
    fn incompleteCholesky(m: *const Sparse, gpa: Allocator) Allocator.Error!Sparse {
        const dim = m.start.len - 1;
        var l: Sparse = .{ .start = try gpa.dupe(u32, m.start), .col = try gpa.dupe(u32, m.col), .val = try gpa.alloc(f64, m.val.len) };
        errdefer l.deinit(gpa);
        var shift: f64 = 0;
        attempt: while (true) {
            @memcpy(l.val, m.val);
            for (0..dim) |i| l.val[l.start[i + 1] - 1] *= 1 + shift;
            for (0..dim) |i| {
                const ri = l.start[i];
                const re = l.start[i + 1];
                for (ri..re) |e| {
                    const k = l.col[e];
                    // Σ_m L_im L_km over the columns both rows hold, m < k.
                    var sum: f64 = 0;
                    var a = ri;
                    var bpos: usize = l.start[k];
                    const bend = l.start[k + 1] - 1;
                    while (a < e and bpos < bend) {
                        const ca = l.col[a];
                        const cb = l.col[bpos];
                        if (ca == cb) {
                            sum += l.val[a] * l.val[bpos];
                            a += 1;
                            bpos += 1;
                        } else if (ca < cb) a += 1 else bpos += 1;
                    }
                    if (k == i) {
                        const d = l.val[e] - sum;
                        if (!(d > 0)) {
                            shift = if (shift == 0) 1e-3 else shift * 10;
                            continue :attempt;
                        }
                        l.val[e] = @sqrt(d);
                    } else {
                        l.val[e] = (l.val[e] - sum) / l.val[l.start[k + 1] - 1];
                    }
                }
            }
            return l;
        }
    }

    /// z = (L Lᵀ)⁻¹ r.
    fn solve(l: *const Sparse, r: []const f64, z: []f64) void {
        const dim = z.len;
        for (0..dim) |i| {
            var s = r[i];
            const diag = l.start[i + 1] - 1;
            for (l.start[i]..diag) |e| s -= l.val[e] * z[l.col[e]];
            z[i] = s / l.val[diag];
        }
        var i = dim;
        while (i > 0) {
            i -= 1;
            const diag = l.start[i + 1] - 1;
            z[i] /= l.val[diag];
            for (l.start[i]..diag) |e| z[l.col[e]] -= l.val[e] * z[i];
        }
    }
};

fn dot(a: []const f64, b: []const f64) f64 {
    var t: f64 = 0;
    for (a, b) |x, y| t += x * y;
    return t;
}

/// Scales every chart to its 3D area, turns it to its smallest bounding
/// box (lying flat), packs the boxes in shelves, tallest first, and fits
/// the whole into the unit square.
fn pack(gpa: Allocator, charts: []Placed, margin: f32) Allocator.Error!void {
    if (charts.len == 0) return;
    var total: f64 = 0;
    for (charts) |*ch| {
        const s = if (ch.area2 > 1e-30) @sqrt(ch.area3 / ch.area2) else 1;
        for (ch.uv) |*w| w.* = .{ w[0] * s, w[1] * s };
        try rotateToBestBox(gpa, ch);
        total += (ch.hi[0] - ch.lo[0]) * (ch.hi[1] - ch.lo[1]);
    }
    const gap = @as(f64, margin) * @sqrt(@max(total, 1e-30)) * 2;
    const order = try gpa.alloc(u32, charts.len);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.sort.block(u32, order, charts, struct {
        fn lt(cs: []Placed, a: u32, b: u32) bool {
            return cs[a].hi[1] - cs[a].lo[1] > cs[b].hi[1] - cs[b].lo[1];
        }
    }.lt);
    // Try a range of shelf widths and keep the squarest layout.
    var widest: f64 = 0;
    var sum_w: f64 = 0;
    for (charts) |ch| {
        widest = @max(widest, ch.hi[0] - ch.lo[0]);
        sum_w += ch.hi[0] - ch.lo[0] + gap;
    }
    var best_width = widest;
    var best_side = std.math.inf(f64);
    for (0..33) |k| {
        const t = @as(f64, @floatFromInt(k)) / 32;
        const width = widest + (sum_w - widest) * t * t;
        const e = shelves(charts, order, width, gap, false);
        if (@max(e[0], e[1]) < best_side * (1 - 1e-9)) {
            best_side = @max(e[0], e[1]);
            best_width = width;
        }
    }
    const extent = shelves(charts, order, best_width, gap, true);
    const s = 1 / @max(extent[0], extent[1]);
    for (charts) |*ch| for (ch.uv) |*u| {
        u.* = .{ u[0] * s, u[1] * s };
    };
}

/// Lays the charts in `order` into shelves `row_width` wide and returns
/// the extent; moves them only when `place`.
fn shelves(charts: []Placed, order: []const u32, row_width: f64, gap: f64, place: bool) [2]f64 {
    var x: f64 = gap;
    var y: f64 = gap;
    var row_h: f64 = 0;
    var extent: [2]f64 = .{ 0, 0 };
    for (order) |i| {
        const ch = &charts[i];
        const w = ch.hi[0] - ch.lo[0];
        const h = ch.hi[1] - ch.lo[1];
        if (x > gap and x + w > row_width + gap) {
            x = gap;
            y += row_h + gap;
            row_h = 0;
        }
        if (place) {
            const dx = x - ch.lo[0];
            const dy = y - ch.lo[1];
            for (ch.uv) |*u| u.* = .{ u[0] + dx, u[1] + dy };
        }
        x += w + gap;
        row_h = @max(row_h, h);
        extent = .{ @max(extent[0], x), @max(extent[1], y + h + gap) };
    }
    return extent;
}

fn bounds(ch: *Placed) void {
    ch.lo = ch.uv[0];
    ch.hi = ch.uv[0];
    for (ch.uv) |w| for (0..2) |k| {
        ch.lo[k] = @min(ch.lo[k], w[k]);
        ch.hi[k] = @max(ch.hi[k], w[k]);
    };
}

/// Turns the chart to its smallest bounding box, then lays it so the box
/// is wider than tall. The smallest box has a side along an edge of the
/// convex hull, so each hull edge's direction is tried.
fn rotateToBestBox(gpa: Allocator, ch: *Placed) Allocator.Error!void {
    const hull = try convexHull(gpa, ch.uv);
    defer gpa.free(hull);
    var best: f64 = std.math.inf(f64);
    var best_dir: [2]f64 = .{ 1, 0 };
    // Very round charts have long hulls; every other edge is near enough.
    const step = @max(1, hull.len / 256);
    var i: usize = 0;
    while (i < hull.len) : (i += step) {
        const a = hull[i];
        const b = hull[(i + 1) % hull.len];
        const len = @sqrt((b[0] - a[0]) * (b[0] - a[0]) + (b[1] - a[1]) * (b[1] - a[1]));
        if (len < 1e-30) continue;
        const d = [2]f64{ (b[0] - a[0]) / len, (b[1] - a[1]) / len };
        var lo: [2]f64 = .{ std.math.inf(f64), std.math.inf(f64) };
        var hi: [2]f64 = .{ -std.math.inf(f64), -std.math.inf(f64) };
        for (hull) |p| {
            const r = [2]f64{ d[0] * p[0] + d[1] * p[1], -d[1] * p[0] + d[0] * p[1] };
            for (0..2) |k| {
                lo[k] = @min(lo[k], r[k]);
                hi[k] = @max(hi[k], r[k]);
            }
        }
        const area = (hi[0] - lo[0]) * (hi[1] - lo[1]);
        if (area < best * (1 - 1e-9)) {
            best = area;
            best_dir = d;
        }
    }
    // Each new pair is built before it is stored: `w.* = .{ f(w), g(w) }`
    // would write w[0] before g reads it.
    const d = best_dir;
    for (ch.uv) |*w| {
        const r = [2]f64{ d[0] * w[0] + d[1] * w[1], -d[1] * w[0] + d[0] * w[1] };
        w.* = r;
    }
    bounds(ch);
    if (ch.hi[1] - ch.lo[1] > ch.hi[0] - ch.lo[0]) {
        for (ch.uv) |*w| {
            const r = [2]f64{ -w[1], w[0] };
            w.* = r;
        }
        bounds(ch);
    }
}

/// Andrew's monotone chain; counter-clockwise, without repeated points.
fn convexHull(gpa: Allocator, pts: []const [2]f64) Allocator.Error![][2]f64 {
    const sorted = try gpa.dupe([2]f64, pts);
    defer gpa.free(sorted);
    std.mem.sort([2]f64, sorted, {}, struct {
        fn lt(_: void, a: [2]f64, b: [2]f64) bool {
            return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
        }
    }.lt);
    const hull = try gpa.alloc([2]f64, 2 * sorted.len + 1);
    errdefer gpa.free(hull);
    var k: usize = 0;
    const turn = struct {
        fn f(o: [2]f64, a: [2]f64, b: [2]f64) f64 {
            return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
        }
    }.f;
    for (sorted) |p| {
        while (k >= 2 and turn(hull[k - 2], hull[k - 1], p) <= 0) k -= 1;
        hull[k] = p;
        k += 1;
    }
    const lower = k + 1;
    var i = sorted.len;
    while (i > 1) {
        i -= 1;
        const p = sorted[i - 1];
        while (k >= lower and turn(hull[k - 2], hull[k - 1], p) <= 0) k -= 1;
        hull[k] = p;
        k += 1;
    }
    const n = if (k > 1) k - 1 else k;
    return gpa.realloc(hull, n);
}

const testing = std.testing;
const prims = @import("primitives.zig");

fn faceUvArea(m: *const Mesh, uvs: []const [2]f32, f: usize) f64 {
    const off = m.face_offsets.slice();
    var a: f64 = 0;
    for (off[f]..off[f + 1]) |k| {
        const p = uvs[k];
        const q = uvs[if (k + 1 == off[f + 1]) off[f] else k + 1];
        a += @as(f64, p[0]) * q[1] - @as(f64, q[0]) * p[1];
    }
    return a / 2;
}

fn allFaces(m: *const Mesh, buf: []u32) []u32 {
    for (buf[0..m.faceCount()], 0..) |*x, i| x.* = @intCast(i);
    return buf[0..m.faceCount()];
}

test "smart unwrap of a cube: six equal, separate, upright squares" {
    const gpa = testing.allocator;
    var m = try prims.generate(gpa, .cube, .{});
    defer m.releaseRefs(gpa);
    var buf: [6]u32 = undefined;
    var r = try unwrap(gpa, &m, allFaces(&m, &buf), v.identity, null, null, null, .{});
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 6), r.charts);
    for (r.uvs) |w| for (w) |x| try testing.expect(x >= 0 and x <= 1);
    const a0 = faceUvArea(&m, r.uvs, 0);
    try testing.expect(a0 > 0.05);
    for (0..6) |f| try testing.expectApproxEqRel(a0, faceUvArea(&m, r.uvs, f), 1e-4);
    // Boxes do not overlap.
    const off = m.face_offsets.slice();
    var boxes: [6][2][2]f32 = undefined;
    for (0..6) |f| {
        boxes[f] = .{ r.uvs[off[f]], r.uvs[off[f]] };
        for (off[f]..off[f + 1]) |k| for (0..2) |d| {
            boxes[f][0][d] = @min(boxes[f][0][d], r.uvs[k][d]);
            boxes[f][1][d] = @max(boxes[f][1][d], r.uvs[k][d]);
        };
    }
    for (0..6) |i| for (i + 1..6) |j| {
        const apart = boxes[i][1][0] <= boxes[j][0][0] or boxes[j][1][0] <= boxes[i][0][0] or
            boxes[i][1][1] <= boxes[j][0][1] or boxes[j][1][1] <= boxes[i][0][1];
        try testing.expect(apart);
    };
}

test "conformal unwrap keeps a flat grid's squares square" {
    const gpa = testing.allocator;
    var m = try prims.generate(gpa, .grid, .{ .x_subdivisions = 4, .y_subdivisions = 3 });
    defer m.releaseRefs(gpa);
    var buf: [12]u32 = undefined;
    // A non-uniform object scale is measured in world space.
    const world = v.compose(.{ 0, 0, 0 }, v.quat_identity, .{ 2, 1, 1 });
    var r = try unwrap(gpa, &m, allFaces(&m, &buf), world, null, null, null, .{ .method = .conformal });
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), r.charts);
    const off = m.face_offsets.slice();
    // Each face is 1 x 0.667 m in the world: the same shape in UV.
    for (0..m.faceCount()) |f| {
        const c = r.uvs[off[f]..off[f + 1]];
        const e0 = @sqrt(std.math.pow(f32, c[1][0] - c[0][0], 2) + std.math.pow(f32, c[1][1] - c[0][1], 2));
        const e1 = @sqrt(std.math.pow(f32, c[2][0] - c[1][0], 2) + std.math.pow(f32, c[2][1] - c[1][1], 2));
        const ratio = @max(e0, e1) / @min(e0, e1);
        try testing.expectApproxEqAbs(@as(f32, 1.5), ratio, 1e-3);
        try testing.expect(faceUvArea(&m, r.uvs, f) > 0);
    }
}

test "conformal unwrap of a seamed cylinder unrolls its side" {
    const gpa = testing.allocator;
    var m = try prims.generate(gpa, .cylinder, .{ .segments = 32 });
    defer m.releaseRefs(gpa);
    var seams = try std.DynamicBitSetUnmanaged.initEmpty(gpa, m.edgeCount());
    defer seams.deinit(gpa);
    const pos = m.positions.slice();
    var vertical_seam = false;
    for (m.edges.slice(), 0..) |e, i| {
        const a = pos[e[0]];
        const b = pos[e[1]];
        if (a[2] == b[2]) seams.set(i) // rims
        else if (!vertical_seam) {
            seams.set(i);
            vertical_seam = true;
        }
    }
    var buf: [34]u32 = undefined;
    var r = try unwrap(gpa, &m, allFaces(&m, &buf), v.identity, &seams, null, null, .{ .method = .conformal });
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), r.charts);
    try testing.expectEqual(@as(usize, 0), r.closed);
    var lo: [2]f32 = .{ 1, 1 };
    var hi: [2]f32 = .{ 0, 0 };
    const off = m.face_offsets.slice();
    for (0..m.faceCount()) |f| if (off[f + 1] - off[f] == 4) for (r.uvs[off[f]..off[f + 1]]) |w| for (0..2) |d| {
        lo[d] = @min(lo[d], w[d]);
        hi[d] = @max(hi[d], w[d]);
    };
    // Perimeter 64 sin(π/32) = 6.273 over a height of 2.
    try testing.expectApproxEqRel(@as(f32, 3.1365), (hi[0] - lo[0]) / (hi[1] - lo[1]), 1e-3);
}

test "a closed chart is split, and corners outside the selection keep their UVs" {
    const gpa = testing.allocator;
    var m = try prims.generate(gpa, .uv_sphere, .{ .segments = 12, .rings = 6 });
    defer m.releaseRefs(gpa);
    var buf: [72]u32 = undefined;
    const keep = try gpa.alloc([2]f32, m.cornerCount());
    defer gpa.free(keep);
    @memset(keep, .{ 7, 7 });
    const faces = allFaces(&m, &buf);
    var r = try unwrap(gpa, &m, faces[0 .. faces.len - 1], v.identity, null, keep, null, .{ .method = .conformal });
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), r.closed);
    // The whole sphere has no boundary until a face is left out.
    var r2 = try unwrap(gpa, &m, faces, v.identity, null, null, null, .{ .method = .conformal });
    defer r2.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), r2.closed);
    try testing.expect(r2.charts > 1);
    const off = m.face_offsets.slice();
    try testing.expectEqual([2]f32{ 7, 7 }, r.uvs[off[faces.len - 1]]);
}
