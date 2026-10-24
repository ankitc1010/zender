//! The tool table, in the deterministic order tools/list reports.

const server = @import("server.zig");

pub const tools: []const server.Tool = &(@import("tools/scene.zig").tools ++
    @import("tools/object.zig").tools ++
    @import("tools/shading.zig").tools ++
    @import("tools/camera.zig").tools ++
    @import("tools/render.zig").tools ++
    @import("tools/io.zig").tools ++
    @import("tools/introspect.zig").tools);
