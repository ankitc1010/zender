//! Implicit modelling for mesh.from_sdf: a program of signed-distance
//! shapes combined with smooth booleans, sampled on a voxel grid and turned
//! into quads with surface nets. Distances are negative inside.
//!
//! Each step touches only the cells near its shape (its bounds grown by the
//! blend radius and a margin), so thousands of small shapes, such as the
//! capsules of a lock of hair, cost about as much as one large one. Values
//! far from every surface can be larger than the true distance; only their
//! signs and the values near a surface reach the mesher. Every cell is
//! computed on its own, so the mesh does not depend on the thread count.

const std = @import("std");
const math = @import("math");
const core = @import("../core/root.zig");
const build = @import("build.zig");
const smooth_op = @import("ops/smooth.zig");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const v = math.vec;
const Mesh = core.types.Mesh;

pub const Kind = union(enum) {
    sphere: struct { radius: f32 },
    ellipsoid: struct { radii: Vec3 },
    /// Half extents; `round` rounds the edges without growing the box.
    box: struct { half: Vec3, round: f32 = 0 },
    /// From a to b, the radius going linearly from ra to rb.
    capsule: struct { a: Vec3, b: Vec3, ra: f32, rb: f32 },
    /// Around local Z; sx and sy stretch the ring into an ellipse.
    torus: struct { major: f32, minor: f32, sx: f32 = 1, sy: f32 = 1 },
    /// Along local Z.
    cylinder: struct { radius: f32, half_height: f32 },
    /// Everything below the plane through the local origin with this normal.
    half_space: struct { normal: Vec3 },
    /// Capsules between consecutive points, a radius per point.
    chain: struct { points: []const Vec3, radii: []const f32 },
};

pub const Shape = struct {
    kind: Kind,
    location: Vec3 = .{ 0, 0, 0 },
    /// Euler XYZ, radians.
    rotation: Vec3 = .{ 0, 0, 0 },
    /// Uniform, so distances stay distances.
    scale: f32 = 1,
    /// Also add the copy mirrored across the YZ plane.
    mirror_x: bool = false,
};

pub const Op = enum { add, subtract, intersect };

pub const Step = struct {
    op: Op = .add,
    /// Smooth-blend radius (m); 0 = a hard boolean.
    blend: f32 = 0,
    /// Grow (positive) or shrink the shape by this distance (m).
    offset: f32 = 0,
    /// Material slot of the surface this step contributes.
    slot: ?u8 = null,
    /// Push the shape's surface out by amount x (texture - 0.5), the
    /// texture read at the program-space point.
    displace: ?*const math.texture.Recipe = null,
    displace_amount: f32 = 0,
    body: union(enum) { shape: Shape, group: []const Step },
};

pub const Options = struct {
    voxel: f32,
    /// World box to sample; null = the bounds of the added shapes.
    bounds: ?[2]Vec3 = null,
    max_cells: u64 = 64 << 20,
    /// Taubin passes after meshing; 0 = none.
    smooth_iterations: u32 = 0,
    pool: ?math.Pool = null,
    /// Tests only: evaluate chains segment by segment in every cell.
    naive_chains: bool = false,
};

pub const Error = Allocator.Error || math.DeadlineError || build.BuildError || error{ TooManyCells, Unbounded, InvalidParameter, Empty };

const big: f32 = 1e6;

pub fn smin(a: f32, b: f32, k: f32) f32 {
    // Apart by the blend radius or more, the blend is the plain minimum;
    // returning it directly also keeps small values exact next to the 1e6
    // placeholder, where b + (a - b) would round them away in f32.
    if (k <= 0 or @abs(a - b) >= k) return @min(a, b);
    const h = 0.5 + 0.5 * (b - a) / k;
    return b + (a - b) * h - k * h * (1 - h);
}

pub fn smax(a: f32, b: f32, k: f32) f32 {
    return -smin(-a, -b, k);
}

fn len2(x: f32, y: f32) f32 {
    return @sqrt(x * x + y * y);
}

/// Distance to one segment of a chain or a capsule.
fn capsuleDist(p: Vec3, a: Vec3, b: Vec3, ra: f32, rb: f32) f32 {
    const pa = v.sub(p, a);
    const ba = v.sub(b, a);
    const bb = v.dot(ba, ba);
    const h = if (bb > 0) std.math.clamp(v.dot(pa, ba) / bb, 0, 1) else 0;
    return v.length(v.sub(pa, v.scale(ba, h))) - (ra + (rb - ra) * h);
}

/// Distance in the shape's own frame.
fn localDist(k: Kind, p: Vec3) f32 {
    return switch (k) {
        .sphere => |s| v.length(p) - s.radius,
        .ellipsoid => |e| blk: {
            // Quilez's bound: exact on the surface, close nearby.
            const q = Vec3{ p[0] / e.radii[0], p[1] / e.radii[1], p[2] / e.radii[2] };
            const k0 = v.length(q);
            const k1 = v.length(.{ q[0] / e.radii[0], q[1] / e.radii[1], q[2] / e.radii[2] });
            break :blk if (k1 > 0) k0 * (k0 - 1) / k1 else -@min(e.radii[0], @min(e.radii[1], e.radii[2]));
        },
        .box => |b| blk: {
            const r = @min(b.round, @min(b.half[0], @min(b.half[1], b.half[2])));
            const q = Vec3{ @abs(p[0]) - b.half[0] + r, @abs(p[1]) - b.half[1] + r, @abs(p[2]) - b.half[2] + r };
            const outside = v.length(.{ @max(q[0], 0), @max(q[1], 0), @max(q[2], 0) });
            break :blk outside + @min(@max(q[0], @max(q[1], q[2])), 0) - r;
        },
        .capsule => |c| capsuleDist(p, c.a, c.b, c.ra, c.rb),
        .torus => |t| len2(len2(p[0] / t.sx, p[1] / t.sy) - t.major, p[2]) - t.minor,
        .cylinder => |c| blk: {
            const d0 = len2(p[0], p[1]) - c.radius;
            const d1 = @abs(p[2]) - c.half_height;
            break :blk @min(@max(d0, d1), 0) + len2(@max(d0, 0), @max(d1, 0));
        },
        .half_space => |h| v.dot(p, h.normal),
        .chain => |c| blk: {
            var d: f32 = big;
            for (0..c.points.len - 1) |i| d = @min(d, capsuleDist(p, c.points[i], c.points[i + 1], c.radii[i], c.radii[i + 1]));
            break :blk d;
        },
    };
}

/// A shape ready to evaluate: its rotation as rows of the inverse matrix.
const Placed = struct {
    shape: Shape,
    inv_rows: [3]Vec3,

    fn init(s: Shape) Placed {
        const m = v.quatToMat(v.eulerToQuat(s.rotation, .xyz));
        // The inverse of a rotation is its transpose: rows = columns of m.
        return .{ .shape = s, .inv_rows = .{ v.axis(m, 0), v.axis(m, 1), v.axis(m, 2) } };
    }

    fn one(pl: Placed, p: Vec3) f32 {
        const d = v.sub(p, pl.shape.location);
        const q = Vec3{ v.dot(pl.inv_rows[0], d), v.dot(pl.inv_rows[1], d), v.dot(pl.inv_rows[2], d) };
        const s = pl.shape.scale;
        return localDist(pl.shape.kind, v.scale(q, 1 / s)) * s;
    }

    fn dist(pl: Placed, p: Vec3) f32 {
        const d = pl.one(p);
        return if (pl.shape.mirror_x) @min(d, pl.one(.{ -p[0], p[1], p[2] })) else d;
    }
};

/// Local bounding box of a shape, or null when it is unbounded.
fn localBounds(k: Kind) ?[2]Vec3 {
    return switch (k) {
        .sphere => |s| .{ @splat(-s.radius), @splat(s.radius) },
        .ellipsoid => |e| .{ v.scale(e.radii, -1), e.radii },
        .box => |b| .{ v.scale(b.half, -1), b.half },
        .capsule => |c| blk: {
            const r = @max(c.ra, c.rb);
            break :blk .{ v.sub(v.min3(c.a, c.b), @splat(r)), v.add(v.max3(c.a, c.b), @splat(r)) };
        },
        .torus => |t| .{ .{ -(t.major + t.minor) * t.sx, -(t.major + t.minor) * t.sy, -t.minor }, .{ (t.major + t.minor) * t.sx, (t.major + t.minor) * t.sy, t.minor } },
        .cylinder => |c| .{ .{ -c.radius, -c.radius, -c.half_height }, .{ c.radius, c.radius, c.half_height } },
        .half_space => null,
        .chain => |c| blk: {
            var lo = c.points[0];
            var hi = c.points[0];
            var r: f32 = 0;
            for (c.points, c.radii) |p, rr| {
                lo = v.min3(lo, p);
                hi = v.max3(hi, p);
                r = @max(r, rr);
            }
            break :blk .{ v.sub(lo, @splat(r)), v.add(hi, @splat(r)) };
        },
    };
}

/// World bounds of a shape (with its mirror and offset), or null.
fn worldBounds(s: Shape, offset: f32) ?[2]Vec3 {
    const lb = localBounds(s.kind) orelse return null;
    const m = v.quatToMat(v.eulerToQuat(s.rotation, .xyz));
    var lo: Vec3 = @splat(std.math.inf(f32));
    var hi: Vec3 = @splat(-std.math.inf(f32));
    for (0..8) |c| {
        const corner = Vec3{ lb[c & 1][0], lb[(c >> 1) & 1][1], lb[(c >> 2) & 1][2] };
        const p = v.add(s.location, v.transformDir(m, v.scale(corner, s.scale)));
        lo = v.min3(lo, p);
        hi = v.max3(hi, p);
    }
    if (s.mirror_x) {
        const mlo = -hi[0];
        hi[0] = @max(hi[0], -lo[0]);
        lo[0] = @min(lo[0], mlo);
    }
    const g = @max(offset, 0);
    return .{ v.sub(lo, @splat(g)), v.add(hi, @splat(g)) };
}

/// Bounds of what a step list adds, or null if something added is unbounded.
fn addedBounds(steps: []const Step, acc: *?[2]Vec3) bool {
    for (steps) |st| {
        if (st.op != .add) continue;
        const b: ?[2]Vec3 = switch (st.body) {
            .shape => |s| worldBounds(s, st.offset) orelse return false,
            .group => |g| blk: {
                var inner: ?[2]Vec3 = null;
                if (!addedBounds(g, &inner)) return false;
                break :blk inner;
            },
        };
        if (b) |bb| {
            const reach = st.blend + displaceReach(st);
            const grown = [2]Vec3{ v.sub(bb[0], @splat(reach)), v.add(bb[1], @splat(reach)) };
            acc.* = if (acc.*) |a| .{ v.min3(a[0], grown[0]), v.max3(a[1], grown[1]) } else grown;
        }
    }
    return true;
}

fn usesSlots(steps: []const Step) bool {
    for (steps) |st| {
        if (st.slot != null) return true;
        if (st.body == .group and usesSlots(st.body.group)) return true;
    }
    return false;
}

pub const Grid = struct {
    origin: Vec3,
    voxel: f32,
    n: [3]usize,

    fn count(g: Grid) usize {
        return g.n[0] * g.n[1] * g.n[2];
    }
    fn index(g: Grid, i: usize, j: usize, k: usize) usize {
        return (i * g.n[1] + j) * g.n[2] + k;
    }
    fn point(g: Grid, i: usize, j: usize, k: usize) Vec3 {
        return .{
            g.origin[0] + g.voxel * @as(f32, @floatFromInt(i)),
            g.origin[1] + g.voxel * @as(f32, @floatFromInt(j)),
            g.origin[2] + g.voxel * @as(f32, @floatFromInt(k)),
        };
    }
    /// Cell index range covering a world box, clamped to the grid.
    fn range(g: Grid, b: [2]Vec3) [2][3]usize {
        var out: [2][3]usize = undefined;
        for (0..3) |a| {
            const lo = @floor((b[0][a] - g.origin[a]) / g.voxel);
            const hi = @ceil((b[1][a] - g.origin[a]) / g.voxel) + 1;
            const nf: f32 = @floatFromInt(g.n[a]);
            out[0][a] = @intFromFloat(std.math.clamp(lo, 0, nf));
            out[1][a] = @intFromFloat(std.math.clamp(hi, 0, nf));
        }
        return out;
    }
};

/// A field plus, when the program uses slots, the slot that won each cell.
const Field = struct {
    d: []f32,
    slot: []u8,

    fn init(gpa: Allocator, n: usize, slots: bool) Allocator.Error!Field {
        const d = try gpa.alloc(f32, n);
        @memset(d, big);
        const s = try gpa.alloc(u8, if (slots) n else 0);
        @memset(s, 0);
        return .{ .d = d, .slot = s };
    }
    fn deinit(f: Field, gpa: Allocator) void {
        gpa.free(f.d);
        gpa.free(f.slot);
    }
};

/// Combines value `s` (slot `sl`) into cell `c` of `f` by `op`.
inline fn combine(f: Field, c: usize, op: Op, k: f32, s: f32, sl: ?u8) void {
    const old = f.d[c];
    switch (op) {
        .add => {
            f.d[c] = smin(old, s, k);
            if (sl) |x| if (f.slot.len > 0 and s < old) {
                f.slot[c] = x;
            };
        },
        .subtract => {
            f.d[c] = smax(old, -s, k);
            if (sl) |x| if (f.slot.len > 0 and -s > old) {
                f.slot[c] = x;
            };
        },
        .intersect => f.d[c] = smax(old, s, k),
    }
}

const Eval = struct {
    gpa: Allocator,
    grid: Grid,
    pool: ?math.Pool,
    margin: f32,
    slots: bool,
    naive_chains: bool = false,

    /// Applies `steps` to `f`.
    fn run(e: *const Eval, f: Field, steps: []const Step) Error!void {
        for (steps) |st| switch (st.body) {
            .shape => |s| try e.shapeStep(f, st, s),
            .group => |g| {
                const tmp = try Field.init(e.gpa, f.d.len, e.slots);
                defer tmp.deinit(e.gpa);
                try e.run(tmp, g);
                var b: ?[2]Vec3 = null;
                const bounded = addedBounds(g, &b);
                const r = if (st.op == .intersect or !bounded or b == null)
                    [2][3]usize{ .{ 0, 0, 0 }, e.grid.n }
                else
                    e.grid.range(e.grow(b.?, st.blend + @max(st.offset, 0)));
                try e.forRange(r, GroupCtx{ .f = f, .tmp = tmp, .st = st });
            },
        };
    }

    fn grow(e: *const Eval, b: [2]Vec3, by: f32) [2]Vec3 {
        const g = by + e.margin;
        return .{ v.sub(b[0], @splat(g)), v.add(b[1], @splat(g)) };
    }

    fn shapeStep(e: *const Eval, f: Field, st: Step, s: Shape) Error!void {
        if (s.kind == .chain and st.op != .intersect and !e.naive_chains) return e.chainStep(f, st, s);
        const wb = worldBounds(s, st.offset);
        const r = if (st.op == .intersect or wb == null)
            [2][3]usize{ .{ 0, 0, 0 }, e.grid.n }
        else
            e.grid.range(e.grow(wb.?, st.blend + displaceReach(st)));
        try e.forRange(r, ShapeCtx{ .f = f, .pl = Placed.init(s), .st = st, .grid = e.grid });
    }

    /// A chain's distance is the minimum over its segments, and a segment
    /// matters only near itself. So each segment writes its own small box of
    /// a scratch grid over the chain's region, and the chain then combines
    /// with the field in one pass: far fewer distance evaluations than
    /// testing every segment in every cell of the chain's box.
    fn chainStep(e: *const Eval, f: Field, st: Step, s: Shape) Error!void {
        const c = s.kind.chain;
        const r = e.grid.range(e.grow(worldBounds(s, st.offset).?, st.blend + displaceReach(st)));
        if (r[1][0] <= r[0][0] or r[1][1] <= r[0][1] or r[1][2] <= r[0][2]) return;
        // Segments in world space, mirrored copies included.
        const copies: usize = if (s.mirror_x) 2 else 1;
        const n_seg = (c.points.len - 1) * copies;
        const segs = try e.gpa.alloc(Seg, n_seg);
        defer e.gpa.free(segs);
        const m = v.quatToMat(v.eulerToQuat(s.rotation, .xyz));
        for (0..copies) |copy| for (0..c.points.len - 1) |i| {
            var a = v.add(s.location, v.transformDir(m, v.scale(c.points[i], s.scale)));
            var b = v.add(s.location, v.transformDir(m, v.scale(c.points[i + 1], s.scale)));
            if (copy == 1) {
                a[0] = -a[0];
                b[0] = -b[0];
            }
            const ra = c.radii[i] * s.scale - st.offset;
            const rb = c.radii[i + 1] * s.scale - st.offset;
            const g = @max(ra, rb) + st.blend + displaceReach(st) + e.margin;
            const box = e.grid.range(.{ v.sub(v.min3(a, b), @splat(g)), v.add(v.max3(a, b), @splat(g)) });
            segs[copy * (c.points.len - 1) + i] = .{ .a = a, .b = b, .ra = ra, .rb = rb, .box = box };
        };
        const dims = [3]usize{ r[1][0] - r[0][0], r[1][1] - r[0][1], r[1][2] - r[0][2] };
        const tmp = try e.gpa.alloc(f32, dims[0] * dims[1] * dims[2]);
        defer e.gpa.free(tmp);
        @memset(tmp, big);
        const Ctx = struct {
            segs: []const Seg,
            tmp: []f32,
            r: [2][3]usize,
            dims: [3]usize,
            f: Field,
            st: Step,
            fn cell(cx: @This(), g: Grid, i: usize, j: usize, k: usize) void {
                var t = cx.tmp[((i - cx.r[0][0]) * cx.dims[1] + (j - cx.r[0][1])) * cx.dims[2] + (k - cx.r[0][2])];
                if (cx.st.displace) |tex| if (t < big) {
                    t -= cx.st.displace_amount * (tex.scalar(g.point(i, j, k)) - 0.5);
                };
                combine(cx.f, g.index(i, j, k), cx.st.op, cx.st.blend, t, cx.st.slot);
            }
        };
        const ctx: Ctx = .{ .segs = segs, .tmp = tmp, .r = r, .dims = dims, .f = f, .st = st };
        // Fill the scratch grid one x slab at a time, so threads never share
        // a cell; then combine.
        try e.fillChain(&ctx, dims);
        try e.forRange(r, ctx);
    }

    fn fillChain(e: *const Eval, ctx: anytype, dims: [3]usize) Error!void {
        const Job = struct {
            ctx: @TypeOf(ctx),
            grid: Grid,
            fn run(job: *const @This(), x: usize) void {
                const cx = job.ctx;
                const i = cx.r[0][0] + x;
                for (cx.segs) |sg| {
                    if (i < sg.box[0][0] or i >= sg.box[1][0]) continue;
                    const j0 = @max(sg.box[0][1], cx.r[0][1]);
                    const j1 = @min(sg.box[1][1], cx.r[1][1]);
                    const k0 = @max(sg.box[0][2], cx.r[0][2]);
                    const k1 = @min(sg.box[1][2], cx.r[1][2]);
                    for (j0..j1) |j| for (k0..k1) |k| {
                        const idx = (x * cx.dims[1] + (j - cx.r[0][1])) * cx.dims[2] + (k - cx.r[0][2]);
                        cx.tmp[idx] = @min(cx.tmp[idx], capsuleDist(job.grid.point(i, j, k), sg.a, sg.b, sg.ra, sg.rb));
                    };
                }
            }
        };
        const job: Job = .{ .ctx = ctx, .grid = e.grid };
        if (e.pool) |p| if (p.threads > 1 and dims[0] * dims[1] * dims[2] >= 32 * 1024) {
            try p.parallelFor(dims[0], &job, Job.run);
            return;
        };
        for (0..dims[0]) |x| job.run(x);
    }

    /// Calls ctx.cell for every cell in the index box, x slabs in parallel
    /// when the box is large.
    fn forRange(e: *const Eval, r: [2][3]usize, ctx: anytype) Error!void {
        if (r[1][0] <= r[0][0] or r[1][1] <= r[0][1] or r[1][2] <= r[0][2]) return;
        const Ctx = @TypeOf(ctx);
        const Slab = struct {
            ctx: Ctx,
            r: [2][3]usize,
            grid: Grid,
            fn run(s: *const @This(), x: usize) void {
                const i = s.r[0][0] + x;
                for (s.r[0][1]..s.r[1][1]) |j| for (s.r[0][2]..s.r[1][2]) |k| s.ctx.cell(s.grid, i, j, k);
            }
        };
        const slab: Slab = .{ .ctx = ctx, .r = r, .grid = e.grid };
        const nx = r[1][0] - r[0][0];
        const cells = nx * (r[1][1] - r[0][1]) * (r[1][2] - r[0][2]);
        if (e.pool) |p| if (cells >= 32 * 1024 and p.threads > 1) {
            try p.parallelFor(nx, &slab, Slab.run);
            return;
        };
        for (0..nx) |x| slab.run(x);
    }
};

/// How far a step's displacement can move its surface out.
fn displaceReach(st: Step) f32 {
    return if (st.displace != null) @abs(st.displace_amount) else 0;
}

const Seg = struct { a: Vec3, b: Vec3, ra: f32, rb: f32, box: [2][3]usize };

const ShapeCtx = struct {
    f: Field,
    pl: Placed,
    st: Step,
    grid: Grid,
    fn cell(c: ShapeCtx, g: Grid, i: usize, j: usize, k: usize) void {
        const p = g.point(i, j, k);
        var s = c.pl.dist(p) - c.st.offset;
        if (c.st.displace) |r| s -= c.st.displace_amount * (r.scalar(p) - 0.5);
        combine(c.f, g.index(i, j, k), c.st.op, c.st.blend, s, c.st.slot);
    }
};

const GroupCtx = struct {
    f: Field,
    tmp: Field,
    st: Step,
    fn cell(c: GroupCtx, g: Grid, i: usize, j: usize, k: usize) void {
        const idx = g.index(i, j, k);
        const s = c.tmp.d[idx] - c.st.offset;
        const sl: ?u8 = c.st.slot orelse if (c.tmp.slot.len > 0) c.tmp.slot[idx] else null;
        combine(c.f, idx, c.st.op, c.st.blend, s, sl);
    }
};

/// Samples the program; the caller frees the field.
pub fn sample(gpa: Allocator, steps: []const Step, opts: Options) Error!struct { grid: Grid, field: []f32, slot: []u8 } {
    if (!(opts.voxel > 0)) return error.InvalidParameter;
    var b: ?[2]Vec3 = opts.bounds;
    if (b == null) {
        if (!addedBounds(steps, &b)) return error.Unbounded;
        const bb = b orelse return error.Empty;
        const pad = 2 * opts.voxel;
        b = .{ v.sub(bb[0], @splat(pad)), v.add(bb[1], @splat(pad)) };
    }
    const bb = b.?;
    var n: [3]usize = undefined;
    var cells: u64 = 1;
    for (0..3) |a| {
        const ext = bb[1][a] - bb[0][a];
        if (!(ext > 0)) return error.Empty;
        const c = @ceil(ext / opts.voxel) + 1;
        if (c > 1e6) return error.TooManyCells;
        n[a] = @intFromFloat(c);
        cells *= n[a];
    }
    if (cells > opts.max_cells) return error.TooManyCells;
    const grid: Grid = .{ .origin = bb[0], .voxel = opts.voxel, .n = n };
    const slots = usesSlots(steps);
    const f = try Field.init(gpa, grid.count(), slots);
    errdefer f.deinit(gpa);
    const e: Eval = .{ .gpa = gpa, .grid = grid, .pool = opts.pool, .margin = 2 * opts.voxel, .slots = slots, .naive_chains = opts.naive_chains };
    try e.run(f, steps);
    return .{ .grid = grid, .field = f.d, .slot = f.slot };
}

/// Builds the mesh of the program's zero surface: quads, smooth shaded,
/// with a material_index attribute when steps set slots.
pub fn mesh(gpa: Allocator, steps: []const Step, opts: Options) Error!Mesh {
    const s = try sample(gpa, steps, opts);
    defer gpa.free(s.field);
    defer gpa.free(s.slot);
    return surfaceNets(gpa, s.grid, s.field, s.slot, opts);
}

const edge_corners = [12][2]u3{
    .{ 0, 1 }, .{ 2, 3 }, .{ 4, 5 }, .{ 6, 7 }, // along z
    .{ 0, 2 }, .{ 1, 3 }, .{ 4, 6 }, .{ 5, 7 }, // along y
    .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 }, // along x
};

/// One vertex per cell the surface crosses, at the mean of its edge
/// crossings; one quad per crossed grid edge, wound outward.
fn surfaceNets(gpa: Allocator, g: Grid, f: []const f32, slot: []const u8, opts: Options) Error!Mesh {
    const cn = [3]usize{ g.n[0] - 1, g.n[1] - 1, g.n[2] - 1 };
    if (cn[0] == 0 or cn[1] == 0 or cn[2] == 0) return error.Empty;
    const none = std.math.maxInt(u32);
    const cell_vert = try gpa.alloc(u32, cn[0] * cn[1] * cn[2]);
    defer gpa.free(cell_vert);
    var positions: std.ArrayList(Vec3) = .empty;
    defer positions.deinit(gpa);
    for (0..cn[0]) |i| for (0..cn[1]) |j| for (0..cn[2]) |k| {
        var vals: [8]f32 = undefined;
        var inside: u8 = 0;
        for (0..8) |c| {
            vals[c] = f[g.index(i + (c >> 2), j + ((c >> 1) & 1), k + (c & 1))];
            if (vals[c] < 0) inside += 1;
        }
        const ci = (i * cn[1] + j) * cn[2] + k;
        if (inside == 0 or inside == 8) {
            cell_vert[ci] = none;
            continue;
        }
        var sum: Vec3 = .{ 0, 0, 0 };
        var cnt: f32 = 0;
        for (edge_corners) |ec| {
            const a = vals[ec[0]];
            const b = vals[ec[1]];
            if ((a < 0) == (b < 0)) continue;
            const t = a / (a - b);
            const pa = cornerOffset(ec[0]);
            const pb = cornerOffset(ec[1]);
            sum = v.add(sum, v.lerp(pa, pb, t));
            cnt += 1;
        }
        cell_vert[ci] = @intCast(positions.items.len);
        try positions.append(gpa, v.add(g.point(i, j, k), v.scale(sum, g.voxel / cnt)));
    };

    var corners: std.ArrayList(u32) = .empty;
    defer corners.deinit(gpa);
    var mats: std.ArrayList(i32) = .empty;
    defer mats.deinit(gpa);
    const cell = struct {
        fn at(cv: []const u32, cnn: [3]usize, i: usize, j: usize, k: usize) u32 {
            return cv[(i * cnn[1] + j) * cnn[2] + k];
        }
    }.at;
    // Grid edges from (i, j, k) one step along `axis`, away from the border
    // so the four cells around them exist.
    for (0..3) |axis| {
        for (0..g.n[0]) |i| for (0..g.n[1]) |j| for (0..g.n[2]) |k| {
            var e = [3]usize{ i, j, k };
            e[axis] += 1;
            if (e[0] >= g.n[0] or e[1] >= g.n[1] or e[2] >= g.n[2]) continue;
            const a = f[g.index(i, j, k)];
            const b = f[g.index(e[0], e[1], e[2])];
            if ((a < 0) == (b < 0)) continue;
            const q: [4]u32 = switch (axis) {
                0 => blk: {
                    if (j == 0 or k == 0) continue;
                    break :blk .{ cell(cell_vert, cn, i, j - 1, k - 1), cell(cell_vert, cn, i, j, k - 1), cell(cell_vert, cn, i, j, k), cell(cell_vert, cn, i, j - 1, k) };
                },
                1 => blk: {
                    if (i == 0 or k == 0) continue;
                    break :blk .{ cell(cell_vert, cn, i - 1, j, k - 1), cell(cell_vert, cn, i - 1, j, k), cell(cell_vert, cn, i, j, k), cell(cell_vert, cn, i, j, k - 1) };
                },
                else => blk: {
                    if (i == 0 or j == 0) continue;
                    break :blk .{ cell(cell_vert, cn, i - 1, j - 1, k), cell(cell_vert, cn, i, j - 1, k), cell(cell_vert, cn, i, j, k), cell(cell_vert, cn, i - 1, j, k) };
                },
            };
            if (q[0] == none or q[1] == none or q[2] == none or q[3] == none) continue;
            if (a < 0) {
                try corners.appendSlice(gpa, &q);
            } else {
                try corners.appendSlice(gpa, &.{ q[3], q[2], q[1], q[0] });
            }
            if (slot.len > 0) try mats.append(gpa, slot[if (a < 0) g.index(i, j, k) else g.index(e[0], e[1], e[2])]);
        };
    }
    const n_faces = corners.items.len / 4;
    if (n_faces == 0) return error.Empty;
    const offsets = try gpa.alloc(u32, n_faces + 1);
    defer gpa.free(offsets);
    for (offsets, 0..) |*o, x| o.* = @intCast(4 * x);

    var m = try build.fromPolygons(gpa, .{
        .positions = positions.items,
        .face_offsets = offsets,
        .corner_verts = corners.items,
        .material_index = mats.items,
    });
    errdefer m.releaseRefs(gpa);
    if (opts.smooth_iterations > 0) {
        const pos = try gpa.dupe(Vec3, m.positions.slice());
        var pos_owned = true;
        defer if (pos_owned) gpa.free(pos);
        const w = try gpa.alloc(f32, pos.len);
        defer gpa.free(w);
        @memset(w, 1);
        try smooth_op.smooth(gpa, &m, pos, w, .{ .iterations = opts.smooth_iterations }, null);
        m.positions.release(gpa);
        pos_owned = false;
        m.positions = try .fromOwned(gpa, pos);
    }
    return m;
}

fn cornerOffset(c: u3) Vec3 {
    return .{ @floatFromInt(c >> 2), @floatFromInt((c >> 1) & 1), @floatFromInt(c & 1) };
}

const testing = std.testing;

fn volumeOf(m: *const Mesh) f32 {
    // Divergence theorem over the quads, split into triangles.
    const pos = m.positions.slice();
    const off = m.face_offsets.slice();
    const cv = m.corner_verts.slice();
    var vol: f32 = 0;
    for (0..off.len - 1) |fi| {
        const a = pos[cv[off[fi]]];
        for (off[fi] + 1..off[fi + 1] - 1) |c| vol += v.dot(a, v.cross(pos[cv[c]], pos[cv[c + 1]])) / 6;
    }
    return vol;
}

test "a sphere meshes closed, outward, at the right volume" {
    const gpa = testing.allocator;
    var m = try mesh(gpa, &.{.{ .body = .{ .shape = .{ .kind = .{ .sphere = .{ .radius = 1 } } } } }}, .{ .voxel = 0.02 });
    defer m.releaseRefs(gpa);
    // Closed and manifold: V - E + F = 2.
    try testing.expectEqual(@as(i64, 2), @as(i64, @intCast(m.vertCount())) - @as(i64, @intCast(m.edgeCount())) + @as(i64, @intCast(m.faceCount())));
    // Positive volume means the quads face outward.
    const vol = volumeOf(&m);
    try testing.expectApproxEqRel(@as(f32, 4.0 / 3.0 * std.math.pi), vol, 0.01);
}

test "smooth union fills the crease; subtract cuts; slots follow the winner" {
    const gpa = testing.allocator;
    const two = [_]Step{
        .{ .body = .{ .shape = .{ .kind = .{ .sphere = .{ .radius = 0.5 } }, .location = .{ -0.4, 0, 0 } } } },
        .{ .blend = 0.3, .slot = 1, .body = .{ .shape = .{ .kind = .{ .sphere = .{ .radius = 0.5 } }, .location = .{ 0.4, 0, 0 } } } },
    };
    const hard = [_]Step{ two[0], .{ .slot = 1, .body = two[1].body } };
    // Bounds that put grid points exactly on the probes below.
    const box = [2]Vec3{ .{ -1.2, -0.8, -0.8 }, .{ 1.2, 0.8, 0.8 } };
    const a = try sample(gpa, &two, .{ .voxel = 0.05, .bounds = box });
    defer gpa.free(a.field);
    defer gpa.free(a.slot);
    const b = try sample(gpa, &hard, .{ .voxel = 0.05, .bounds = box });
    defer gpa.free(b.field);
    defer gpa.free(b.slot);
    // At the waist (x = 0, y = 0.4) the blend is inside, the hard union outside.
    const pw: Vec3 = .{ 0, 0.4, 0 };
    try testing.expect(sampleAt(a.grid, a.field, pw) < 0);
    try testing.expect(sampleAt(b.grid, b.field, pw) > 0);
    // The right sphere's centre carries its slot.
    try testing.expectEqual(@as(u8, 1), a.slot[nearest(a.grid, .{ 0.4, 0, 0 })]);
    try testing.expectEqual(@as(u8, 0), a.slot[nearest(a.grid, .{ -0.4, 0, 0 })]);

    var cut = try mesh(gpa, &.{
        .{ .body = .{ .shape = .{ .kind = .{ .box = .{ .half = .{ 1, 1, 1 }, .round = 0.1 } } } } },
        .{ .op = .subtract, .blend = 0.05, .body = .{ .shape = .{ .kind = .{ .cylinder = .{ .radius = 0.4, .half_height = 2 } } } } },
    }, .{ .voxel = 0.05 });
    defer cut.releaseRefs(gpa);
    // A box with a hole through it: genus 1, so V - E + F = 0.
    try testing.expectEqual(@as(i64, 0), @as(i64, @intCast(cut.vertCount())) - @as(i64, @intCast(cut.edgeCount())) + @as(i64, @intCast(cut.faceCount())));
}

test "chains, mirrors and groups; the same mesh at any thread count" {
    const gpa = testing.allocator;
    const pts = [_]Vec3{ .{ 0.3, 0, 0 }, .{ 0.5, 0, 0.5 }, .{ 0.3, 0, 1 } };
    const radii = [_]f32{ 0.1, 0.08, 0.05 };
    const group = [_]Step{
        .{ .body = .{ .shape = .{ .kind = .{ .chain = .{ .points = &pts, .radii = &radii } }, .mirror_x = true } } },
        .{ .op = .subtract, .body = .{ .shape = .{ .kind = .{ .half_space = .{ .normal = .{ 0, 0, -1 } } } } } },
    };
    const prog = [_]Step{
        .{ .body = .{ .shape = .{ .kind = .{ .ellipsoid = .{ .radii = .{ 0.3, 0.2, 0.25 } } } } } },
        .{ .blend = 0.05, .body = .{ .group = &group } },
    };
    var one = try mesh(gpa, &prog, .{ .voxel = 0.03, .pool = .{ .io = testing.io, .threads = 1 } });
    defer one.releaseRefs(gpa);
    var four = try mesh(gpa, &prog, .{ .voxel = 0.03, .pool = .{ .io = testing.io, .threads = 4 } });
    defer four.releaseRefs(gpa);
    try testing.expectEqualSlices(Vec3, one.positions.slice(), four.positions.slice());
    try testing.expectEqualSlices(u32, one.corner_verts.slice(), four.corner_verts.slice());
    // Mirrored: the mesh spans both sides equally.
    var lo: f32 = 0;
    var hi: f32 = 0;
    for (one.positions.slice()) |p| {
        lo = @min(lo, p[0]);
        hi = @max(hi, p[0]);
    }
    try testing.expectApproxEqAbs(-lo, hi, 0.03);
    try testing.expectError(error.Unbounded, mesh(gpa, &.{.{ .body = .{ .shape = .{ .kind = .{ .half_space = .{ .normal = .{ 0, 0, 1 } } } } } }}, .{ .voxel = 0.1 }));
}

fn nearest(g: Grid, p: Vec3) usize {
    var idx: [3]usize = undefined;
    for (0..3) |a| idx[a] = @intFromFloat(@round((p[a] - g.origin[a]) / g.voxel));
    return g.index(idx[0], idx[1], idx[2]);
}

fn sampleAt(g: Grid, f: []const f32, p: Vec3) f32 {
    return f[nearest(g, p)];
}

test "the per-segment chain path keeps every cell's sign" {
    const gpa = testing.allocator;
    var pts: [40]Vec3 = undefined;
    var radii: [40]f32 = undefined;
    for (&pts, &radii, 0..) |*p, *r, i| {
        const t: f32 = @floatFromInt(i);
        p.* = .{ 0.3 * @cos(t * 0.4), 0.3 * @sin(t * 0.4), -0.6 + t * 0.03 };
        r.* = 0.06 - t * 0.001;
    }
    const prog = [_]Step{
        .{ .body = .{ .shape = .{ .kind = .{ .ellipsoid = .{ .radii = .{ 0.25, 0.25, 0.5 } } } } } },
        .{ .blend = 0.03, .body = .{ .shape = .{ .kind = .{ .chain = .{ .points = &pts, .radii = &radii } }, .mirror_x = true } } },
        .{ .op = .subtract, .blend = 0.05, .body = .{ .shape = .{ .kind = .{ .half_space = .{ .normal = .{ 0, 0.2, -1 } } }, .location = .{ 0, 0, 0.4 } } } },
    };
    const fast = try sample(gpa, &prog, .{ .voxel = 0.02 });
    defer gpa.free(fast.field);
    defer gpa.free(fast.slot);
    const slow = try sample(gpa, &prog, .{ .voxel = 0.02, .naive_chains = true });
    defer gpa.free(slow.field);
    defer gpa.free(slow.slot);
    var differ: usize = 0;
    for (fast.field, slow.field) |x, y| {
        if ((x < 0) != (y < 0)) differ += 1;
    }
    try testing.expectEqual(@as(usize, 0), differ);
}
