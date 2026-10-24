//! Engine layer: the data model (core), the geometry kernel (geom) and
//! evaluation (eval). Only this layer reads or writes scene data.

pub const core = @import("core/root.zig");
pub const geom = @import("geom/root.zig");
pub const eval = @import("eval/root.zig");
/// The interchange types flatten produces, for callers above this layer.
pub const ir = @import("ir");

test {
    _ = core;
    _ = geom;
    _ = eval;
}
