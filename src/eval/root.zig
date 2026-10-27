//! Evaluation: transforms, the depsgraph and modifier stacks, evaluated
//! meshes and the flattened interchange scene. Animation arrives in P2.

pub const flatten = @import("flatten.zig");
pub const cache = @import("cache.zig");
pub const depsgraph = @import("depsgraph.zig");
pub const Cache = cache.Cache;

test {
    _ = flatten;
    _ = cache;
    _ = depsgraph;
}
