//! Selectors (TRD §7). Agents cannot click, so mesh operators take a rule
//! that picks elements instead of a stored selection: index sets,
//! comparisons on position, normal, size or a named attribute, boxes,
//! spheres, normal cones, and set operations. The command core parses the
//! JSON form into a `Selector`; this module evaluates it against a Mesh.
//!
//! Positions, centres and normals are measured in world space by default
//! (the space agents see in scene.inspect bounds) or in the mesh's local
//! space. A face's centre is the mean of its corners, an edge's is its
//! midpoint; a vertex normal is the area-weighted mean of its faces',
//! an edge's the mean of its faces' unit normals.

const std = @import("std");
const math = @import("math");
const core = @import("../core/root.zig");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const v = math.vec;
const Mesh = core.types.Mesh;

pub const Bits = std.DynamicBitSetUnmanaged;

pub const Domain = enum {
    vert,
    edge,
    face,

    pub fn plural(d: Domain) []const u8 {
        return switch (d) {
            .vert => "verts",
            .edge => "edges",
            .face => "faces",
        };
    }

    pub fn count(d: Domain, m: *const Mesh) usize {
        return switch (d) {
            .vert => m.vertCount(),
            .edge => m.edgeCount(),
            .face => m.faceCount(),
        };
    }
};

pub const Space = enum { world, local };

pub const Field = union(enum) {
    x,
    y,
    z,
    nx,
    ny,
    nz,
    /// Face area (m²); for edges and verts, not defined.
    area,
    /// Edge length (m).
    length,
    index,
    /// A scalar attribute (float, int or boolean) on the selector's domain.
    attribute: []const u8,
};

pub const Cmp = enum {
    lt,
    le,
    gt,
    ge,
    eq,
    ne,

    fn holds(c: Cmp, a: f64, b: f64) bool {
        const tol = 1e-6 * @max(1.0, @abs(b));
        return switch (c) {
            .lt => a < b,
            .le => a <= b + tol,
            .gt => a > b,
            .ge => a >= b - tol,
            .eq => @abs(a - b) <= tol,
            .ne => @abs(a - b) > tol,
        };
    }
};

pub const Pred = struct {
    field: Field,
    /// Compare |field| rather than field.
    abs: bool = false,
    cmp: Cmp,
    value: f64,
};

/// Inclusive index range.
pub const Range = [2]u32;

pub const Node = struct {
    index: ?[]const Range = null,
    where: []const Pred = &.{},
    /// Centre inside [min, max] (inclusive).
    box: ?[2]Vec3 = null,
    sphere: ?struct { center: Vec3, radius: f32 } = null,
    /// Unit normal within an angle of `dir`: dot(n, dir) >= cos_max.
    normal: ?struct { dir: Vec3, cos_max: f32 } = null,
    /// Edges only: running along `dir` either way, |dot(d, dir)| >= cos_max.
    direction: ?struct { dir: Vec3, cos_max: f32 } = null,
    /// Set operations on child nodes; every part present must hold.
    any_of: []const Node = &.{},
    all_of: []const Node = &.{},
    none_of: []const Node = &.{},
};

pub const Selector = struct {
    domain: Domain,
    space: Space = .world,
    root: Node = .{},
};

pub const Error = Allocator.Error || error{
    IndexOutOfRange,
    UnknownAttribute,
    AttributeNotScalar,
    /// area outside the face domain, or length outside the edge domain.
    FieldNotInDomain,
};

/// Details for `Error` values other than OutOfMemory.
pub const Diag = struct {
    index: u32 = 0,
    attribute: []const u8 = "",
};

/// Evaluates `sel` on `m`, whose object has world matrix `world`. The
/// result has one bit per element of `sel.domain`; the caller frees it.
pub fn evaluate(gpa: Allocator, m: *const Mesh, sel: Selector, world: Mat4, diag: *Diag) Error!Bits {
    var ctx: Ctx = .{ .gpa = gpa, .m = m, .domain = sel.domain, .n = sel.domain.count(m), .diag = diag };
    defer ctx.deinit();
    if (sel.space == .world and !std.mem.eql(f32, &world, &v.identity)) {
        const p = try gpa.alloc(Vec3, m.vertCount());
        for (m.positions.slice(), p) |src, *dst| dst.* = v.transformPoint(world, src);
        ctx.world_pos = p;
        ctx.flip = det3(world) < 0;
    }
    var out = try Bits.initFull(gpa, ctx.n);
    errdefer out.deinit(gpa);
    try ctx.node(sel.root, &out);
    return out;
}

/// Elements selected as their vertices: a face's corners, an edge's ends.
pub fn toVerts(gpa: Allocator, m: *const Mesh, domain: Domain, bits: *const Bits) Allocator.Error!Bits {
    var out = try Bits.initEmpty(gpa, m.vertCount());
    switch (domain) {
        .vert => out.setUnion(bits.*),
        .edge => for (m.edges.slice(), 0..) |e, i| if (bits.isSet(i)) {
            out.set(e[0]);
            out.set(e[1]);
        },
        .face => {
            const off = m.face_offsets.slice();
            const cv = m.corner_verts.slice();
            for (0..m.faceCount()) |f| if (bits.isSet(f)) for (cv[off[f]..off[f + 1]]) |x| out.set(x);
        },
    }
    return out;
}

/// Faces selected by `bits`: a vertex or edge selection picks the faces
/// whose vertices (or edges) are all selected, as Blender's mode switch does.
pub fn toFaces(gpa: Allocator, m: *const Mesh, domain: Domain, bits: *const Bits) Allocator.Error!Bits {
    const n_faces = m.faceCount();
    if (domain == .face) return bits.clone(gpa);
    var out = try Bits.initEmpty(gpa, n_faces);
    const off = m.face_offsets.slice();
    const corners = if (domain == .vert) m.corner_verts.slice() else m.corner_edges.slice();
    for (0..n_faces) |f| {
        var all = true;
        for (corners[off[f]..off[f + 1]]) |x| if (!bits.isSet(x)) {
            all = false;
            break;
        };
        if (all) out.set(f);
    }
    return out;
}

/// Edges selected by `bits`: both ends selected, or used by a selected face.
pub fn toEdges(gpa: Allocator, m: *const Mesh, domain: Domain, bits: *const Bits) Allocator.Error!Bits {
    if (domain == .edge) return bits.clone(gpa);
    var out = try Bits.initEmpty(gpa, m.edgeCount());
    switch (domain) {
        .vert => for (m.edges.slice(), 0..) |e, i| if (bits.isSet(e[0]) and bits.isSet(e[1])) out.set(i),
        .face => {
            const off = m.face_offsets.slice();
            const ce = m.corner_edges.slice();
            for (0..m.faceCount()) |f| if (bits.isSet(f)) for (ce[off[f]..off[f + 1]]) |x| out.set(x);
        },
        .edge => unreachable,
    }
    return out;
}

const Ctx = struct {
    gpa: Allocator,
    m: *const Mesh,
    domain: Domain,
    n: usize,
    diag: *Diag,
    /// Positions in world space, or null when evaluating in local space.
    world_pos: ?[]Vec3 = null,
    /// The world matrix mirrors, so Newell normals of world positions point inward.
    flip: bool = false,
    centers: ?[]Vec3 = null,
    normals: ?[]Vec3 = null,
    sizes: ?[]f32 = null,

    fn deinit(c: *Ctx) void {
        if (c.world_pos) |p| c.gpa.free(p);
        if (c.centers) |p| c.gpa.free(p);
        if (c.normals) |p| c.gpa.free(p);
        if (c.sizes) |p| c.gpa.free(p);
    }

    fn pos(c: *const Ctx) []const Vec3 {
        return c.world_pos orelse c.m.positions.slice();
    }

    fn node(c: *Ctx, n: Node, out: *Bits) Error!void {
        if (n.index) |ranges| {
            var keep = try Bits.initEmpty(c.gpa, c.n);
            defer keep.deinit(c.gpa);
            for (ranges) |r| {
                const hi = @max(r[0], r[1]);
                if (hi >= c.n) {
                    c.diag.index = hi;
                    return error.IndexOutOfRange;
                }
                keep.setRangeValue(.{ .start = @min(r[0], r[1]), .end = hi + 1 }, true);
            }
            out.setIntersection(keep);
        }
        for (n.where) |p| try c.where(p, out);
        if (n.box) |b| {
            const ctr = try c.centerArray();
            var it = out.iterator(.{});
            while (it.next()) |i| {
                const p = ctr[i];
                for (0..3) |k| if (p[k] < b[0][k] or p[k] > b[1][k]) {
                    out.unset(i);
                    break;
                };
            }
        }
        if (n.sphere) |s| {
            const ctr = try c.centerArray();
            const r2 = s.radius * s.radius;
            var it = out.iterator(.{});
            while (it.next()) |i| {
                const d = v.sub(ctr[i], s.center);
                if (v.dot(d, d) > r2) out.unset(i);
            }
        }
        if (n.normal) |cone| {
            const nrm = try c.normalArray();
            const dir = v.normalize(cone.dir);
            var it = out.iterator(.{});
            while (it.next()) |i| {
                const x = nrm[i];
                if (v.dot(x, x) < 0.5 or v.dot(x, dir) < cone.cos_max) out.unset(i);
            }
        }
        if (n.direction) |cone| {
            if (c.domain != .edge) return error.FieldNotInDomain;
            const p = c.pos();
            const edges = c.m.edges.slice();
            const dir = v.normalize(cone.dir);
            var it = out.iterator(.{});
            while (it.next()) |i| {
                const d = v.sub(p[edges[i][1]], p[edges[i][0]]);
                const len = v.length(d);
                if (len == 0 or @abs(v.dot(d, dir)) < cone.cos_max * len) out.unset(i);
            }
        }
        if (n.any_of.len > 0) {
            var acc = try Bits.initEmpty(c.gpa, c.n);
            defer acc.deinit(c.gpa);
            for (n.any_of) |child| {
                var part = try Bits.initFull(c.gpa, c.n);
                defer part.deinit(c.gpa);
                try c.node(child, &part);
                acc.setUnion(part);
            }
            out.setIntersection(acc);
        }
        for (n.all_of) |child| try c.node(child, out);
        for (n.none_of) |child| {
            var part = try Bits.initFull(c.gpa, c.n);
            defer part.deinit(c.gpa);
            try c.node(child, &part);
            part.toggleAll();
            out.setIntersection(part);
        }
    }

    fn where(c: *Ctx, p: Pred, out: *Bits) Error!void {
        switch (p.field) {
            .x, .y, .z => {
                const k: usize = switch (p.field) {
                    .x => 0,
                    .y => 1,
                    else => 2,
                };
                const ctr = try c.centerArray();
                filter(out, p, ctr, struct {
                    fn get(a: []const Vec3, i: usize, kk: usize) f64 {
                        return a[i][kk];
                    }
                }.get, k);
            },
            .nx, .ny, .nz => {
                const k: usize = switch (p.field) {
                    .nx => 0,
                    .ny => 1,
                    else => 2,
                };
                const nrm = try c.normalArray();
                filter(out, p, nrm, struct {
                    fn get(a: []const Vec3, i: usize, kk: usize) f64 {
                        return a[i][kk];
                    }
                }.get, k);
            },
            .area, .length => {
                if ((p.field == .area and c.domain != .face) or (p.field == .length and c.domain != .edge)) return error.FieldNotInDomain;
                const s = try c.sizeArray();
                filter(out, p, s, struct {
                    fn get(a: []const f32, i: usize, _: usize) f64 {
                        return a[i];
                    }
                }.get, 0);
            },
            .index => {
                var it = out.iterator(.{});
                while (it.next()) |i| if (!test1(p, @floatFromInt(i))) out.unset(i);
            },
            .attribute => |name| {
                const a = c.m.attribute(name) orelse {
                    c.diag.attribute = name;
                    return error.UnknownAttribute;
                };
                const want: core.types.Domain = switch (c.domain) {
                    .vert => .point,
                    .edge => .edge,
                    .face => .face,
                };
                if (a.domain != want) {
                    c.diag.attribute = name;
                    return error.UnknownAttribute;
                }
                switch (a.data) {
                    .float => |d| filter(out, p, d.slice(), struct {
                        fn get(x: []const f32, i: usize, _: usize) f64 {
                            return x[i];
                        }
                    }.get, 0),
                    .int => |d| filter(out, p, d.slice(), struct {
                        fn get(x: []const i32, i: usize, _: usize) f64 {
                            return @floatFromInt(x[i]);
                        }
                    }.get, 0),
                    .boolean => |d| filter(out, p, d.slice(), struct {
                        fn get(x: []const bool, i: usize, _: usize) f64 {
                            return @floatFromInt(@intFromBool(x[i]));
                        }
                    }.get, 0),
                    else => {
                        c.diag.attribute = name;
                        return error.AttributeNotScalar;
                    },
                }
            },
        }
    }

    fn centerArray(c: *Ctx) Allocator.Error![]const Vec3 {
        if (c.centers) |x| return x;
        const p = c.pos();
        const out = try c.gpa.alloc(Vec3, c.n);
        switch (c.domain) {
            .vert => @memcpy(out, p),
            .edge => for (c.m.edges.slice(), out) |e, *o| {
                o.* = v.scale(v.add(p[e[0]], p[e[1]]), 0.5);
            },
            .face => {
                const off = c.m.face_offsets.slice();
                const cv = c.m.corner_verts.slice();
                for (out, 0..) |*o, f| o.* = meanOf(p, cv[off[f]..off[f + 1]]);
            },
        }
        c.centers = out;
        return out;
    }

    fn normalArray(c: *Ctx) Allocator.Error![]const Vec3 {
        if (c.normals) |x| return x;
        const p = c.pos();
        const off = c.m.face_offsets.slice();
        const cv = c.m.corner_verts.slice();
        const n_faces = c.m.faceCount();
        const sign: f32 = if (c.flip) -1 else 1;
        // Unnormalised Newell normals: length is twice the face area.
        const fn_raw = try c.gpa.alloc(Vec3, n_faces);
        defer c.gpa.free(fn_raw);
        for (fn_raw, 0..) |*o, f| o.* = v.scale(math.triangulate.newellNormal(p, cv[off[f]..off[f + 1]]), sign);

        const out = try c.gpa.alloc(Vec3, c.n);
        switch (c.domain) {
            .face => for (fn_raw, out) |x, *o| {
                o.* = v.normalize(x);
            },
            .vert => {
                @memset(out, .{ 0, 0, 0 });
                for (0..n_faces) |f| for (cv[off[f]..off[f + 1]]) |x| {
                    out[x] = v.add(out[x], fn_raw[f]);
                };
                for (out) |*o| o.* = v.normalize(o.*);
            },
            .edge => {
                @memset(out, .{ 0, 0, 0 });
                const ce = c.m.corner_edges.slice();
                for (0..n_faces) |f| {
                    const u = v.normalize(fn_raw[f]);
                    for (ce[off[f]..off[f + 1]]) |e| out[e] = v.add(out[e], u);
                }
                for (out) |*o| o.* = v.normalize(o.*);
            },
        }
        c.normals = out;
        return out;
    }

    fn sizeArray(c: *Ctx) Allocator.Error![]const f32 {
        if (c.sizes) |x| return x;
        const p = c.pos();
        const out = try c.gpa.alloc(f32, c.n);
        switch (c.domain) {
            .vert => @memset(out, 0),
            .edge => for (c.m.edges.slice(), out) |e, *o| {
                o.* = v.length(v.sub(p[e[1]], p[e[0]]));
            },
            .face => {
                const off = c.m.face_offsets.slice();
                const cv = c.m.corner_verts.slice();
                for (out, 0..) |*o, f| o.* = v.length(math.triangulate.newellNormal(p, cv[off[f]..off[f + 1]])) / 2;
            },
        }
        c.sizes = out;
        return out;
    }
};

fn test1(p: Pred, x: f64) bool {
    return p.cmp.holds(if (p.abs) @abs(x) else x, p.value);
}

fn filter(out: *Bits, p: Pred, data: anytype, comptime get: anytype, k: usize) void {
    var it = out.iterator(.{});
    while (it.next()) |i| if (!test1(p, get(data, i, k))) out.unset(i);
}

fn meanOf(p: []const Vec3, idx: []const u32) Vec3 {
    var acc: [3]f64 = .{ 0, 0, 0 };
    for (idx) |i| for (0..3) |k| {
        acc[k] += p[i][k];
    };
    const n: f64 = @floatFromInt(idx.len);
    return .{ @floatCast(acc[0] / n), @floatCast(acc[1] / n), @floatCast(acc[2] / n) };
}

fn det3(m: Mat4) f32 {
    // Column-major: column c is m[4c .. 4c + 3].
    const a = v.axis(m, 0);
    const b = v.axis(m, 1);
    const c = v.axis(m, 2);
    return v.dot(a, v.cross(b, c));
}

const testing = std.testing;
const prims = @import("primitives.zig");

fn countSel(b: Bits) usize {
    return b.count();
}

test "normal cones, comparisons and set operations on a cube" {
    const gpa = testing.allocator;
    var m = try prims.generate(gpa, .cube, .{});
    defer m.releaseRefs(gpa);
    var diag: Diag = .{};

    var top = try evaluate(gpa, &m, .{ .domain = .face, .root = .{ .normal = .{ .dir = .{ 0, 0, 1 }, .cos_max = @cos(0.5) } } }, v.identity, &diag);
    defer top.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), countSel(top));

    const preds = [_]Pred{.{ .field = .z, .cmp = .gt, .value = 0.5 }};
    var upper = try evaluate(gpa, &m, .{ .domain = .vert, .root = .{ .where = &preds } }, v.identity, &diag);
    defer upper.deinit(gpa);
    try testing.expectEqual(@as(usize, 4), countSel(upper));

    // Every face but the top and the bottom.
    const caps = [_]Node{ .{ .normal = .{ .dir = .{ 0, 0, 1 }, .cos_max = 0.9 } }, .{ .normal = .{ .dir = .{ 0, 0, -1 }, .cos_max = 0.9 } } };
    const not_caps = [_]Node{.{ .any_of = &caps }};
    var sides = try evaluate(gpa, &m, .{ .domain = .face, .root = .{ .none_of = &not_caps } }, v.identity, &diag);
    defer sides.deinit(gpa);
    try testing.expectEqual(@as(usize, 4), countSel(sides));

    // World space: a 90° turn about X makes the +Y face the top one.
    const world = v.compose(.{ 0, 0, 0 }, v.quatAxisAngle(.{ 1, 0, 0 }, std.math.pi / 2.0), .{ 1, 1, 1 });
    var turned = try evaluate(gpa, &m, .{ .domain = .face, .root = .{ .normal = .{ .dir = .{ 0, 0, 1 }, .cos_max = 0.99 } } }, world, &diag);
    defer turned.deinit(gpa);
    var local = try evaluate(gpa, &m, .{ .domain = .face, .space = .local, .root = .{ .normal = .{ .dir = .{ 0, 1, 0 }, .cos_max = 0.99 } } }, world, &diag);
    defer local.deinit(gpa);
    try testing.expect(turned.eql(local));

    // A mirrored object keeps outward normals.
    const mirror = v.compose(.{ 0, 0, 0 }, v.quat_identity, .{ 1, 1, -1 });
    var mirrored = try evaluate(gpa, &m, .{ .domain = .face, .root = .{ .normal = .{ .dir = .{ 0, 0, 1 }, .cos_max = 0.99 } } }, mirror, &diag);
    defer mirrored.deinit(gpa);
    var bottom = try evaluate(gpa, &m, .{ .domain = .face, .space = .local, .root = .{ .normal = .{ .dir = .{ 0, 0, -1 }, .cos_max = 0.99 } } }, v.identity, &diag);
    defer bottom.deinit(gpa);
    try testing.expect(mirrored.eql(bottom));

    // Edge direction is undirected: the cube's 4 vertical edges, and under a
    // 90° turn about X the 4 edges along local Y.
    var vertical = try evaluate(gpa, &m, .{ .domain = .edge, .root = .{ .direction = .{ .dir = .{ 0, 0, -1 }, .cos_max = 0.99 } } }, v.identity, &diag);
    defer vertical.deinit(gpa);
    try testing.expectEqual(@as(usize, 4), countSel(vertical));
    var along_y = try evaluate(gpa, &m, .{ .domain = .edge, .space = .local, .root = .{ .direction = .{ .dir = .{ 0, 1, 0 }, .cos_max = 0.99 } } }, v.identity, &diag);
    defer along_y.deinit(gpa);
    var turned_v = try evaluate(gpa, &m, .{ .domain = .edge, .root = .{ .direction = .{ .dir = .{ 0, 0, 1 }, .cos_max = 0.99 } } }, world, &diag);
    defer turned_v.deinit(gpa);
    try testing.expect(turned_v.eql(along_y));
}

test "index ranges, attributes and domain conversion" {
    const gpa = testing.allocator;
    var m = try prims.generate(gpa, .grid, .{ .x_subdivisions = 4, .y_subdivisions = 4 });
    defer m.releaseRefs(gpa);
    var diag: Diag = .{};
    const ranges = [_]Range{ .{ 0, 3 }, .{ 8, 8 } };
    var sel = try evaluate(gpa, &m, .{ .domain = .face, .root = .{ .index = &ranges } }, v.identity, &diag);
    defer sel.deinit(gpa);
    try testing.expectEqual(@as(usize, 5), sel.count());

    const bad = [_]Range{.{ 0, 16 }};
    try testing.expectError(error.IndexOutOfRange, evaluate(gpa, &m, .{ .domain = .face, .root = .{ .index = &bad } }, v.identity, &diag));
    try testing.expectEqual(@as(u32, 16), diag.index);

    const sharp = [_]Pred{.{ .field = .{ .attribute = "sharp_face" }, .cmp = .eq, .value = 1 }};
    var flat = try evaluate(gpa, &m, .{ .domain = .face, .root = .{ .where = &sharp } }, v.identity, &diag);
    defer flat.deinit(gpa);
    try testing.expectEqual(@as(usize, 16), flat.count());
    const nope = [_]Pred{.{ .field = .{ .attribute = "weight" }, .cmp = .gt, .value = 0 }};
    try testing.expectError(error.UnknownAttribute, evaluate(gpa, &m, .{ .domain = .face, .root = .{ .where = &nope } }, v.identity, &diag));

    // The first row of 4 faces touches 10 grid vertices; those vertices
    // pick exactly the same 4 faces back.
    var row = try evaluate(gpa, &m, .{ .domain = .face, .root = .{ .index = ranges[0..1] } }, v.identity, &diag);
    defer row.deinit(gpa);
    var verts = try toVerts(gpa, &m, .face, &row);
    defer verts.deinit(gpa);
    try testing.expectEqual(@as(usize, 10), verts.count());
    var back = try toFaces(gpa, &m, .vert, &verts);
    defer back.deinit(gpa);
    try testing.expect(back.eql(row));
    var edges = try toEdges(gpa, &m, .face, &row);
    defer edges.deinit(gpa);
    try testing.expectEqual(@as(usize, 13), edges.count());
}
