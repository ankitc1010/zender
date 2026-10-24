//! Small fixed-size vector, matrix and quaternion math.
//!
//! Conventions (TRD §6): right-handed, Z-up, metres, radians. Matrices are
//! column-major `[16]f32` (element `m[col * 4 + row]`), the layout glTF uses,
//! and act on column vectors: `p' = M · p`.

const std = @import("std");

pub const Vec3 = [3]f32;
pub const Vec4 = [4]f32;
/// Quaternion stored (x, y, z, w), the glTF order. Blender stores (w, x, y, z);
/// conversions happen in the .blend reader.
pub const Quat = [4]f32;
pub const Mat4 = [16]f32;

pub fn add(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

pub fn sub(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

pub fn scale(a: Vec3, s: f32) Vec3 {
    return .{ a[0] * s, a[1] * s, a[2] * s };
}

pub fn mul(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] * b[0], a[1] * b[1], a[2] * b[2] };
}

pub fn dot(a: Vec3, b: Vec3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

pub fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

pub fn length(a: Vec3) f32 {
    return @sqrt(dot(a, a));
}

/// Returns `a` scaled to unit length, or `a` unchanged when it is (near) zero.
pub fn normalize(a: Vec3) Vec3 {
    const l = length(a);
    if (l < 1e-20) return a;
    return scale(a, 1.0 / l);
}

pub fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t };
}

pub fn min3(a: Vec3, b: Vec3) Vec3 {
    return .{ @min(a[0], b[0]), @min(a[1], b[1]), @min(a[2], b[2]) };
}

pub fn max3(a: Vec3, b: Vec3) Vec3 {
    return .{ @max(a[0], b[0]), @max(a[1], b[1]), @max(a[2], b[2]) };
}

pub const identity: Mat4 = .{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
};

pub fn matMul(a: Mat4, b: Mat4) Mat4 {
    var r: Mat4 = undefined;
    for (0..4) |c| {
        for (0..4) |row| {
            var s: f32 = 0;
            for (0..4) |k| s += a[k * 4 + row] * b[c * 4 + k];
            r[c * 4 + row] = s;
        }
    }
    return r;
}

pub fn transformPoint(m: Mat4, p: Vec3) Vec3 {
    return .{
        m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12],
        m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13],
        m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[14],
    };
}

pub fn transformDir(m: Mat4, d: Vec3) Vec3 {
    return .{
        m[0] * d[0] + m[4] * d[1] + m[8] * d[2],
        m[1] * d[0] + m[5] * d[1] + m[9] * d[2],
        m[2] * d[0] + m[6] * d[1] + m[10] * d[2],
    };
}

pub fn translation(m: Mat4) Vec3 {
    return .{ m[12], m[13], m[14] };
}

/// Column `c` (0 = local X axis, 1 = Y, 2 = Z) of the upper 3×3.
pub fn axis(m: Mat4, c: usize) Vec3 {
    return .{ m[c * 4], m[c * 4 + 1], m[c * 4 + 2] };
}

/// T · R · S, the order Blender and glTF both use for a local transform.
pub fn compose(t: Vec3, r: Quat, s: Vec3) Mat4 {
    const rm = quatToMat(r);
    return .{
        rm[0] * s[0], rm[1] * s[0], rm[2] * s[0],  0,
        rm[4] * s[1], rm[5] * s[1], rm[6] * s[1],  0,
        rm[8] * s[2], rm[9] * s[2], rm[10] * s[2], 0,
        t[0],         t[1],         t[2],          1,
    };
}

/// Splits an affine matrix without shear into translation, rotation and scale.
/// A negative determinant is folded into the X scale.
pub fn decompose(m: Mat4) struct { t: Vec3, r: Quat, s: Vec3 } {
    var sx = length(axis(m, 0));
    const sy = length(axis(m, 1));
    const sz = length(axis(m, 2));
    const det = dot(axis(m, 0), cross(axis(m, 1), axis(m, 2)));
    if (det < 0) sx = -sx;
    const inv = [3]f32{
        if (sx != 0) 1.0 / sx else 0,
        if (sy != 0) 1.0 / sy else 0,
        if (sz != 0) 1.0 / sz else 0,
    };
    var rm = identity;
    for (0..3) |c| {
        for (0..3) |row| rm[c * 4 + row] = m[c * 4 + row] * inv[c];
    }
    return .{ .t = translation(m), .r = matToQuat(rm), .s = .{ sx, sy, sz } };
}

/// General 4×4 inverse; returns null when the matrix is singular.
pub fn invert(m: Mat4) ?Mat4 {
    var inv: Mat4 = undefined;
    inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
    inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
    inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
    inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
    inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
    inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
    inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
    inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
    inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
    inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
    inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
    inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
    inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
    inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
    inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
    inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];
    const det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
    if (det == 0 or !std.math.isFinite(det)) return null;
    const inv_det = 1.0 / det;
    for (&inv) |*v| v.* *= inv_det;
    return inv;
}

/// Inverse-transpose of the upper 3×3, for transforming normals. Columns are
/// returned in a Mat4 with zero translation.
pub fn normalMatrix(m: Mat4) Mat4 {
    const inv = invert(m) orelse return identity;
    var r = identity;
    for (0..3) |c| {
        for (0..3) |row| r[c * 4 + row] = inv[row * 4 + c];
    }
    return r;
}

pub fn perspective(yfov: f32, aspect: f32, near: f32, far: f32) Mat4 {
    const f = 1.0 / @tan(yfov / 2);
    return .{
        f / aspect, 0, 0,                             0,
        0,          f, 0,                             0,
        0,          0, (far + near) / (near - far),   -1,
        0,          0, 2 * far * near / (near - far), 0,
    };
}

pub fn orthographic(half_w: f32, half_h: f32, near: f32, far: f32) Mat4 {
    return .{
        1 / half_w, 0,          0,                            0,
        0,          1 / half_h, 0,                            0,
        0,          0,          -2 / (far - near),            0,
        0,          0,          -(far + near) / (far - near), 1,
    };
}

pub const quat_identity: Quat = .{ 0, 0, 0, 1 };

pub fn quatMul(a: Quat, b: Quat) Quat {
    return .{
        a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
        a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
        a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
        a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
    };
}

pub fn quatNormalize(q: Quat) Quat {
    const l = @sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    if (l < 1e-20) return quat_identity;
    return .{ q[0] / l, q[1] / l, q[2] / l, q[3] / l };
}

pub fn quatAxisAngle(ax: Vec3, angle: f32) Quat {
    const n = normalize(ax);
    const s = @sin(angle / 2);
    return .{ n[0] * s, n[1] * s, n[2] * s, @cos(angle / 2) };
}

pub fn quatToMat(q: Quat) Mat4 {
    const x = q[0];
    const y = q[1];
    const z = q[2];
    const w = q[3];
    return .{
        1 - 2 * (y * y + z * z), 2 * (x * y + z * w),     2 * (x * z - y * w),     0,
        2 * (x * y - z * w),     1 - 2 * (x * x + z * z), 2 * (y * z + x * w),     0,
        2 * (x * z + y * w),     2 * (y * z - x * w),     1 - 2 * (x * x + y * y), 0,
        0,                       0,                       0,                       1,
    };
}

/// Rotation part of a pure rotation matrix to a unit quaternion (Shepperd).
pub fn matToQuat(m: Mat4) Quat {
    const m00 = m[0];
    const m11 = m[5];
    const m22 = m[10];
    const tr = m00 + m11 + m22;
    var q: Quat = undefined;
    if (tr > 0) {
        const s = @sqrt(tr + 1.0) * 2;
        q = .{ (m[6] - m[9]) / s, (m[8] - m[2]) / s, (m[1] - m[4]) / s, 0.25 * s };
    } else if (m00 > m11 and m00 > m22) {
        const s = @sqrt(1.0 + m00 - m11 - m22) * 2;
        q = .{ 0.25 * s, (m[4] + m[1]) / s, (m[8] + m[2]) / s, (m[6] - m[9]) / s };
    } else if (m11 > m22) {
        const s = @sqrt(1.0 + m11 - m00 - m22) * 2;
        q = .{ (m[4] + m[1]) / s, 0.25 * s, (m[9] + m[6]) / s, (m[8] - m[2]) / s };
    } else {
        const s = @sqrt(1.0 + m22 - m00 - m11) * 2;
        q = .{ (m[8] + m[2]) / s, (m[9] + m[6]) / s, 0.25 * s, (m[1] - m[4]) / s };
    }
    // Canonical sign keeps output deterministic for equal rotations.
    if (q[3] < 0) q = .{ -q[0], -q[1], -q[2], -q[3] };
    return quatNormalize(q);
}

/// Euler rotation orders, named as Blender names them. `xyz` means X is applied
/// first, then Y, then Z, about the fixed parent axes: R = Rz · Ry · Rx.
pub const EulerOrder = enum { xyz, xzy, yxz, yzx, zxy, zyx };

pub fn eulerToQuat(e: Vec3, order: EulerOrder) Quat {
    const qx = quatAxisAngle(.{ 1, 0, 0 }, e[0]);
    const qy = quatAxisAngle(.{ 0, 1, 0 }, e[1]);
    const qz = quatAxisAngle(.{ 0, 0, 1 }, e[2]);
    // Later rotations multiply on the left.
    return quatNormalize(switch (order) {
        .xyz => quatMul(qz, quatMul(qy, qx)),
        .xzy => quatMul(qy, quatMul(qz, qx)),
        .yxz => quatMul(qz, quatMul(qx, qy)),
        .yzx => quatMul(qx, quatMul(qz, qy)),
        .zxy => quatMul(qy, quatMul(qx, qz)),
        .zyx => quatMul(qx, quatMul(qy, qz)),
    });
}

/// Inverse of `eulerToQuat` for order XYZ (R = Rz·Ry·Rx), the Blender default.
pub fn quatToEulerXyz(q: Quat) Vec3 {
    const m = quatToMat(q);
    // R[2][0] = -sin(y) with R[row][col]; column-major index col*4+row.
    const r20 = m[0 * 4 + 2];
    const y = std.math.asin(std.math.clamp(-r20, -1.0, 1.0));
    if (@abs(r20) < 0.999999) {
        const x = std.math.atan2(m[1 * 4 + 2], m[2 * 4 + 2]);
        const z = std.math.atan2(m[0 * 4 + 1], m[0 * 4 + 0]);
        return .{ x, y, z };
    }
    // Gimbal lock: fold all of the remaining rotation into Z.
    const z = std.math.atan2(-m[1 * 4 + 0], m[1 * 4 + 1]);
    return .{ 0, y, z };
}

/// Rotation that turns local -Z towards `dir` with local +Y as close to
/// `up` as possible: the orientation a Blender camera or light needs to look
/// along `dir`.
pub fn lookRotation(dir: Vec3, up: Vec3) Quat {
    const f = normalize(dir);
    var r = cross(f, up);
    if (length(r) < 1e-6) r = cross(f, if (@abs(f[2]) < 0.9) Vec3{ 0, 0, 1 } else Vec3{ 0, 1, 0 });
    r = normalize(r);
    const u = cross(r, f);
    // Local axes: X = right, Y = up, Z = -forward.
    const m: Mat4 = .{
        r[0],  r[1],  r[2],  0,
        u[0],  u[1],  u[2],  0,
        -f[0], -f[1], -f[2], 0,
        0,     0,     0,     1,
    };
    return matToQuat(m);
}

pub fn degToRad(d: f32) f32 {
    return d * (std.math.pi / 180.0);
}

pub fn radToDeg(r: f32) f32 {
    return r * (180.0 / std.math.pi);
}

const testing = std.testing;

fn expectVec(a: Vec3, b: Vec3, tol: f32) !void {
    for (0..3) |i| try testing.expectApproxEqAbs(a[i], b[i], tol);
}

test "euler XYZ applies X, then Y, then Z" {
    const q = eulerToQuat(.{ degToRad(90), 0, degToRad(90) }, .xyz);
    // +Y: X(90°) takes it to +Z, Z(90°) leaves +Z alone.
    try expectVec(transformDir(quatToMat(q), .{ 0, 1, 0 }), .{ 0, 0, 1 }, 1e-6);
    // +X: X leaves it, Z(90°) takes it to +Y.
    try expectVec(transformDir(quatToMat(q), .{ 1, 0, 0 }), .{ 0, 1, 0 }, 1e-6);
}

test "euler round trip" {
    const e = Vec3{ 0.3, -0.7, 2.1 };
    const back = quatToEulerXyz(eulerToQuat(e, .xyz));
    try expectVec(back, e, 1e-5);
}

test "compose, decompose and invert" {
    const q = eulerToQuat(.{ 0.1, 0.2, 0.3 }, .xyz);
    const m = compose(.{ 1, 2, 3 }, q, .{ 2, 3, 4 });
    const d = decompose(m);
    try expectVec(d.t, .{ 1, 2, 3 }, 1e-6);
    try expectVec(d.s, .{ 2, 3, 4 }, 1e-5);
    const inv = invert(m).?;
    const p = transformPoint(inv, transformPoint(m, .{ 0.5, -1, 7 }));
    try expectVec(p, .{ 0.5, -1, 7 }, 1e-4);
}

test "look rotation points -Z along the direction" {
    const q = lookRotation(.{ 1, 1, -1 }, .{ 0, 0, 1 });
    const m = quatToMat(q);
    try expectVec(transformDir(m, .{ 0, 0, -1 }), normalize(.{ 1, 1, -1 }), 1e-6);
    // Up vector stays in the plane spanned by forward and world Z.
    try testing.expect(transformDir(m, .{ 0, 1, 0 })[2] > 0);
}
