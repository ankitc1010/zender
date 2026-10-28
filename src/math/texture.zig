//! Procedural textures: Blender's Noise (fBM), Wave and Voronoi (F1) nodes
//! with Mapping and Color Ramp, as Cycles evaluates them. Cycles is
//! Apache-2.0, so its kernels may be ported (TRD licence position); the
//! hashing, Perlin gradients, fractal sums and ramp table follow it, so a
//! recipe and its Blender node tree give the same values. f32 throughout,
//! integer hashing, no fused multiply-add: the same on every target.

const std = @import("std");
const vec = @import("vec.zig");

const Vec3 = vec.Vec3;

pub const Kind = enum { noise, wave, voronoi };
pub const Coords = enum { object, generated, uv, normal };
pub const WaveType = enum { bands, rings };
pub const Direction = enum { x, y, z, diagonal, spherical };
pub const Profile = enum { sine, saw, tri };
pub const RampMode = enum { linear, ease, constant };
pub const Output = enum { value, color };

pub const max_stops = 16;

pub const Ramp = struct {
    mode: RampMode = .linear,
    count: u8 = 0,
    pos: [max_stops]f32 = @splat(0),
    color: [max_stops][4]f32 = @splat(.{ 0, 0, 0, 1 }),
};

/// One texture node, its mapping and an optional ramp: what a material
/// input, a displacement or a relief reads.
pub const Recipe = struct {
    kind: Kind = .noise,
    coords: Coords = .object,
    location: Vec3 = .{ 0, 0, 0 },
    /// Euler XYZ, radians.
    rotation: Vec3 = .{ 0, 0, 0 },
    map_scale: Vec3 = .{ 1, 1, 1 },
    scale: f32 = 5,
    detail: f32 = 2,
    roughness: f32 = 0.5,
    lacunarity: f32 = 2,
    distortion: f32 = 0,
    wave_type: WaveType = .bands,
    direction: Direction = .x,
    profile: Profile = .sine,
    phase: f32 = 0,
    detail_scale: f32 = 1,
    detail_roughness: f32 = 0.5,
    randomness: f32 = 1,
    output: Output = .value,
    ramp: Ramp = .{},
    /// For a normal input: Blender's Bump node settings.
    bump_strength: f32 = 1,
    bump_distance: f32 = 1,
    bump_invert: bool = false,

    /// RGBA at a texture-space point (before mapping).
    pub fn eval(r: *const Recipe, p_in: Vec3) [4]f32 {
        const p = r.map(p_in);
        const v = r.raw(p);
        if (r.ramp.count > 0) return rampEval(&r.ramp, v[0]);
        return v;
    }

    /// The value a factor input reads: the colour's luminance, or Fac.
    pub fn scalar(r: *const Recipe, p: Vec3) f32 {
        const c = r.eval(p);
        if (r.ramp.count == 0 and r.output == .value) return c[0];
        return luminance(c);
    }

    fn map(r: *const Recipe, p: Vec3) Vec3 {
        const s = vec.mul(p, r.map_scale);
        const m = vec.quatToMat(vec.eulerToQuat(r.rotation, .xyz));
        return vec.add(vec.transformDir(m, s), r.location);
    }

    fn raw(r: *const Recipe, p: Vec3) [4]f32 {
        switch (r.kind) {
            .noise => {
                const x = noiseTexture(vec.scale(p, r.scale), r.detail, r.roughness, r.lacunarity, r.distortion);
                return .{ x, x, x, 1 };
            },
            .wave => {
                const x = wave(r.wave_type, r.direction, r.profile, vec.scale(p, r.scale), r.distortion, r.detail, r.detail_scale, r.detail_roughness, r.phase);
                return .{ x, x, x, 1 };
            },
            .voronoi => {
                const o = voronoiF1(vec.scale(p, r.scale), r.randomness);
                return if (r.output == .color) .{ o.color[0], o.color[1], o.color[2], 1 } else .{ o.distance, o.distance, o.distance, 1 };
            },
        }
    }
};

/// Blender's scene-linear Rec.709 luminance, as the colour-to-float socket
/// conversion uses.
pub fn luminance(c: [4]f32) f32 {
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}

// ---------------------------------------------------------------- hashing

fn rot(x: u32, comptime k: u5) u32 {
    return std.math.rotl(u32, x, k);
}

fn final(a: *u32, b: *u32, c: *u32) void {
    c.* ^= b.*;
    c.* -%= rot(b.*, 14);
    a.* ^= c.*;
    a.* -%= rot(c.*, 11);
    b.* ^= a.*;
    b.* -%= rot(a.*, 25);
    c.* ^= b.*;
    c.* -%= rot(b.*, 16);
    a.* ^= c.*;
    a.* -%= rot(c.*, 4);
    b.* ^= a.*;
    b.* -%= rot(a.*, 14);
    c.* ^= b.*;
    c.* -%= rot(b.*, 24);
}

fn mixHash(a: *u32, b: *u32, c: *u32) void {
    a.* -%= c.*;
    a.* ^= rot(c.*, 4);
    c.* +%= b.*;
    b.* -%= a.*;
    b.* ^= rot(a.*, 6);
    a.* +%= c.*;
    c.* -%= b.*;
    c.* ^= rot(b.*, 8);
    b.* +%= a.*;
    a.* -%= c.*;
    a.* ^= rot(c.*, 16);
    c.* +%= b.*;
    b.* -%= a.*;
    b.* ^= rot(a.*, 19);
    a.* +%= c.*;
    c.* -%= b.*;
    c.* ^= rot(b.*, 4);
    b.* +%= a.*;
}

/// Jenkins lookup3, as Cycles' hash_uint2/3/4.
pub fn hash2(kx: u32, ky: u32) u32 {
    var a: u32 = 0xdeadbeef +% (2 << 2) +% 13;
    var b = a;
    var c = a;
    b +%= ky;
    a +%= kx;
    final(&a, &b, &c);
    return c;
}

pub fn hash3(kx: u32, ky: u32, kz: u32) u32 {
    var a: u32 = 0xdeadbeef +% (3 << 2) +% 13;
    var b = a;
    var c = a;
    c +%= kz;
    b +%= ky;
    a +%= kx;
    final(&a, &b, &c);
    return c;
}

pub fn hash4(kx: u32, ky: u32, kz: u32, kw: u32) u32 {
    var a: u32 = 0xdeadbeef +% (4 << 2) +% 13;
    var b = a;
    var c = a;
    a +%= kx;
    b +%= ky;
    c +%= kz;
    mixHash(&a, &b, &c);
    a +%= kw;
    final(&a, &b, &c);
    return c;
}

fn toUnit(h: u32) f32 {
    return @as(f32, @floatFromInt(h)) / @as(f32, @floatFromInt(@as(u32, 0xFFFFFFFF)));
}

fn bits(x: f32) u32 {
    return @bitCast(x);
}

fn ibits(x: i32) u32 {
    return @bitCast(x);
}

// ---------------------------------------------------------------- Perlin

fn fade(t: f32) f32 {
    return t * t * t * (t * (t * 6 - 15) + 10);
}

fn grad3(hash: u32, x: f32, y: f32, z: f32) f32 {
    const h = hash & 15;
    const u = if (h < 8) x else y;
    const vt = if (h == 12 or h == 14) x else z;
    const v = if (h < 4) y else vt;
    return (if (h & 1 != 0) -u else u) + (if (h & 2 != 0) -v else v);
}

fn perlin(p: Vec3) f32 {
    const fx = @floor(p[0]);
    const fy = @floor(p[1]);
    const fz = @floor(p[2]);
    const X: i32 = @intFromFloat(fx);
    const Y: i32 = @intFromFloat(fy);
    const Z: i32 = @intFromFloat(fz);
    const x = p[0] - fx;
    const y = p[1] - fy;
    const z = p[2] - fz;
    const u = fade(x);
    const v = fade(y);
    const w = fade(z);
    const g = struct {
        fn at(i: i32, j: i32, k: i32, a: f32, b: f32, c: f32) f32 {
            return grad3(hash3(ibits(i), ibits(j), ibits(k)), a, b, c);
        }
    }.at;
    const v0 = g(X, Y, Z, x, y, z);
    const v1 = g(X + 1, Y, Z, x - 1, y, z);
    const v2 = g(X, Y + 1, Z, x, y - 1, z);
    const v3 = g(X + 1, Y + 1, Z, x - 1, y - 1, z);
    const v4 = g(X, Y, Z + 1, x, y, z - 1);
    const v5 = g(X + 1, Y, Z + 1, x - 1, y, z - 1);
    const v6 = g(X, Y + 1, Z + 1, x, y - 1, z - 1);
    const v7 = g(X + 1, Y + 1, Z + 1, x - 1, y - 1, z - 1);
    const x1 = 1 - u;
    const y1 = 1 - v;
    const z1 = 1 - w;
    return z1 * (y1 * (v0 * x1 + v1 * u) + v * (v2 * x1 + v3 * u)) + w * (y1 * (v4 * x1 + v5 * u) + v * (v6 * x1 + v7 * u));
}

/// Signed noise in about -1..1, as Cycles' snoise_3d.
pub fn snoise(p_in: Vec3) f32 {
    // Cycles wraps large coordinates to keep precision.
    var p = p_in;
    for (&p) |*c| c.* = @rem(c.*, 100000.0);
    const r = 0.982 * perlin(p);
    return if (std.math.isFinite(r)) r else 0;
}

/// Fractal Brownian motion, normalised to 0..1.
pub fn fbm(p: Vec3, detail_in: f32, roughness: f32, lacunarity: f32) f32 {
    const detail = std.math.clamp(detail_in, 0, 15);
    var fscale: f32 = 1;
    var amp: f32 = 1;
    var maxamp: f32 = 0;
    var sum: f32 = 0;
    const octaves: u32 = @intFromFloat(detail);
    var i: u32 = 0;
    while (i <= octaves) : (i += 1) {
        const t = snoise(vec.scale(p, fscale));
        sum += t * amp;
        maxamp += amp;
        amp *= @max(roughness, 0);
        fscale *= lacunarity;
    }
    const rmd = detail - @floor(detail);
    if (rmd != 0) {
        const t = snoise(vec.scale(p, fscale));
        const sum2 = sum + t * amp;
        const a = 0.5 * sum / maxamp + 0.5;
        const b = 0.5 * sum2 / (maxamp + amp) + 0.5;
        return a + (b - a) * rmd;
    }
    return 0.5 * sum / maxamp + 0.5;
}

fn randomOffset(seed: f32) Vec3 {
    return .{
        100 + toUnit(hash2(bits(seed), bits(@as(f32, 0)))) * 100,
        100 + toUnit(hash2(bits(seed), bits(@as(f32, 1)))) * 100,
        100 + toUnit(hash2(bits(seed), bits(@as(f32, 2)))) * 100,
    };
}

/// The Noise Texture node's Fac (fBM, normalised) at p = vector x scale.
pub fn noiseTexture(p_in: Vec3, detail: f32, roughness: f32, lacunarity: f32, distortion: f32) f32 {
    var p = p_in;
    if (distortion != 0) {
        p = vec.add(p, .{
            snoise(vec.add(p, randomOffset(0))) * distortion,
            snoise(vec.add(p, randomOffset(1))) * distortion,
            snoise(vec.add(p, randomOffset(2))) * distortion,
        });
    }
    return fbm(p, detail, roughness, lacunarity);
}

// ---------------------------------------------------------------- wave

pub fn wave(kind: WaveType, dir: Direction, profile: Profile, p_in: Vec3, distortion: f32, detail: f32, dscale: f32, droughness: f32, phase: f32) f32 {
    // As Cycles: nudge off exact unit coordinates.
    const p = vec.scale(vec.add(p_in, @splat(0.000001)), 0.999999);
    var n: f32 = switch (kind) {
        .bands => switch (dir) {
            .x => p[0] * 20,
            .y => p[1] * 20,
            .z => p[2] * 20,
            .diagonal, .spherical => (p[0] + p[1] + p[2]) * 10,
        },
        .rings => blk: {
            var rp = p;
            switch (dir) {
                .x => rp[0] = 0,
                .y => rp[1] = 0,
                .z => rp[2] = 0,
                .diagonal, .spherical => {},
            }
            break :blk vec.length(rp) * 20;
        },
    };
    n += phase;
    if (distortion != 0) n += distortion * (fbm(vec.scale(p, dscale), detail, droughness, 2) * 2 - 1);
    const two_pi: f32 = 2 * std.math.pi;
    return switch (profile) {
        .sine => 0.5 + 0.5 * @sin(n - std.math.pi / 2.0),
        .saw => blk: {
            const t = n / two_pi;
            break :blk t - @floor(t);
        },
        .tri => blk: {
            const t = n / two_pi;
            break :blk @abs(t - @floor(t + 0.5)) * 2;
        },
    };
}

// ---------------------------------------------------------------- Voronoi

pub const VoronoiOut = struct { distance: f32, color: Vec3 };

// Cells are hashed by the bits of their float coordinates, as Cycles does.

fn hashFloat3ToFloat3(x: f32, y: f32, z: f32) Vec3 {
    return .{
        toUnit(hash3(bits(x), bits(y), bits(z))),
        toUnit(hash4(bits(x), bits(y), bits(z), bits(@as(f32, 1)))),
        toUnit(hash4(bits(x), bits(y), bits(z), bits(@as(f32, 2)))),
    };
}

/// F1, Euclidean, one octave (Blender 4's default Voronoi).
pub fn voronoiF1(coord: Vec3, randomness: f32) VoronoiOut {
    const cf = Vec3{ @floor(coord[0]), @floor(coord[1]), @floor(coord[2]) };
    const local = vec.sub(coord, cf);
    var min_d: f32 = std.math.floatMax(f32);
    var target: [3]i32 = .{ 0, 0, 0 };
    var k: i32 = -1;
    while (k <= 1) : (k += 1) {
        var j: i32 = -1;
        while (j <= 1) : (j += 1) {
            var i: i32 = -1;
            while (i <= 1) : (i += 1) {
                const h = hashFloat3ToFloat3(cf[0] + @as(f32, @floatFromInt(i)), cf[1] + @as(f32, @floatFromInt(j)), cf[2] + @as(f32, @floatFromInt(k)));
                const point = Vec3{ @as(f32, @floatFromInt(i)) + h[0] * randomness, @as(f32, @floatFromInt(j)) + h[1] * randomness, @as(f32, @floatFromInt(k)) + h[2] * randomness };
                const d = vec.length(vec.sub(point, local));
                if (d < min_d) {
                    min_d = d;
                    target = .{ i, j, k };
                }
            }
        }
    }
    return .{ .distance = min_d, .color = hashFloat3ToFloat3(cf[0] + @as(f32, @floatFromInt(target[0])), cf[1] + @as(f32, @floatFromInt(target[1])), cf[2] + @as(f32, @floatFromInt(target[2]))) };
}

// ---------------------------------------------------------------- color ramp

/// Blender's ColorBand evaluation at t (stops sorted by position).
pub fn rampExact(r: *const Ramp, t: f32) [4]f32 {
    const n = r.count;
    if (n == 0) return .{ t, t, t, 1 };
    if (t <= r.pos[0]) return r.color[0];
    if (t >= r.pos[n - 1]) return r.color[n - 1];
    var i: usize = 0;
    while (i + 1 < n and r.pos[i + 1] <= t) i += 1;
    if (r.mode == .constant) return r.color[i];
    const span = r.pos[i + 1] - r.pos[i];
    var f = if (span > 0) (t - r.pos[i]) / span else 0;
    if (r.mode == .ease) f = f * f * (3 - 2 * f);
    var out: [4]f32 = undefined;
    for (0..4) |c| out[c] = r.color[i][c] + (r.color[i + 1][c] - r.color[i][c]) * f;
    return out;
}

const table_size = 257;

/// As Cycles: the ramp baked to a table of 257 entries at i / 256, read at
/// fac x 256 with linear interpolation (or none, for constant ramps), so a
/// constant ramp steps where its table does, up to 1/256 past the stop.
pub fn rampEval(r: *const Ramp, fac: f32) [4]f32 {
    const f = std.math.clamp(fac, 0, 1) * (table_size - 1);
    const i: usize = @intFromFloat(std.math.clamp(@floor(f), 0, table_size - 1));
    const t = f - @as(f32, @floatFromInt(i));
    const a = rampExact(r, @as(f32, @floatFromInt(i)) / (table_size - 1));
    if (r.mode == .constant or t <= 0 or i + 1 >= table_size) return a;
    const b = rampExact(r, @as(f32, @floatFromInt(i + 1)) / (table_size - 1));
    var out: [4]f32 = undefined;
    for (0..4) |c| out[c] = (1 - t) * a[c] + t * b[c];
    return out;
}

/// Mean RGBA over a fixed lattice of the texture-space box [lo, hi]: what
/// renderers without texture evaluation show (the preview until P3, glTF
/// without a bake).
pub fn mean(r: *const Recipe, lo: Vec3, hi: Vec3) [4]f32 {
    const n = 12;
    var sum: [4]f32 = .{ 0, 0, 0, 0 };
    for (0..n) |i| for (0..n) |j| for (0..n) |k| {
        const f = Vec3{ (@as(f32, @floatFromInt(i)) + 0.5) / n, (@as(f32, @floatFromInt(j)) + 0.5) / n, (@as(f32, @floatFromInt(k)) + 0.5) / n };
        const p = vec.add(lo, vec.mul(vec.sub(hi, lo), f));
        const c = r.eval(p);
        for (0..4) |q| sum[q] += c[q];
    };
    for (&sum) |*s| s.* /= n * n * n;
    return sum;
}

// ---------------------------------------------------------------- recipes from JSON

/// What a recipe parse rejected: the key (a path below the recipe) and why.
pub const ParseDiag = struct {
    key: []const u8 = "",
    message: []const u8 = "",
};

const Value = std.json.Value;

fn num(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn fail(diag: *ParseDiag, key: []const u8, message: []const u8) error{Invalid} {
    diag.* = .{ .key = key, .message = message };
    return error.Invalid;
}

fn getF(o: std.json.ObjectMap, key: []const u8, lo: f64, hi: f64, out: *f32, diag: *ParseDiag) error{Invalid}!void {
    const v = o.get(key) orelse return;
    const x = num(v) orelse return fail(diag, key, "must be a number");
    if (!(x >= lo and x <= hi)) return fail(diag, key, "is out of range");
    out.* = @floatCast(x);
}

fn getVec(v: Value, key: []const u8, out: *Vec3, diag: *ParseDiag) error{Invalid}!void {
    const a = if (v == .array and v.array.items.len == 3) v.array.items else return fail(diag, key, "must be [x, y, z]");
    for (a, out) |x, *o| {
        const f = num(x) orelse return fail(diag, key, "must hold numbers");
        if (!(@abs(f) <= 1e6)) return fail(diag, key, "is out of range");
        o.* = @floatCast(f);
    }
}

fn getEnum(comptime E: type, o: std.json.ObjectMap, key: []const u8, out: *E, diag: *ParseDiag) error{Invalid}!void {
    const v = o.get(key) orelse return;
    out.* = (if (v == .string) std.meta.stringToEnum(E, v.string) else null) orelse return fail(diag, key, "has an unknown value");
}

pub const recipe_keys = [_][]const u8{ "texture", "coords", "mapping", "scale", "detail", "roughness", "lacunarity", "distortion", "wave_type", "direction", "profile", "phase", "detail_scale", "detail_roughness", "randomness", "output", "ramp", "strength", "distance", "invert" };

/// Reads a recipe object: {texture: noise|wave|voronoi, coords, mapping
/// {location, rotation (degrees), scale}, the node's inputs, ramp {mode,
/// stops [[position, [r, g, b(, a)]], ...]}, and for normals strength,
/// distance, invert}.
pub fn parse(o: std.json.ObjectMap, diag: *ParseDiag) error{Invalid}!Recipe {
    var it = o.iterator();
    outer: while (it.next()) |e| {
        for (recipe_keys) |k| if (std.mem.eql(u8, k, e.key_ptr.*)) continue :outer;
        return fail(diag, e.key_ptr.*, "is not a recipe key");
    }
    var r: Recipe = .{};
    const tv = o.get("texture") orelse return fail(diag, "texture", "is missing (noise, wave or voronoi)");
    r.kind = (if (tv == .string) std.meta.stringToEnum(Kind, tv.string) else null) orelse return fail(diag, "texture", "must be noise, wave or voronoi");
    try getEnum(Coords, o, "coords", &r.coords, diag);
    if (o.get("mapping")) |m| {
        if (m != .object) return fail(diag, "mapping", "must be an object");
        var mit = m.object.iterator();
        while (mit.next()) |e| {
            const k = e.key_ptr.*;
            if (std.mem.eql(u8, k, "location")) {
                try getVec(e.value_ptr.*, "mapping/location", &r.location, diag);
            } else if (std.mem.eql(u8, k, "rotation")) {
                var d: Vec3 = undefined;
                try getVec(e.value_ptr.*, "mapping/rotation", &d, diag);
                r.rotation = .{ vec.degToRad(d[0]), vec.degToRad(d[1]), vec.degToRad(d[2]) };
            } else if (std.mem.eql(u8, k, "scale")) {
                try getVec(e.value_ptr.*, "mapping/scale", &r.map_scale, diag);
            } else return fail(diag, "mapping", "takes location, rotation and scale");
        }
    }
    try getF(o, "scale", -1000, 1000, &r.scale, diag);
    try getF(o, "detail", 0, 15, &r.detail, diag);
    try getF(o, "roughness", 0, 1, &r.roughness, diag);
    try getF(o, "lacunarity", 0, 1000, &r.lacunarity, diag);
    try getF(o, "distortion", -1000, 1000, &r.distortion, diag);
    try getEnum(WaveType, o, "wave_type", &r.wave_type, diag);
    try getEnum(Direction, o, "direction", &r.direction, diag);
    try getEnum(Profile, o, "profile", &r.profile, diag);
    try getF(o, "phase", -1e5, 1e5, &r.phase, diag);
    try getF(o, "detail_scale", -1000, 1000, &r.detail_scale, diag);
    try getF(o, "detail_roughness", 0, 1, &r.detail_roughness, diag);
    try getF(o, "randomness", 0, 1, &r.randomness, diag);
    try getEnum(Output, o, "output", &r.output, diag);
    try getF(o, "strength", 0, 1, &r.bump_strength, diag);
    try getF(o, "distance", 0, 1000, &r.bump_distance, diag);
    if (o.get("invert")) |v| r.bump_invert = v == .bool and v.bool;
    if (r.wave_type == .bands and r.direction == .spherical) return fail(diag, "direction", "spherical applies to rings");
    if (r.wave_type == .rings and r.direction == .diagonal) return fail(diag, "direction", "diagonal applies to bands");
    if (o.get("ramp")) |rv| {
        if (rv != .object) return fail(diag, "ramp", "must be an object");
        try getEnum(RampMode, rv.object, "mode", &r.ramp.mode, diag);
        const sv = rv.object.get("stops") orelse return fail(diag, "ramp/stops", "is missing");
        const stops = if (sv == .array) sv.array.items else return fail(diag, "ramp/stops", "must be a list");
        if (stops.len < 1 or stops.len > max_stops) return fail(diag, "ramp/stops", "needs 1 to 16 stops");
        var last: f32 = -1;
        for (stops, 0..) |st, i| {
            const pair = if (st == .array and st.array.items.len == 2) st.array.items else return fail(diag, "ramp/stops", "each stop is [position, [r, g, b]]");
            const pos = num(pair[0]) orelse return fail(diag, "ramp/stops", "positions must be numbers");
            if (!(pos >= 0 and pos <= 1) or pos < last) return fail(diag, "ramp/stops", "positions must rise from 0 to 1");
            last = @floatCast(pos);
            const col = if (pair[1] == .array and (pair[1].array.items.len == 3 or pair[1].array.items.len == 4)) pair[1].array.items else return fail(diag, "ramp/stops", "colours are [r, g, b] or [r, g, b, a]");
            r.ramp.pos[i] = @floatCast(pos);
            r.ramp.color[i] = .{ 0, 0, 0, 1 };
            for (col, 0..) |c, k| {
                const f = num(c) orelse return fail(diag, "ramp/stops", "colours must hold numbers");
                if (!(f >= 0 and f <= 1e4)) return fail(diag, "ramp/stops", "colours must be at least 0");
                r.ramp.color[i][k] = @floatCast(f);
            }
        }
        r.ramp.count = @intCast(stops.len);
    }
    return r;
}

/// Writes a recipe back as JSON, defaults included, for readback and the
/// canonical scene.
pub fn write(r: *const Recipe, w: *std.json.Stringify) std.json.Stringify.Error!void {
    try w.beginObject();
    try w.objectField("texture");
    try w.write(@tagName(r.kind));
    try w.objectField("coords");
    try w.write(@tagName(r.coords));
    try w.objectField("mapping");
    try w.beginObject();
    try w.objectField("location");
    try w.write(r.location);
    try w.objectField("rotation");
    try w.write(Vec3{ vec.radToDeg(r.rotation[0]), vec.radToDeg(r.rotation[1]), vec.radToDeg(r.rotation[2]) });
    try w.objectField("scale");
    try w.write(r.map_scale);
    try w.endObject();
    try w.objectField("scale");
    try w.write(r.scale);
    switch (r.kind) {
        .noise => {
            inline for (.{ "detail", "roughness", "lacunarity", "distortion" }) |k| {
                try w.objectField(k);
                try w.write(@field(r, k));
            }
        },
        .wave => {
            try w.objectField("wave_type");
            try w.write(@tagName(r.wave_type));
            try w.objectField("direction");
            try w.write(@tagName(r.direction));
            try w.objectField("profile");
            try w.write(@tagName(r.profile));
            inline for (.{ "phase", "distortion", "detail", "detail_scale", "detail_roughness" }) |k| {
                try w.objectField(k);
                try w.write(@field(r, k));
            }
        },
        .voronoi => {
            try w.objectField("randomness");
            try w.write(r.randomness);
            try w.objectField("output");
            try w.write(@tagName(r.output));
        },
    }
    if (r.ramp.count > 0) {
        try w.objectField("ramp");
        try w.beginObject();
        try w.objectField("mode");
        try w.write(@tagName(r.ramp.mode));
        try w.objectField("stops");
        try w.beginArray();
        for (0..r.ramp.count) |i| {
            try w.beginArray();
            try w.write(r.ramp.pos[i]);
            try w.write(r.ramp.color[i]);
            try w.endArray();
        }
        try w.endArray();
        try w.endObject();
    }
    try w.endObject();
}

const testing = std.testing;

test "hashes and Perlin noise behave like Cycles' building blocks" {
    // Lattice points: Perlin noise is zero there.
    try testing.expectEqual(@as(f32, 0), perlin(.{ 3, -2, 7 }));
    // Range and continuity.
    var lo: f32 = 1;
    var hi: f32 = -1;
    for (0..2000) |i| {
        const t = @as(f32, @floatFromInt(i)) * 0.0137;
        const x = snoise(.{ t, t * 0.7 + 0.3, 1.1 - t * 0.2 });
        lo = @min(lo, x);
        hi = @max(hi, x);
        const y = snoise(.{ t + 1e-4, t * 0.7 + 0.3, 1.1 - t * 0.2 });
        try testing.expect(@abs(x - y) < 1e-2);
    }
    try testing.expect(lo > -1.05 and hi < 1.05 and hi - lo > 0.8);
    try testing.expect(hash3(1, 2, 3) != hash3(3, 2, 1));
}

test "ramp table, constant steps and ease" {
    var r: Ramp = .{ .mode = .constant, .count = 2 };
    r.pos[0] = 0.25;
    r.pos[1] = 0.75;
    r.color[0] = .{ 1, 0, 0, 1 };
    r.color[1] = .{ 0, 0, 1, 1 };
    try testing.expectEqual(@as(f32, 1), rampEval(&r, 0.5)[0]);
    try testing.expectEqual(@as(f32, 1), rampEval(&r, 0.9)[2]);
    r.mode = .linear;
    try testing.expectApproxEqAbs(@as(f32, 0.5), rampEval(&r, 0.5)[0], 5e-3);
    r.mode = .ease;
    try testing.expectApproxEqAbs(@as(f32, 0.84375), rampExact(&r, 0.375)[0], 1e-6);
}

test "kernels match Blender's own nodes (Cycles renders of 13 recipes)" {
    const gpa = testing.allocator;
    const text = @embedFile("testdata/blender_texture_refs.json");
    const parsed = try std.json.parseFromSlice(Value, gpa, text, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const n: usize = @intCast(root.get("size").?.integer);
    const z: f32 = @floatCast(num(root.get("z").?).?);
    const stride: usize = if (root.get("stride")) |x| @intCast(x.integer) else 1;
    var bad: usize = 0;
    for (root.get("recipes").?.array.items) |entry| {
        const rec_obj = entry.object.get("recipe").?.object;
        var copy = try rec_obj.clone(gpa);
        defer copy.deinit(gpa);
        const name = copy.get("name").?.string;
        _ = copy.orderedRemove("name");
        var diag: ParseDiag = .{};
        const r = parse(copy, &diag) catch {
            std.debug.print("{s}: {s} {s}\n", .{ name, diag.key, diag.message });
            return error.TestUnexpectedResult;
        };
        const rgb = entry.object.get("rgb").?.array.items;
        var worst: f32 = 0;
        var off: usize = 0;
        // Cycles' pixel filter is 0.01 px wide, so a sample may sit up to
        // 0.005 px from the centre: allow the local slope times that.
        const jitter = 0.005 * 2 / @as(f32, @floatFromInt(n * stride));
        for (rgb, 0..) |px, i| {
            const row = i / n;
            const col = i % n;
            // Pixel (row, col) of the n x stride render, every stride-th kept.
            const wf: f32 = @floatFromInt(n * stride);
            const half: f32 = @floatFromInt(stride / 2);
            const sf: f32 = @floatFromInt(stride);
            const p = Vec3{ -1 + (@as(f32, @floatFromInt(col)) * sf + half + 0.5) * 2 / wf, -1 + (@as(f32, @floatFromInt(row)) * sf + half + 0.5) * 2 / wf, z };
            const got = r.eval(p);
            var slope: f32 = 0;
            for (0..2) |axis| {
                var d: Vec3 = .{ 0, 0, 0 };
                d[axis] = 1e-3;
                const a = r.eval(vec.add(p, d));
                const b = r.eval(vec.sub(p, d));
                for (0..3) |c| slope = @max(slope, @abs(a[c] - b[c]) / 2e-3);
            }
            var e: f32 = 0;
            for (0..3) |c| e = @max(e, @abs(got[c] - @as(f32, @floatCast(num(px.array.items[c]).?))));
            worst = @max(worst, e);
            if (e > 1e-4 + 1.5 * slope * jitter) off += 1;
        }
        if (off > 0) {
            std.debug.print("{s}: max error {e:.2}, {d} of {d} pixels beyond slope x offset + 1e-4\n", .{ name, worst, off, rgb.len });
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}
