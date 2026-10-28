//! Platform layer (layer 5): math, triangulation and the shared parallel pool.
//! Imports nothing but std.

pub const vec = @import("vec.zig");
pub const triangulate = @import("triangulate.zig");
pub const texture = @import("texture.zig");
pub const Pool = @import("pool.zig").Pool;
pub const Deadline = @import("pool.zig").Deadline;
pub const DeadlineError = @import("pool.zig").DeadlineError;

pub const Vec3 = vec.Vec3;
pub const Vec4 = vec.Vec4;
pub const Quat = vec.Quat;
pub const Mat4 = vec.Mat4;

test {
    _ = vec;
    _ = triangulate;
    _ = texture;
    _ = @import("pool.zig");
}
