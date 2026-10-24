//! Render layer: the preview rasteriser now; the CPU path tracer (P3) and
//! the Vulkan backend (v2) sit behind the same interface. Links no GL,
//! windowing or display library (FR-REN-1).

pub const preview = @import("preview/raster.zig");

test {
    _ = preview;
}
