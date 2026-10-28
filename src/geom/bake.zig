//! Baking procedural textures to images through a mesh's UV map, for
//! material.bake: every texel whose centre a face covers takes the
//! recipe's value at the matching surface point; normals bake as a
//! tangent-space normal map from the recipe's bump. Texels outside the UV
//! islands are filled outward from their edges (the margin), so filtering
//! does not pull in background at seams.

const std = @import("std");
const math = @import("math");
const core = @import("../core/root.zig");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const v = math.vec;
const Mesh = core.types.Mesh;
const Recipe = math.texture.Recipe;
const Input = core.types.TextureInput;

pub const Options = struct {
    width: u32,
    height: u32,
    /// Texels to grow each island by.
    margin: u32 = 4,
    /// Only faces with this material_index; null = all faces.
    slot: ?i32 = null,
    /// Value of texels no face or margin reaches.
    background: [4]f32 = .{ 0, 0, 0, 1 },
};

pub const Error = Allocator.Error || error{ NoUvMap, NoFaces };

pub const Result = struct {
    /// Bottom row first, as Blender images.
    pixels: [][4]f32,
    /// Texels covered by faces (before the margin).
    covered: usize,
};

const Point = struct { p: Vec3, n: Vec3, uv: [2]f32 };

pub fn bake(gpa: Allocator, m: *const Mesh, recipe: *const Recipe, input: Input, opts: Options) Error!Result {
    const uvs = if (m.attribute(Mesh.uv_name)) |a| switch (a.data) {
        .float2 => |s| if (a.domain == .corner) s.slice() else return error.NoUvMap,
        else => return error.NoUvMap,
    } else return error.NoUvMap;
    const mats: []const i32 = if (m.attribute("material_index")) |a| switch (a.data) {
        .int => |s| if (a.domain == .face) s.slice() else &.{},
        else => &.{},
    } else &.{};
    const pos = m.positions.slice();
    const off = m.face_offsets.slice();
    const cv = m.corner_verts.slice();
    if (off.len < 2) return error.NoFaces;

    // Smooth vertex normals (area weighted) and local bounds for generated
    // coordinates.
    const vn = try gpa.alloc(Vec3, pos.len);
    defer gpa.free(vn);
    @memset(vn, .{ 0, 0, 0 });
    for (0..off.len - 1) |f| {
        var n: Vec3 = .{ 0, 0, 0 };
        for (off[f]..off[f + 1]) |c| {
            const a = pos[cv[c]];
            const b = pos[cv[if (c + 1 == off[f + 1]) off[f] else c + 1]];
            n = v.add(n, v.cross(a, b));
        }
        for (off[f]..off[f + 1]) |c| vn[cv[c]] = v.add(vn[cv[c]], n);
    }
    for (vn) |*n| n.* = if (v.length(n.*) > 0) v.normalize(n.*) else .{ 0, 0, 1 };
    var lo = pos[0];
    var hi = pos[0];
    for (pos) |p| {
        lo = v.min3(lo, p);
        hi = v.max3(hi, p);
    }
    const ctx: Ctx = .{ .recipe = recipe, .lo = lo, .hi = hi };

    const w = opts.width;
    const h = opts.height;
    const pixels = try gpa.alloc([4]f32, @as(usize, w) * h);
    errdefer gpa.free(pixels);
    const filled = try gpa.alloc(bool, pixels.len);
    defer gpa.free(filled);
    @memset(filled, false);
    @memset(pixels, opts.background);
    var covered: usize = 0;
    const wf: f32 = @floatFromInt(w);
    const hf: f32 = @floatFromInt(h);

    for (0..off.len - 1) |f| {
        if (opts.slot) |s| if ((if (mats.len > 0) mats[f] else 0) != s) continue;
        // Fan triangulation; the UV-derived tangent frame is per triangle.
        const c0 = off[f];
        for (off[f] + 1..off[f + 1] - 1) |c1| {
            const tri = [3]Point{
                .{ .p = pos[cv[c0]], .n = vn[cv[c0]], .uv = uvs[c0] },
                .{ .p = pos[cv[c1]], .n = vn[cv[c1]], .uv = uvs[c1] },
                .{ .p = pos[cv[c1 + 1]], .n = vn[cv[c1 + 1]], .uv = uvs[c1 + 1] },
            };
            const frame = tangentFrame(tri);
            var xs: [3]f32 = undefined;
            var ys: [3]f32 = undefined;
            for (tri, 0..) |t, k| {
                xs[k] = t.uv[0] * wf;
                ys[k] = t.uv[1] * hf;
            }
            const area = (xs[1] - xs[0]) * (ys[2] - ys[0]) - (xs[2] - xs[0]) * (ys[1] - ys[0]);
            if (@abs(area) < 1e-12) continue;
            const x0: usize = @intFromFloat(std.math.clamp(@floor(@min(xs[0], @min(xs[1], xs[2]))), 0, wf - 1));
            const x1: usize = @intFromFloat(std.math.clamp(@ceil(@max(xs[0], @max(xs[1], xs[2]))), 0, wf - 1));
            const y0: usize = @intFromFloat(std.math.clamp(@floor(@min(ys[0], @min(ys[1], ys[2]))), 0, hf - 1));
            const y1: usize = @intFromFloat(std.math.clamp(@ceil(@max(ys[0], @max(ys[1], ys[2]))), 0, hf - 1));
            for (y0..y1 + 1) |py| for (x0..x1 + 1) |px| {
                const sx = @as(f32, @floatFromInt(px)) + 0.5;
                const sy = @as(f32, @floatFromInt(py)) + 0.5;
                const b0 = ((xs[1] - sx) * (ys[2] - sy) - (xs[2] - sx) * (ys[1] - sy)) / area;
                const b1 = ((xs[2] - sx) * (ys[0] - sy) - (xs[0] - sx) * (ys[2] - sy)) / area;
                const b2 = 1 - b0 - b1;
                const eps = -1e-5;
                if (b0 < eps or b1 < eps or b2 < eps) continue;
                const idx = py * w + px;
                if (filled[idx]) continue;
                const pt: Point = .{
                    .p = v.add(v.add(v.scale(tri[0].p, b0), v.scale(tri[1].p, b1)), v.scale(tri[2].p, b2)),
                    .n = v.normalize(v.add(v.add(v.scale(tri[0].n, b0), v.scale(tri[1].n, b1)), v.scale(tri[2].n, b2))),
                    .uv = .{ (sx) / wf, (sy) / hf },
                };
                pixels[idx] = ctx.value(input, pt, frame);
                filled[idx] = true;
                covered += 1;
            };
        }
    }
    try dilate(gpa, pixels, filled, w, h, opts.margin);
    return .{ .pixels = pixels, .covered = covered };
}

const Frame = struct { t: Vec3, b: Vec3 };

/// Tangent and bitangent from the triangle's UVs (directions of +u, +v).
fn tangentFrame(tri: [3]Point) Frame {
    const e1 = v.sub(tri[1].p, tri[0].p);
    const e2 = v.sub(tri[2].p, tri[0].p);
    const du1 = tri[1].uv[0] - tri[0].uv[0];
    const dv1 = tri[1].uv[1] - tri[0].uv[1];
    const du2 = tri[2].uv[0] - tri[0].uv[0];
    const dv2 = tri[2].uv[1] - tri[0].uv[1];
    const det = du1 * dv2 - du2 * dv1;
    if (@abs(det) < 1e-20) return .{ .t = .{ 1, 0, 0 }, .b = .{ 0, 1, 0 } };
    const r = 1 / det;
    return .{
        .t = v.scale(v.sub(v.scale(e1, dv2), v.scale(e2, dv1)), r),
        .b = v.scale(v.sub(v.scale(e2, du1), v.scale(e1, du2)), r),
    };
}

const Ctx = struct {
    recipe: *const Recipe,
    lo: Vec3,
    hi: Vec3,

    fn coords(c: Ctx, p: Vec3, n: Vec3, uv: [2]f32) Vec3 {
        return switch (c.recipe.coords) {
            .object => p,
            .normal => n,
            .uv => .{ uv[0], uv[1], 0 },
            .generated => blk: {
                var g: Vec3 = undefined;
                for (0..3) |k| g[k] = if (c.hi[k] > c.lo[k]) (p[k] - c.lo[k]) / (c.hi[k] - c.lo[k]) else 0.5;
                break :blk g;
            },
        };
    }

    fn value(c: Ctx, input: Input, pt: Point, fr: Frame) [4]f32 {
        switch (input) {
            .base_color, .emission_color => return c.recipe.eval(c.coords(pt.p, pt.n, pt.uv)),
            .metallic, .roughness => {
                const s = c.recipe.scalar(c.coords(pt.p, pt.n, pt.uv));
                return .{ s, s, s, 1 };
            },
            .normal => {
                const n = pt.n;
                // An orthonormal tangent frame around the shading normal.
                var t = v.sub(fr.t, v.scale(n, v.dot(fr.t, n)));
                t = if (v.length(t) > 1e-12) v.normalize(t) else perpendicular(n);
                var b = v.cross(n, t);
                if (v.dot(b, fr.b) < 0) b = v.scale(b, -1);
                // Blender's Bump: the surface gradient of the height, scaled
                // by distance, tilts the normal; strength blends it in.
                const eps: f32 = 1e-3;
                const sign: f32 = if (c.recipe.bump_invert) -1 else 1;
                const h = struct {
                    fn at(cc: Ctx, p: Vec3, nn: Vec3, uv: [2]f32) f32 {
                        return cc.recipe.scalar(cc.coords(p, nn, uv));
                    }
                }.at;
                const dt = (h(c, v.add(pt.p, v.scale(t, eps)), n, pt.uv) - h(c, v.sub(pt.p, v.scale(t, eps)), n, pt.uv)) / (2 * eps);
                const db = (h(c, v.add(pt.p, v.scale(b, eps)), n, pt.uv) - h(c, v.sub(pt.p, v.scale(b, eps)), n, pt.uv)) / (2 * eps);
                const grad = v.add(v.scale(t, dt * sign), v.scale(b, db * sign));
                const bumped = v.normalize(v.sub(n, v.scale(grad, c.recipe.bump_distance)));
                const out = v.normalize(v.add(n, v.scale(v.sub(bumped, n), c.recipe.bump_strength)));
                return .{ v.dot(out, t) * 0.5 + 0.5, v.dot(out, b) * 0.5 + 0.5, v.dot(out, n) * 0.5 + 0.5, 1 };
            },
        }
    }
};

fn perpendicular(n: Vec3) Vec3 {
    const a: Vec3 = if (@abs(n[0]) < 0.9) .{ 1, 0, 0 } else .{ 0, 1, 0 };
    return v.normalize(v.cross(a, n));
}

/// Grows filled texels outward `steps` times, each new texel the mean of
/// its filled 4-neighbours.
fn dilate(gpa: Allocator, pixels: [][4]f32, filled: []bool, w: u32, h: u32, steps: u32) Allocator.Error!void {
    const next = try gpa.dupe(bool, filled);
    defer gpa.free(next);
    for (0..steps) |_| {
        var grew = false;
        for (0..h) |y| for (0..w) |x| {
            const i = y * w + x;
            if (filled[i]) continue;
            var sum: [4]f32 = .{ 0, 0, 0, 0 };
            var n: f32 = 0;
            const nb = [4][2]i64{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
            for (nb) |d| {
                const nx = @as(i64, @intCast(x)) + d[0];
                const ny = @as(i64, @intCast(y)) + d[1];
                if (nx < 0 or ny < 0 or nx >= w or ny >= h) continue;
                const j: usize = @intCast(ny * w + nx);
                if (!filled[j]) continue;
                for (0..4) |k| sum[k] += pixels[j][k];
                n += 1;
            }
            if (n == 0) continue;
            for (0..4) |k| pixels[i][k] = sum[k] / n;
            next[i] = true;
            grew = true;
        };
        @memcpy(filled, next);
        if (!grew) break;
    }
}

const testing = std.testing;

test "bakes a recipe through UVs, with margin, and a flat bump to the neutral normal" {
    const gpa = testing.allocator;
    const prims = @import("primitives.zig");
    // A 2 m plane: UVs span 0..1, object coordinates -1..1.
    var plane = try prims.generate(gpa, .plane, .{});
    defer plane.releaseRefs(gpa);
    const r: Recipe = .{ .kind = .wave, .scale = 1, .direction = .x };
    const out = try bake(gpa, &plane, &r, .base_color, .{ .width = 16, .height = 16 });
    defer gpa.free(out.pixels);
    try testing.expectEqual(@as(usize, 256), out.covered);
    // Texel (3, 5): centre uv (3.5/16, 5.5/16) is object point (2u - 1, 2v - 1).
    const p: Vec3 = .{ 2 * 3.5 / 16.0 - 1, 2 * 5.5 / 16.0 - 1, 0 };
    try testing.expectApproxEqAbs(r.eval(p)[0], out.pixels[5 * 16 + 3][0], 1e-4);

    // A constant height bakes to the straight-up normal (0.5, 0.5, 1).
    const flat: Recipe = .{ .kind = .noise, .scale = 0 };
    const nrm = try bake(gpa, &plane, &flat, .normal, .{ .width = 8, .height = 8 });
    defer gpa.free(nrm.pixels);
    for (nrm.pixels) |px| {
        try testing.expectApproxEqAbs(@as(f32, 0.5), px[0], 1e-4);
        try testing.expectApproxEqAbs(@as(f32, 1), px[2], 1e-4);
    }
    try testing.expectError(error.NoUvMap, bake(gpa, &Mesh{}, &r, .base_color, .{ .width = 4, .height = 4 }));
}
