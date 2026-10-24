//! Geometry kernel: mesh construction, normals and primitives. Operators,
//! selectors and modifiers arrive in P1.

pub const build = @import("build.zig");
pub const normals = @import("normals.zig");
pub const primitives = @import("primitives.zig");

test {
    _ = build;
    _ = normals;
    _ = primitives;
}
