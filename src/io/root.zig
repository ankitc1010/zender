//! File I/O layer: image codecs and scene exchange formats. Works on `ir`
//! scenes and byte streams only; path checks live in the command core.

pub const png = @import("image/png.zig");
pub const gltf = @import("gltf/export.zig");

test {
    _ = png;
    _ = gltf;
}
