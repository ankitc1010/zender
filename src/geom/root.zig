//! Geometry kernel: mesh construction, normals, primitives, the EditMesh
//! boundary representation, selectors and mesh operators.

pub const build = @import("build.zig");
pub const normals = @import("normals.zig");
pub const primitives = @import("primitives.zig");
pub const editmesh = @import("editmesh.zig");
pub const EditMesh = editmesh.EditMesh;
pub const select = @import("select.zig");
pub const ops = @import("ops.zig");

test {
    _ = build;
    _ = normals;
    _ = primitives;
    _ = editmesh;
    _ = select;
    _ = ops;
}
