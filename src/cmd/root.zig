//! Command core (layer 4): one dispatcher shared by MCP, CLI and the C ABI.

pub const schema = @import("schema.zig");
pub const selector = @import("selector.zig");
pub const paths = @import("paths.zig");
pub const server = @import("server.zig");
pub const catalog = @import("catalog.zig");
pub const replay = @import("replay.zig");
pub const telemetry = @import("telemetry.zig");

pub const Server = server.Server;
pub const Outcome = server.Outcome;
pub const version = server.version;

test {
    _ = schema;
    _ = selector;
    _ = paths;
    _ = server;
    _ = catalog;
    _ = replay;
    _ = telemetry;
    _ = @import("tests.zig");
}
