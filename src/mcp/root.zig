//! MCP front end (layer 5): translates JSON-RPC to command-core calls and
//! back, holding no scene logic itself (FR-ARCH-2).

pub const protocol = @import("protocol.zig");
pub const stdio = @import("stdio.zig");

pub const Session = protocol.Session;

test {
    _ = protocol;
    _ = stdio;
    _ = @import("tests.zig");
}
