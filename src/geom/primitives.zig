//! Mesh primitives with Blender's default parameters, outward winding and a
//! UV map. Like Blender 4.1+, faces start flat (sharp) unless `smooth` is set.
//! Each generator is a pure function of its parameters (FR-GEO-1).

const std = @import("std");
const math = @import("math");
const core = @import("../core/root.zig");
const build = @import("build.zig");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const Mesh = core.types.Mesh;
const tau = 2 * std.math.pi;

pub const Kind = enum { cube, plane, grid, uv_sphere, ico_sphere, cylinder, cone, torus };

pub const Params = struct {
    /// Edge length for cube, plane and grid.
    size: f32 = 2,
    radius: f32 = 1,
    /// Cone tip radius (Blender's radius2).
    radius_top: f32 = 0,
    depth: f32 = 2,
    /// Around the axis: UV sphere segments, cylinder and cone vertices.
    segments: u32 = 32,
    rings: u32 = 16,
    subdivisions: u32 = 2,
    x_subdivisions: u32 = 10,
    y_subdivisions: u32 = 10,
    major_radius: f32 = 1,
    minor_radius: f32 = 0.25,
    major_segments: u32 = 48,
    minor_segments: u32 = 12,
    fill_caps: bool = true,
    smooth: bool = false,
};

/// Limits the generators accept; tools validate against the same numbers.
pub const limits = struct {
    pub const max_segments = 4096;
    pub const max_subdivisions = 10;
    pub const max_grid = 4096;
};

pub const Error = build.BuildError || error{InvalidParameter};

const Builder = struct {
    gpa: Allocator,
    pos: std.ArrayList(Vec3) = .empty,
    offsets: std.ArrayList(u32) = .empty,
    corners: std.ArrayList(u32) = .empty,
    uvs: std.ArrayList([2]f32) = .empty,

    fn init(gpa: Allocator) Allocator.Error!Builder {
        var b: Builder = .{ .gpa = gpa };
        try b.offsets.append(gpa, 0);
        return b;
    }

    fn deinit(b: *Builder) void {
        b.pos.deinit(b.gpa);
        b.offsets.deinit(b.gpa);
        b.corners.deinit(b.gpa);
        b.uvs.deinit(b.gpa);
    }

    fn vert(b: *Builder, p: Vec3) Allocator.Error!u32 {
        try b.pos.append(b.gpa, p);
        return @intCast(b.pos.items.len - 1);
    }

    fn face(b: *Builder, verts: []const u32, uvs: []const [2]f32) Allocator.Error!void {
        std.debug.assert(verts.len == uvs.len);
        try b.corners.appendSlice(b.gpa, verts);
        try b.uvs.appendSlice(b.gpa, uvs);
        try b.offsets.append(b.gpa, @intCast(b.corners.items.len));
    }

    fn finish(b: *Builder, smooth: bool) Error!Mesh {
        const n_faces = b.offsets.items.len - 1;
        const sharp = try b.gpa.alloc(bool, n_faces);
        defer b.gpa.free(sharp);
        @memset(sharp, !smooth);
        return build.fromPolygons(b.gpa, .{
            .positions = b.pos.items,
            .face_offsets = b.offsets.items,
            .corner_verts = b.corners.items,
            .corner_uvs = b.uvs.items,
            .sharp_face = sharp,
        });
    }
};

pub fn generate(gpa: Allocator, kind: Kind, p: Params) Error!Mesh {
    var b = try Builder.init(gpa);
    defer b.deinit();
    switch (kind) {
        .plane => try grid(&b, p.size, 1, 1),
        .grid => {
            if (p.x_subdivisions < 1 or p.y_subdivisions < 1 or p.x_subdivisions > limits.max_grid or p.y_subdivisions > limits.max_grid) return error.InvalidParameter;
            try grid(&b, p.size, p.x_subdivisions, p.y_subdivisions);
        },
        .cube => try cube(&b, p.size / 2),
        .uv_sphere => {
            if (p.segments < 3 or p.rings < 3 or p.segments > limits.max_segments or p.rings > limits.max_segments) return error.InvalidParameter;
            try uvSphere(&b, p.radius, p.segments, p.rings);
        },
        .ico_sphere => {
            if (p.subdivisions < 1 or p.subdivisions > limits.max_subdivisions) return error.InvalidParameter;
            try icoSphere(&b, p.radius, p.subdivisions);
        },
        .cylinder => {
            if (p.segments < 3 or p.segments > limits.max_segments) return error.InvalidParameter;
            try cone(&b, p.radius, p.radius, p.depth, p.segments, p.fill_caps);
        },
        .cone => {
            if (p.segments < 3 or p.segments > limits.max_segments) return error.InvalidParameter;
            try cone(&b, p.radius, p.radius_top, p.depth, p.segments, p.fill_caps);
        },
        .torus => {
            if (p.major_segments < 3 or p.minor_segments < 3 or p.major_segments > limits.max_segments or p.minor_segments > limits.max_segments) return error.InvalidParameter;
            try torus(&b, p.major_radius, p.minor_radius, p.major_segments, p.minor_segments);
        },
    }
    return b.finish(p.smooth);
}

fn grid(b: *Builder, size: f32, nx: u32, ny: u32) Allocator.Error!void {
    const h = size / 2;
    for (0..ny + 1) |j| {
        for (0..nx + 1) |i| {
            const fx = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(nx));
            const fy = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(ny));
            _ = try b.vert(.{ -h + fx * size, -h + fy * size, 0 });
        }
    }
    const row = nx + 1;
    for (0..ny) |j| {
        for (0..nx) |i| {
            const v0: u32 = @intCast(j * row + i);
            const ua = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(nx));
            const ub = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(nx));
            const w0 = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(ny));
            const w1 = @as(f32, @floatFromInt(j + 1)) / @as(f32, @floatFromInt(ny));
            try b.face(&.{ v0, v0 + 1, v0 + 1 + row, v0 + row }, &.{ .{ ua, w0 }, .{ ub, w0 }, .{ ub, w1 }, .{ ua, w1 } });
        }
    }
}

fn cube(b: *Builder, h: f32) Allocator.Error!void {
    // Vertex order of Blender's default cube.
    const corners = [8]Vec3{
        .{ h, h, h },  .{ h, h, -h },  .{ h, -h, h },  .{ h, -h, -h },
        .{ -h, h, h }, .{ -h, h, -h }, .{ -h, -h, h }, .{ -h, -h, -h },
    };
    for (corners) |c| _ = try b.vert(c);
    // Faces wound counter-clockwise seen from outside, laid out on Blender's
    // default cube unwrap: a vertical strip of four with two side wings.
    const Face = struct { v: [4]u32, uv: [4][2]f32 };
    const faces = [6]Face{
        .{ .v = .{ 0, 4, 6, 2 }, .uv = .{ .{ 0.625, 0.5 }, .{ 0.875, 0.5 }, .{ 0.875, 0.75 }, .{ 0.625, 0.75 } } }, // +Z
        .{ .v = .{ 3, 2, 6, 7 }, .uv = .{ .{ 0.375, 0.75 }, .{ 0.625, 0.75 }, .{ 0.625, 1.0 }, .{ 0.375, 1.0 } } }, // -Y
        .{ .v = .{ 7, 6, 4, 5 }, .uv = .{ .{ 0.375, 0.0 }, .{ 0.625, 0.0 }, .{ 0.625, 0.25 }, .{ 0.375, 0.25 } } }, // -X
        .{ .v = .{ 5, 1, 3, 7 }, .uv = .{ .{ 0.125, 0.5 }, .{ 0.375, 0.5 }, .{ 0.375, 0.75 }, .{ 0.125, 0.75 } } }, // -Z
        .{ .v = .{ 1, 0, 2, 3 }, .uv = .{ .{ 0.375, 0.5 }, .{ 0.625, 0.5 }, .{ 0.625, 0.75 }, .{ 0.375, 0.75 } } }, // +X
        .{ .v = .{ 5, 4, 0, 1 }, .uv = .{ .{ 0.375, 0.25 }, .{ 0.625, 0.25 }, .{ 0.625, 0.5 }, .{ 0.375, 0.5 } } }, // +Y
    };
    for (faces) |f| try b.face(&f.v, &f.uv);
}

fn uvSphere(b: *Builder, r: f32, segments: u32, rings: u32) Allocator.Error!void {
    const top = try b.vert(.{ 0, 0, r });
    // Ring vertices from top to bottom, excluding the poles.
    for (1..rings) |j| {
        const theta = std.math.pi * @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(rings));
        for (0..segments) |i| {
            const phi = tau * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
            _ = try b.vert(.{ r * @sin(theta) * @cos(phi), r * @sin(theta) * @sin(phi), r * @cos(theta) });
        }
    }
    const bottom = try b.vert(.{ 0, 0, -r });
    const seg_f: f32 = @floatFromInt(segments);
    const ring_f: f32 = @floatFromInt(rings);
    const ringVert = struct {
        fn f(j: usize, i: usize, segs: u32) u32 {
            return @intCast(1 + (j - 1) * segs + (i % segs));
        }
    }.f;
    for (0..segments) |i| {
        const u_0 = @as(f32, @floatFromInt(i)) / seg_f;
        const u_1 = @as(f32, @floatFromInt(i + 1)) / seg_f;
        const u_m = (u_0 + u_1) / 2;
        // Top cap triangle.
        const v1 = 1 - 1 / ring_f;
        try b.face(&.{ top, ringVert(1, i, segments), ringVert(1, i + 1, segments) }, &.{ .{ u_m, 1 }, .{ u_0, v1 }, .{ u_1, v1 } });
        // Quads between rings.
        for (1..rings - 1) |j| {
            const va = 1 - @as(f32, @floatFromInt(j)) / ring_f;
            const vb = 1 - @as(f32, @floatFromInt(j + 1)) / ring_f;
            try b.face(
                &.{ ringVert(j, i, segments), ringVert(j + 1, i, segments), ringVert(j + 1, i + 1, segments), ringVert(j, i + 1, segments) },
                &.{ .{ u_0, va }, .{ u_0, vb }, .{ u_1, vb }, .{ u_1, va } },
            );
        }
        // Bottom cap triangle.
        const vl = 1 / ring_f;
        try b.face(&.{ ringVert(rings - 1, i, segments), bottom, ringVert(rings - 1, i + 1, segments) }, &.{ .{ u_0, vl }, .{ u_m, 0 }, .{ u_1, vl } });
    }
}

fn cone(b: *Builder, r_bottom: f32, r_top: f32, depth: f32, n: u32, caps: bool) Allocator.Error!void {
    const h = depth / 2;
    const n_f: f32 = @floatFromInt(n);
    const top_is_point = r_top == 0;
    const bottom_is_point = r_bottom == 0;
    const bottom_start: u32 = @intCast(b.pos.items.len);
    if (bottom_is_point) {
        _ = try b.vert(.{ 0, 0, -h });
    } else for (0..n) |i| {
        const a = tau * @as(f32, @floatFromInt(i)) / n_f;
        _ = try b.vert(.{ r_bottom * @cos(a), r_bottom * @sin(a), -h });
    }
    const top_start: u32 = @intCast(b.pos.items.len);
    if (top_is_point) {
        _ = try b.vert(.{ 0, 0, h });
    } else for (0..n) |i| {
        const a = tau * @as(f32, @floatFromInt(i)) / n_f;
        _ = try b.vert(.{ r_top * @cos(a), r_top * @sin(a), h });
    }
    const bot = struct {
        fn f(start: u32, point: bool, i: usize, count: u32) u32 {
            return if (point) start else start + @as(u32, @intCast(i % count));
        }
    }.f;
    // Sides occupy the lower half of UV space.
    for (0..n) |i| {
        const u_0 = @as(f32, @floatFromInt(i)) / n_f;
        const u_1 = @as(f32, @floatFromInt(i + 1)) / n_f;
        const b0 = bot(bottom_start, bottom_is_point, i, n);
        const b1 = bot(bottom_start, bottom_is_point, i + 1, n);
        const t0 = bot(top_start, top_is_point, i, n);
        const t1 = bot(top_start, top_is_point, i + 1, n);
        if (top_is_point) {
            try b.face(&.{ b0, b1, t0 }, &.{ .{ u_0, 0 }, .{ u_1, 0 }, .{ (u_0 + u_1) / 2, 0.5 } });
        } else if (bottom_is_point) {
            try b.face(&.{ b0, t1, t0 }, &.{ .{ (u_0 + u_1) / 2, 0 }, .{ u_1, 0.5 }, .{ u_0, 0.5 } });
        } else {
            try b.face(&.{ b0, b1, t1, t0 }, &.{ .{ u_0, 0 }, .{ u_1, 0 }, .{ u_1, 0.5 }, .{ u_0, 0.5 } });
        }
    }
    if (!caps) return;
    // N-gon caps as circles in the upper half of UV space.
    var verts = try b.gpa.alloc(u32, n);
    defer b.gpa.free(verts);
    var uvs = try b.gpa.alloc([2]f32, n);
    defer b.gpa.free(uvs);
    if (!top_is_point) {
        for (0..n) |i| {
            const a = tau * @as(f32, @floatFromInt(i)) / n_f;
            verts[i] = top_start + @as(u32, @intCast(i));
            uvs[i] = .{ 0.75 + 0.24 * @cos(a), 0.75 + 0.24 * @sin(a) };
        }
        try b.face(verts, uvs);
    }
    if (!bottom_is_point) {
        // Reversed so the bottom faces -Z.
        for (0..n) |k| {
            const i = n - 1 - k;
            const a = tau * @as(f32, @floatFromInt(i)) / n_f;
            verts[k] = bottom_start + @as(u32, @intCast(i));
            uvs[k] = .{ 0.25 + 0.24 * @cos(a), 0.75 - 0.24 * @sin(a) };
        }
        try b.face(verts, uvs);
    }
}

fn torus(b: *Builder, major: f32, minor: f32, nu: u32, nv: u32) Allocator.Error!void {
    const nu_f: f32 = @floatFromInt(nu);
    const nv_f: f32 = @floatFromInt(nv);
    for (0..nu) |i| {
        const a = tau * @as(f32, @floatFromInt(i)) / nu_f;
        for (0..nv) |j| {
            const c = tau * @as(f32, @floatFromInt(j)) / nv_f;
            const rr = major + minor * @cos(c);
            _ = try b.vert(.{ rr * @cos(a), rr * @sin(a), minor * @sin(c) });
        }
    }
    for (0..nu) |i| {
        for (0..nv) |j| {
            const inext = (i + 1) % nu;
            const j1 = (j + 1) % nv;
            const v00: u32 = @intCast(i * nv + j);
            const v10: u32 = @intCast(inext * nv + j);
            const v11: u32 = @intCast(inext * nv + j1);
            const v01: u32 = @intCast(i * nv + j1);
            const u_0 = @as(f32, @floatFromInt(i)) / nu_f;
            const u_1 = @as(f32, @floatFromInt(i + 1)) / nu_f;
            const w0 = @as(f32, @floatFromInt(j)) / nv_f;
            const w1 = @as(f32, @floatFromInt(j + 1)) / nv_f;
            try b.face(&.{ v00, v10, v11, v01 }, &.{ .{ u_0, w0 }, .{ u_1, w0 }, .{ u_1, w1 }, .{ u_0, w1 } });
        }
    }
}

fn icoSphere(b: *Builder, r: f32, subdivisions: u32) Error!void {
    const gpa = b.gpa;
    var pos: std.ArrayList(Vec3) = .empty;
    defer pos.deinit(gpa);
    var tris: std.ArrayList([3]u32) = .empty;
    defer tris.deinit(gpa);

    // Icosahedron with a vertex at each pole.
    const z = 1.0 / @sqrt(5.0);
    const rr = 2.0 / @sqrt(5.0);
    try pos.append(gpa, .{ 0, 0, 1 });
    for (0..5) |i| {
        const a = tau * @as(f32, @floatFromInt(i)) / 5;
        try pos.append(gpa, .{ rr * @cos(a), rr * @sin(a), z });
    }
    for (0..5) |i| {
        const a = tau * (@as(f32, @floatFromInt(i)) + 0.5) / 5;
        try pos.append(gpa, .{ rr * @cos(a), rr * @sin(a), -z });
    }
    try pos.append(gpa, .{ 0, 0, -1 });
    for (0..5) |i| {
        const u_i: u32 = @intCast(1 + i);
        const u_n: u32 = @intCast(1 + (i + 1) % 5);
        const l_i: u32 = @intCast(6 + i);
        const l_p: u32 = @intCast(6 + (i + 4) % 5);
        try tris.append(gpa, .{ 0, u_i, u_n });
        try tris.append(gpa, .{ u_i, l_i, u_n });
        try tris.append(gpa, .{ u_i, l_p, l_i });
        try tris.append(gpa, .{ 11, l_i, l_p });
    }

    var level: u32 = 1;
    while (level < subdivisions) : (level += 1) {
        var mid: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        defer mid.deinit(gpa);
        var next: std.ArrayList([3]u32) = .empty;
        errdefer next.deinit(gpa);
        for (tris.items) |t| {
            var m: [3]u32 = undefined;
            for (0..3) |k| {
                const a = t[k];
                const c = t[(k + 1) % 3];
                const key = (@as(u64, @min(a, c)) << 32) | @max(a, c);
                const gop = try mid.getOrPut(gpa, key);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(pos.items.len);
                    try pos.append(gpa, math.vec.normalize(math.vec.lerp(pos.items[a], pos.items[c], 0.5)));
                }
                m[k] = gop.value_ptr.*;
            }
            try next.appendSlice(gpa, &.{ .{ t[0], m[0], m[2] }, .{ m[0], t[1], m[1] }, .{ m[2], m[1], t[2] }, .{ m[0], m[1], m[2] } });
        }
        tris.deinit(gpa);
        tris = next;
    }

    for (pos.items) |p| _ = try b.vert(math.vec.scale(p, r));
    for (tris.items) |t| {
        var uv: [3][2]f32 = undefined;
        for (0..3) |k| uv[k] = sphericalUv(pos.items[t[k]]);
        // Keep triangles that straddle the seam on one side of it.
        const lo = @min(uv[0][0], @min(uv[1][0], uv[2][0]));
        const hi = @max(uv[0][0], @max(uv[1][0], uv[2][0]));
        if (hi - lo > 0.5) {
            for (&uv) |*c| if (c[0] < 0.5) {
                c[0] += 1;
            };
        }
        try b.face(&t, &uv);
    }
}

fn sphericalUv(p: Vec3) [2]f32 {
    const u = 0.5 + std.math.atan2(p[1], p[0]) / tau;
    const w = 0.5 + std.math.asin(std.math.clamp(p[2], -1.0, 1.0)) / std.math.pi;
    return .{ u, w };
}

const testing = std.testing;

fn signedVolume(m: *const Mesh) f32 {
    const gpa = testing.allocator;
    const pos = m.positions.slice();
    const off = m.face_offsets.slice();
    const cv = m.corner_verts.slice();
    var tri: std.ArrayList(u32) = .empty;
    defer tri.deinit(gpa);
    var vol: f32 = 0;
    for (0..m.faceCount()) |f| {
        tri.clearRetainingCapacity();
        const corners = cv[off[f]..off[f + 1]];
        math.triangulate.triangulate(gpa, pos, corners, &tri) catch unreachable;
        var t: usize = 0;
        while (t < tri.items.len) : (t += 3) {
            const a = pos[corners[tri.items[t]]];
            const b = pos[corners[tri.items[t + 1]]];
            const c = pos[corners[tri.items[t + 2]]];
            vol += math.vec.dot(a, math.vec.cross(b, c)) / 6;
        }
    }
    return vol;
}

test "closed primitives have Blender's counts and positive volume" {
    const gpa = testing.allocator;
    const Case = struct { kind: Kind, verts: usize, faces: usize, volume: f32, tol: f32 };
    const cases = [_]Case{
        .{ .kind = .cube, .verts = 8, .faces = 6, .volume = 8, .tol = 1e-4 },
        .{ .kind = .uv_sphere, .verts = 482, .faces = 512, .volume = 4.0 / 3.0 * std.math.pi, .tol = 0.1 },
        .{ .kind = .ico_sphere, .verts = 42, .faces = 80, .volume = 4.0 / 3.0 * std.math.pi, .tol = 0.6 },
        .{ .kind = .cylinder, .verts = 64, .faces = 34, .volume = 2 * std.math.pi, .tol = 0.05 },
        .{ .kind = .cone, .verts = 33, .faces = 33, .volume = 2.0 / 3.0 * std.math.pi, .tol = 0.05 },
        .{ .kind = .torus, .verts = 576, .faces = 576, .volume = 2 * std.math.pi * std.math.pi * 0.0625, .tol = 0.08 },
    };
    for (cases) |c| {
        var m = try generate(gpa, c.kind, .{});
        defer m.releaseRefs(gpa);
        try testing.expectEqual(c.verts, m.vertCount());
        try testing.expectEqual(c.faces, m.faceCount());
        try testing.expect(build.validate(&m) == null);
        try testing.expectApproxEqAbs(c.volume, signedVolume(&m), c.tol);
    }
}

test "grid and plane" {
    const gpa = testing.allocator;
    var g = try generate(gpa, .grid, .{});
    defer g.releaseRefs(gpa);
    try testing.expectEqual(@as(usize, 121), g.vertCount());
    try testing.expectEqual(@as(usize, 100), g.faceCount());
    try testing.expectEqual(@as(usize, 220), g.edgeCount());
    var p = try generate(gpa, .plane, .{ .size = 4 });
    defer p.releaseRefs(gpa);
    // Blender order: (-1,-1), (1,-1), (-1,1), (1,1), scaled.
    try testing.expectEqual([3]f32{ 2, -2, 0 }, p.positions.slice()[1]);
    try testing.expectEqual([3]f32{ -2, 2, 0 }, p.positions.slice()[2]);
}
