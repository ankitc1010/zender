//! stdio transport: one JSON-RPC message per line on stdin and stdout;
//! logs go to stderr only (TRD §10.1).

const std = @import("std");
const protocol = @import("protocol.zig");

const Io = std.Io;

/// Messages longer than this are rejected (and skipped) instead of buffered.
pub const max_message = 16 << 20;

pub fn serve(io: Io, gpa: std.mem.Allocator, session: *protocol.Session) !void {
    // rawAlloc skips the 0xAA fill that safe builds give new memory, so
    // pages a message never reaches stay unmapped (idle RSS, NFR-5).
    const in_ptr = gpa.rawAlloc(max_message, .of(u8), @returnAddress()) orelse return error.OutOfMemory;
    const in_buf = in_ptr[0..max_message];
    defer gpa.rawFree(in_buf, .of(u8), @returnAddress());
    var reader = Io.File.stdin().readerStreaming(io, in_buf);
    var out_buf: [64 * 1024]u8 = undefined;
    var writer = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &writer.interface;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    while (true) {
        _ = arena_state.reset(.{ .retain_with_limit = 8 << 20 });
        const arena = arena_state.allocator();
        const line = reader.interface.takeDelimiter('\n') catch |e| switch (e) {
            error.StreamTooLong => {
                // Drop the rest of the oversized line, then report it.
                _ = reader.interface.discardDelimiterInclusive('\n') catch return;
                const resp = try protocol.errorResponse(arena, .null, -32600, "Invalid Request: message exceeds 16 MB", null);
                try out.writeAll(resp);
                try out.writeByte('\n');
                try out.flush();
                continue;
            },
            error.ReadFailed => return,
        } orelse return; // EOF: the client closed stdin, so exit.
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const resp = session.handle(arena, trimmed) catch |e| switch (e) {
            error.OutOfMemory => try protocol.errorResponse(arena, .null, -32603, "Internal error: out of memory", null),
        } orelse continue;
        try out.writeAll(resp);
        try out.writeByte('\n');
        try out.flush();
    }
}
