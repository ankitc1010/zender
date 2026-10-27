//! Deterministic 3D value noise for the displace modifier: the same point
//! and seed give the same value on every platform (integer hashing, no
//! platform libm calls).

const std = @import("std");
const math = @import("math");

const Vec3 = math.Vec3;

fn hash(x: i32, y: i32, z: i32, seed: u32) u32 {
    var h: u32 = seed *% 0x9E3779B9;
    h ^= @as(u32, @bitCast(x)) *% 0x85EBCA6B;
    h = std.math.rotl(u32, h, 13);
    h ^= @as(u32, @bitCast(y)) *% 0xC2B2AE35;
    h = std.math.rotl(u32, h, 17);
    h ^= @as(u32, @bitCast(z)) *% 0x27D4EB2F;
    h ^= h >> 15;
    h *%= 0x2C1B3C6D;
    h ^= h >> 12;
    h *%= 0x297A2D39;
    h ^= h >> 15;
    return h;
}

fn lattice(x: i32, y: i32, z: i32, seed: u32) f32 {
    return @as(f32, @floatFromInt(hash(x, y, z, seed) >> 8)) / 16777215.0;
}

fn fade(t: f32) f32 {
    return t * t * t * (t * (t * 6 - 15) + 10);
}

/// Value noise in [0, 1], smooth between integer lattice points.
pub fn value(p: Vec3, seed: u32) f32 {
    const fl: [3]f32 = .{ @floor(p[0]), @floor(p[1]), @floor(p[2]) };
    const i: [3]i32 = .{ clampInt(fl[0]), clampInt(fl[1]), clampInt(fl[2]) };
    const f: [3]f32 = .{ fade(p[0] - fl[0]), fade(p[1] - fl[1]), fade(p[2] - fl[2]) };
    var acc: f32 = 0;
    for (0..8) |c| {
        const dx: i32 = @intCast(c & 1);
        const dy: i32 = @intCast((c >> 1) & 1);
        const dz: i32 = @intCast((c >> 2) & 1);
        const w = (if (dx == 1) f[0] else 1 - f[0]) * (if (dy == 1) f[1] else 1 - f[1]) * (if (dz == 1) f[2] else 1 - f[2]);
        acc += w * lattice(i[0] +% dx, i[1] +% dy, i[2] +% dz, seed);
    }
    return acc;
}

fn clampInt(x: f32) i32 {
    return @intFromFloat(std.math.clamp(x, -1e9, 1e9));
}

/// Three octaves, each half the size and half the weight: [0, 1].
pub fn fbm(p: Vec3, seed: u32) f32 {
    var sum: f32 = 0;
    var amp: f32 = 0.5;
    var q = p;
    for (0..3) |k| {
        sum += amp * value(q, seed +% @as(u32, @intCast(k)) *% 7919);
        q = math.vec.scale(q, 2);
        amp *= 0.5;
    }
    return sum / 0.875;
}

test "noise is smooth, bounded and seeded" {
    const a = fbm(.{ 0.3, 1.7, -2.2 }, 1);
    try std.testing.expect(a >= 0 and a <= 1);
    try std.testing.expectEqual(a, fbm(.{ 0.3, 1.7, -2.2 }, 1));
    try std.testing.expect(a != fbm(.{ 0.3, 1.7, -2.2 }, 2));
    // At lattice points value noise equals the hashed value.
    try std.testing.expectEqual(lattice(2, 3, 4, 9), value(.{ 2, 3, 4 }, 9));
    // Nearby points give nearby values.
    try std.testing.expect(@abs(value(.{ 1.5, 1.5, 1.5 }, 3) - value(.{ 1.501, 1.5, 1.5 }, 3)) < 0.01);
}
