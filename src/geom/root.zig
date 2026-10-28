//! Geometry kernel: mesh construction, normals, primitives, the EditMesh
//! boundary representation, selectors and mesh operators.

pub const build = @import("build.zig");
pub const normals = @import("normals.zig");
pub const primitives = @import("primitives.zig");
pub const revolve = @import("revolve.zig");
pub const sdf = @import("sdf.zig");
pub const curve = @import("curve.zig");
pub const bake = @import("bake.zig");
pub const editmesh = @import("editmesh.zig");
pub const EditMesh = editmesh.EditMesh;
pub const select = @import("select.zig");
pub const ops = @import("ops.zig");
pub const uv = @import("uv.zig");
pub const modifiers = @import("modifiers.zig");

test {
    _ = build;
    _ = normals;
    _ = primitives;
    _ = revolve;
    _ = sdf;
    _ = curve;
    _ = bake;
    _ = editmesh;
    _ = select;
    _ = ops;
    _ = uv;
    _ = modifiers;
}
