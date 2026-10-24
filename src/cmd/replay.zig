//! Replaying a command log (FR-CLI-2): the JSONL records a scene's log
//! holds, run again against a fresh scene, reproduce the same state.

const std = @import("std");
const server_mod = @import("server.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Server = server_mod.Server;

pub const ReplayError = error{ OutOfMemory, BadRecord, StepFailed };

pub const Result = struct {
    scene_id: []const u8,
    steps: usize,
    /// Set when a step failed: its 1-based line number and message.
    failed_line: usize = 0,
    message: []const u8 = "",
};

/// Runs every record of `log` (one JSON object per line). A leading
/// scene.create record opens the scene; otherwise an empty one is created
/// with the first record's seed. `arena` owns the result.
pub fn run(s: *Server, arena: Allocator, log: []const u8) ReplayError!Result {
    var scene_id: ?[]const u8 = null;
    var steps: usize = 0;
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, log, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const rec = std.json.parseFromSliceLeaky(Value, arena, line, .{}) catch return .{ .scene_id = scene_id orelse "", .steps = steps, .failed_line = line_no, .message = "line is not valid JSON" };
        if (rec != .object) return .{ .scene_id = scene_id orelse "", .steps = steps, .failed_line = line_no, .message = "record must be an object" };
        const tool = rec.object.get("tool") orelse return .{ .scene_id = scene_id orelse "", .steps = steps, .failed_line = line_no, .message = "record has no tool" };
        if (tool != .string) return error.BadRecord;
        const params = rec.object.get("params") orelse Value{ .object = .empty };
        if (params != .object) return error.BadRecord;
        var args = try params.object.clone(arena);

        if (std.mem.eql(u8, tool.string, "scene.create")) {
            if (scene_id != null) return .{ .scene_id = scene_id.?, .steps = steps, .failed_line = line_no, .message = "second scene.create in one log" };
        } else {
            if (scene_id == null) {
                var create_args: std.json.ObjectMap = .empty;
                if (rec.object.get("seed")) |seed| try create_args.put(arena, "seed", seed);
                const out = try s.call(arena, "scene.create", .{ .object = create_args });
                scene_id = try idFrom(arena, out);
            }
            try args.put(arena, "scene_id", .{ .string = scene_id.? });
        }
        const out = try s.call(arena, tool.string, .{ .object = args });
        switch (out) {
            .ok => |ok| {
                if (scene_id == null) scene_id = try idFromStructured(arena, ok.structured);
            },
            .tool_error => |te| return .{ .scene_id = scene_id orelse "", .steps = steps, .failed_line = line_no, .message = te.message },
            .unknown_tool => return .{ .scene_id = scene_id orelse "", .steps = steps, .failed_line = line_no, .message = "unknown tool" },
        }
        steps += 1;
    }
    if (scene_id == null) {
        const out = try s.call(arena, "scene.create", null);
        scene_id = try idFrom(arena, out);
    }
    return .{ .scene_id = scene_id.?, .steps = steps };
}

fn idFrom(arena: Allocator, out: server_mod.Outcome) ReplayError![]const u8 {
    return switch (out) {
        .ok => |ok| idFromStructured(arena, ok.structured),
        else => error.StepFailed,
    };
}

fn idFromStructured(arena: Allocator, structured: []const u8) ReplayError![]const u8 {
    const v = std.json.parseFromSliceLeaky(Value, arena, structured, .{}) catch return error.StepFailed;
    const id = v.object.get("scene_id") orelse return error.StepFailed;
    return try arena.dupe(u8, id.string);
}
