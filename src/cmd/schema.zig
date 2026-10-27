//! Tool parameter declarations, their JSON Schema, and validation.
//!
//! A tool declares its parameters once as comptime `Param`s. From them the
//! command core emits the MCP `inputSchema` and validates arguments,
//! producing a resolved argument object with defaults filled in: the form
//! recorded in the command log (FR-CLI-1).

const std = @import("std");
const registry = @import("engine").core.registry;
const Stringify = std.json.Stringify;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Allocator = std.mem.Allocator;

pub const Unit = enum {
    none,
    metres,
    degrees,
    millimetres,
    pixels,
    watts,

    fn suffix(u: Unit) []const u8 {
        return switch (u) {
            .none => "",
            .metres => " (m)",
            .degrees => " (deg)",
            .millimetres => " (mm)",
            .pixels => " (px)",
            .watts => " (W, or W/m^2 for sun)",
        };
    }
};

pub const Type = union(enum) {
    number: struct { min: ?f64 = null, max: ?f64 = null, unit: Unit = .none },
    integer: struct { min: ?i64 = null, max: ?i64 = null },
    boolean,
    string: struct { max_len: usize = 1024 },
    enumeration: []const []const u8,
    /// Three numbers.
    vec3: struct { min: ?f64 = null, max: ?f64 = null, unit: Unit = .none },
    /// RGB or RGBA, scene-linear, 0..1.
    color,
    string_list: struct { max_items: usize = 4096 },
    /// Datablock name, or null where `nullable`.
    name_ref: struct { nullable: bool = false },
    /// Free-form object whose schema comes from the property registry;
    /// the handler validates its members.
    properties: *const fn (*Stringify) Stringify.Error!void,
    /// scene.apply's op list.
    ops,
    /// A mesh element selector (cmd/selector.zig); the handler parses it.
    selector,
};

pub const Default = union(enum) {
    number: f64,
    integer: i64,
    boolean: bool,
    string: []const u8,
    vec3: [3]f64,
    null_,
};

pub const Param = struct {
    name: []const u8,
    type: Type,
    doc: []const u8,
    required: bool = false,
    default: ?Default = null,
    /// Mirror into an `Mcp-Param-<name>` HTTP header (x-mcp-header).
    header: ?[]const u8 = null,
};

pub fn writeInputSchema(params: []const Param, w: *Stringify) Stringify.Error!void {
    try w.beginObject();
    try w.objectField("type");
    try w.write("object");
    try w.objectField("properties");
    try w.beginObject();
    for (params) |p| {
        try w.objectField(p.name);
        try writeParamSchema(p, w);
    }
    try w.endObject();
    var n_required: usize = 0;
    for (params) |p| if (p.required) {
        n_required += 1;
    };
    if (n_required > 0) {
        try w.objectField("required");
        try w.beginArray();
        for (params) |p| if (p.required) try w.write(p.name);
        try w.endArray();
    }
    try w.objectField("additionalProperties");
    try w.write(false);
    try w.endObject();
}

fn writeNumber(w: *Stringify, x: f64) Stringify.Error!void {
    try registry.writeBound(w, x);
}

fn writeParamSchema(p: Param, w: *Stringify) Stringify.Error!void {
    if (p.type == .properties) return p.type.properties(w);
    try w.beginObject();
    switch (p.type) {
        .number => |n| {
            try w.objectField("type");
            try w.write("number");
            if (n.min) |x| {
                try w.objectField("minimum");
                try writeNumber(w, x);
            }
            if (n.max) |x| {
                try w.objectField("maximum");
                try writeNumber(w, x);
            }
        },
        .integer => |n| {
            try w.objectField("type");
            try w.write("integer");
            if (n.min) |x| {
                try w.objectField("minimum");
                try w.write(x);
            }
            if (n.max) |x| {
                try w.objectField("maximum");
                try w.write(x);
            }
        },
        .boolean => {
            try w.objectField("type");
            try w.write("boolean");
        },
        .string => |s| {
            try w.objectField("type");
            try w.write("string");
            try w.objectField("maxLength");
            try w.write(s.max_len);
        },
        .enumeration => |e| {
            try w.objectField("enum");
            try w.write(e);
        },
        .vec3 => |n| {
            try w.objectField("type");
            try w.write("array");
            try w.objectField("items");
            try w.beginObject();
            try w.objectField("type");
            try w.write("number");
            if (n.min) |x| {
                try w.objectField("minimum");
                try writeNumber(w, x);
            }
            if (n.max) |x| {
                try w.objectField("maximum");
                try writeNumber(w, x);
            }
            try w.endObject();
            try w.objectField("minItems");
            try w.write(3);
            try w.objectField("maxItems");
            try w.write(3);
        },
        .color => {
            try w.objectField("type");
            try w.write("array");
            try w.objectField("items");
            try w.beginObject();
            try w.objectField("type");
            try w.write("number");
            try w.objectField("minimum");
            try w.write(0);
            try w.objectField("maximum");
            try w.write(1);
            try w.endObject();
            try w.objectField("minItems");
            try w.write(3);
            try w.objectField("maxItems");
            try w.write(4);
        },
        .string_list => |s| {
            try w.objectField("type");
            try w.write("array");
            try w.objectField("items");
            try w.beginObject();
            try w.objectField("type");
            try w.write("string");
            try w.endObject();
            try w.objectField("maxItems");
            try w.write(s.max_items);
        },
        .name_ref => |r| {
            // anyOf rather than a type array: clients that map schemas onto
            // a single-type dialect (Gemini's OpenAPI subset) accept it.
            if (r.nullable) {
                try w.objectField("anyOf");
                try w.beginArray();
                for ([_][]const u8{ "string", "null" }) |t| {
                    try w.beginObject();
                    try w.objectField("type");
                    try w.write(t);
                    try w.endObject();
                }
                try w.endArray();
            } else {
                try w.objectField("type");
                try w.write("string");
            }
        },
        .ops => {
            try w.objectField("type");
            try w.write("array");
            try w.objectField("maxItems");
            try w.write(256);
            try w.objectField("items");
            try w.beginObject();
            try w.objectField("type");
            try w.write("object");
            try w.objectField("properties");
            try w.beginObject();
            try w.objectField("tool");
            try w.beginObject();
            try w.objectField("type");
            try w.write("string");
            try w.endObject();
            try w.objectField("arguments");
            try w.beginObject();
            try w.objectField("type");
            try w.write("object");
            try w.endObject();
            try w.endObject();
            try w.objectField("required");
            try w.write(&[_][]const u8{"tool"});
            try w.endObject();
        },
        .selector => {
            try w.objectField("type");
            try w.write("object");
        },
        .properties => unreachable,
    }
    if (p.default) |d| {
        try w.objectField("default");
        try writeDefault(d, w);
    }
    if (p.header) |h| {
        try w.objectField("x-mcp-header");
        try w.write(h);
    }
    const unit: Unit = switch (p.type) {
        .number => |n| n.unit,
        .vec3 => |n| n.unit,
        else => .none,
    };
    // An empty doc means the name says it all (scene_id); tools/list is
    // read on every connect, so each byte repeated per tool counts.
    if (p.doc.len > 0 or unit != .none) {
        try w.objectField("description");
        var buf: [1024]u8 = undefined;
        const desc = std.fmt.bufPrint(&buf, "{s}{s}", .{ p.doc, unit.suffix() }) catch p.doc;
        try w.write(desc);
    }
    try w.endObject();
}

fn writeDefault(d: Default, w: *Stringify) Stringify.Error!void {
    switch (d) {
        .number => |x| try writeNumber(w, x),
        .integer => |x| try w.write(x),
        .boolean => |x| try w.write(x),
        .string => |x| try w.write(x),
        .vec3 => |x| {
            try w.beginArray();
            for (x) |c| try writeNumber(w, c);
            try w.endArray();
        },
        .null_ => try w.write(null),
    }
}

fn defaultValue(d: Default, arena: Allocator) Allocator.Error!Value {
    return switch (d) {
        .number => |x| .{ .float = x },
        .integer => |x| .{ .integer = x },
        .boolean => |x| .{ .bool = x },
        .string => |x| .{ .string = x },
        .vec3 => |x| blk: {
            var a = std.json.Array.init(arena);
            for (x) |c| try a.append(.{ .float = c });
            break :blk .{ .array = a };
        },
        .null_ => .null,
    };
}

/// A validation failure, phrased for the model to self-correct (FR-MCP-5).
pub const Failure = struct {
    message: []const u8,
    /// JSON pointer into the arguments, e.g. "/location/2".
    path: []const u8,
    hint: []const u8 = "",
    valid_values: []const []const u8 = &.{},
};

pub fn number(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// Validates `args` against `params` and returns the resolved object, with
/// defaults filled and keys in declaration order. On failure returns null
/// and sets `failure`.
pub fn resolve(arena: Allocator, params: []const Param, args: ?Value, failure: *Failure) Allocator.Error!?ObjectMap {
    var out: ObjectMap = .empty;
    const obj: ?ObjectMap = if (args) |a| switch (a) {
        .object => |o| o,
        .null => null,
        else => {
            failure.* = .{ .message = "arguments must be an object", .path = "" };
            return null;
        },
    } else null;

    if (obj) |o| {
        var it = o.iterator();
        while (it.next()) |e| {
            var known = false;
            for (params) |p| if (std.mem.eql(u8, p.name, e.key_ptr.*)) {
                known = true;
            };
            if (!known) {
                const names = try arena.alloc([]const u8, params.len);
                for (params, names) |p, *n| n.* = p.name;
                failure.* = .{
                    .message = try std.fmt.allocPrint(arena, "unknown argument '{s}'", .{e.key_ptr.*}),
                    .path = try std.fmt.allocPrint(arena, "/{s}", .{e.key_ptr.*}),
                    .valid_values = names,
                };
                return null;
            }
        }
    }

    for (params) |p| {
        const given: ?Value = if (obj) |o| o.get(p.name) else null;
        const val = given orelse {
            if (p.required) {
                failure.* = .{
                    .message = try std.fmt.allocPrint(arena, "missing required argument '{s}'", .{p.name}),
                    .path = try std.fmt.allocPrint(arena, "/{s}", .{p.name}),
                };
                return null;
            }
            if (p.default) |d| try out.put(arena, p.name, try defaultValue(d, arena));
            continue;
        };
        if (try check(arena, p, val, failure)) |ok| {
            try out.put(arena, p.name, ok);
        } else return null;
    }
    return out;
}

fn fail(arena: Allocator, failure: *Failure, p: Param, sub: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!?Value {
    failure.* = .{
        .message = try std.fmt.allocPrint(arena, fmt, args),
        .path = try std.fmt.allocPrint(arena, "/{s}{s}", .{ p.name, sub }),
    };
    return null;
}

fn check(arena: Allocator, p: Param, val: Value, failure: *Failure) Allocator.Error!?Value {
    switch (p.type) {
        .number => |n| {
            const x = number(val) orelse return fail(arena, failure, p, "", "'{s}' must be a number", .{p.name});
            if (!std.math.isFinite(x)) return fail(arena, failure, p, "", "'{s}' must be finite", .{p.name});
            if (n.min) |lo| if (x < lo) return fail(arena, failure, p, "", "'{s}' must be at least {d}", .{ p.name, lo });
            if (n.max) |hi| if (x > hi) return fail(arena, failure, p, "", "'{s}' must be at most {d}", .{ p.name, hi });
            return .{ .float = x };
        },
        .integer => |n| {
            const x = number(val) orelse return fail(arena, failure, p, "", "'{s}' must be an integer", .{p.name});
            if (@floor(x) != x or @abs(x) > 9007199254740991) return fail(arena, failure, p, "", "'{s}' must be an integer", .{p.name});
            const i: i64 = @intFromFloat(x);
            if (n.min) |lo| if (i < lo) return fail(arena, failure, p, "", "'{s}' must be at least {d}", .{ p.name, lo });
            if (n.max) |hi| if (i > hi) return fail(arena, failure, p, "", "'{s}' must be at most {d}", .{ p.name, hi });
            return .{ .integer = i };
        },
        .boolean => return switch (val) {
            .bool => val,
            else => fail(arena, failure, p, "", "'{s}' must be true or false", .{p.name}),
        },
        .string => |s| return switch (val) {
            .string => |str| if (str.len > s.max_len)
                fail(arena, failure, p, "", "'{s}' is longer than {d} bytes", .{ p.name, s.max_len })
            else if (!std.unicode.utf8ValidateSlice(str))
                fail(arena, failure, p, "", "'{s}' must be valid UTF-8", .{p.name})
            else
                val,
            else => fail(arena, failure, p, "", "'{s}' must be a string", .{p.name}),
        },
        .enumeration => |e| {
            if (val == .string) for (e) |x| if (std.mem.eql(u8, x, val.string)) return val;
            failure.* = .{
                .message = try std.fmt.allocPrint(arena, "'{s}' must be one of the listed values", .{p.name}),
                .path = try std.fmt.allocPrint(arena, "/{s}", .{p.name}),
                .valid_values = e,
            };
            return null;
        },
        .vec3 => |n| {
            const arr = if (val == .array) val.array.items else &[_]Value{};
            if (arr.len != 3) return fail(arena, failure, p, "", "'{s}' must be an array of 3 numbers [x, y, z]", .{p.name});
            var out = std.json.Array.init(arena);
            for (arr, 0..) |item, i| {
                const x = number(item) orelse return fail(arena, failure, p, try std.fmt.allocPrint(arena, "/{d}", .{i}), "'{s}' must contain numbers", .{p.name});
                if (!std.math.isFinite(x)) return fail(arena, failure, p, try std.fmt.allocPrint(arena, "/{d}", .{i}), "'{s}' must be finite", .{p.name});
                if (n.min) |lo| if (x < lo) return fail(arena, failure, p, try std.fmt.allocPrint(arena, "/{d}", .{i}), "'{s}' components must be at least {d}", .{ p.name, lo });
                if (n.max) |hi| if (x > hi) return fail(arena, failure, p, try std.fmt.allocPrint(arena, "/{d}", .{i}), "'{s}' components must be at most {d}", .{ p.name, hi });
                try out.append(.{ .float = x });
            }
            return .{ .array = out };
        },
        .color => {
            const arr = if (val == .array) val.array.items else &[_]Value{};
            if (arr.len != 3 and arr.len != 4) return fail(arena, failure, p, "", "'{s}' must be [r, g, b] or [r, g, b, a] in 0..1", .{p.name});
            var out = std.json.Array.init(arena);
            for (arr, 0..) |item, i| {
                const x = number(item) orelse return fail(arena, failure, p, try std.fmt.allocPrint(arena, "/{d}", .{i}), "'{s}' must contain numbers", .{p.name});
                if (!(x >= 0 and x <= 1)) return fail(arena, failure, p, try std.fmt.allocPrint(arena, "/{d}", .{i}), "'{s}' components must be in 0..1 (scene-linear)", .{p.name});
                try out.append(.{ .float = x });
            }
            if (out.items.len == 3) try out.append(.{ .float = 1 });
            return .{ .array = out };
        },
        .string_list => |s| {
            const arr = switch (val) {
                .array => |a| a.items,
                .string => {
                    // Accept a single name where a list is expected.
                    var one = std.json.Array.init(arena);
                    try one.append(val);
                    return .{ .array = one };
                },
                else => return fail(arena, failure, p, "", "'{s}' must be an array of strings", .{p.name}),
            };
            if (arr.len > s.max_items) return fail(arena, failure, p, "", "'{s}' has more than {d} items", .{ p.name, s.max_items });
            for (arr, 0..) |item, i| if (item != .string)
                return fail(arena, failure, p, try std.fmt.allocPrint(arena, "/{d}", .{i}), "'{s}' must contain strings", .{p.name});
            return val;
        },
        .name_ref => |r| return switch (val) {
            .string => |s| if (s.len == 0 or s.len > 255) fail(arena, failure, p, "", "'{s}' must be a name of 1 to 255 bytes", .{p.name}) else val,
            .null => if (r.nullable) val else fail(arena, failure, p, "", "'{s}' must be a name", .{p.name}),
            else => fail(arena, failure, p, "", "'{s}' must be a name (string)", .{p.name}),
        },
        .properties => return switch (val) {
            .object => val,
            else => fail(arena, failure, p, "", "'{s}' must be an object of property values", .{p.name}),
        },
        .selector => return switch (val) {
            .object => val,
            else => fail(arena, failure, p, "", "'{s}' must be a selector object such as {{\"normal\":[0,0,1]}}", .{p.name}),
        },
        .ops => {
            const arr = if (val == .array) val.array.items else return fail(arena, failure, p, "", "'{s}' must be an array of {{tool, arguments}} objects", .{p.name});
            if (arr.len == 0) return fail(arena, failure, p, "", "'{s}' must contain at least one op", .{p.name});
            if (arr.len > 256) return fail(arena, failure, p, "", "'{s}' allows at most 256 ops per call", .{p.name});
            for (arr, 0..) |item, i| {
                const ok = item == .object and item.object.get("tool") != null and item.object.get("tool").? == .string;
                if (!ok) return fail(arena, failure, p, try std.fmt.allocPrint(arena, "/{d}", .{i}), "each op needs a 'tool' name and optional 'arguments'", .{});
            }
            return val;
        },
    }
}

/// Typed access to a resolved argument object.
pub const Args = struct {
    map: ObjectMap,

    pub fn has(a: Args, name: []const u8) bool {
        const v = a.map.get(name) orelse return false;
        return v != .null;
    }
    pub fn float(a: Args, name: []const u8) ?f32 {
        const v = a.map.get(name) orelse return null;
        return if (number(v)) |x| @floatCast(x) else null;
    }
    pub fn int(a: Args, name: []const u8) ?i64 {
        const v = a.map.get(name) orelse return null;
        return switch (v) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            else => null,
        };
    }
    pub fn boolean(a: Args, name: []const u8) ?bool {
        const v = a.map.get(name) orelse return null;
        return if (v == .bool) v.bool else null;
    }
    pub fn str(a: Args, name: []const u8) ?[]const u8 {
        const v = a.map.get(name) orelse return null;
        return if (v == .string) v.string else null;
    }
    pub fn vec3(a: Args, name: []const u8) ?[3]f32 {
        const v = a.map.get(name) orelse return null;
        if (v != .array or v.array.items.len < 3) return null;
        var out: [3]f32 = undefined;
        for (0..3) |i| out[i] = @floatCast(number(v.array.items[i]) orelse 0);
        return out;
    }
    pub fn color(a: Args, name: []const u8) ?[4]f32 {
        const v = a.map.get(name) orelse return null;
        if (v != .array or v.array.items.len < 4) return null;
        var out: [4]f32 = undefined;
        for (0..4) |i| out[i] = @floatCast(number(v.array.items[i]) orelse 0);
        return out;
    }
    pub fn strings(a: Args, name: []const u8) []const Value {
        const v = a.map.get(name) orelse return &.{};
        return if (v == .array) v.array.items else &.{};
    }
    pub fn value(a: Args, name: []const u8) ?Value {
        return a.map.get(name);
    }
};

test "resolve fills defaults, reports precise paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const params = [_]Param{
        .{ .name = "kind", .type = .{ .enumeration = &.{ "cube", "plane" } }, .doc = "Kind", .required = true },
        .{ .name = "size", .type = .{ .number = .{ .min = 0.0001 } }, .doc = "Size", .default = .{ .number = 2 } },
        .{ .name = "location", .type = .{ .vec3 = .{} }, .doc = "Where", .default = .{ .vec3 = .{ 0, 0, 0 } } },
    };
    var failure: Failure = undefined;
    const ok = (try resolve(arena, &params, try std.json.parseFromSliceLeaky(Value, arena, "{\"kind\":\"cube\"}", .{}), &failure)).?;
    const args: Args = .{ .map = ok };
    try std.testing.expectEqual(@as(f32, 2), args.float("size").?);
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, args.vec3("location").?);

    try std.testing.expect(try resolve(arena, &params, try std.json.parseFromSliceLeaky(Value, arena, "{\"kind\":\"cube\",\"location\":[0,0,\"x\"]}", .{}), &failure) == null);
    try std.testing.expectEqualStrings("/location/2", failure.path);
    try std.testing.expect(try resolve(arena, &params, try std.json.parseFromSliceLeaky(Value, arena, "{\"kind\":\"cone\"}", .{}), &failure) == null);
    try std.testing.expectEqual(@as(usize, 2), failure.valid_values.len);
    try std.testing.expect(try resolve(arena, &params, try std.json.parseFromSliceLeaky(Value, arena, "{\"kind\":\"cube\",\"szie\":1}", .{}), &failure) == null);
    try std.testing.expectEqualStrings("/szie", failure.path);
}
