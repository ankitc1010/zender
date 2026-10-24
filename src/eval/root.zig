//! Evaluation: transforms, evaluated meshes and the flattened interchange
//! scene. The depsgraph and animation arrive in P1/P2.

pub const flatten = @import("flatten.zig");
pub const cache = @import("cache.zig");
pub const Cache = cache.Cache;

test {
    _ = flatten;
    _ = cache;
}
