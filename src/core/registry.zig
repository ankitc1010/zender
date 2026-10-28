//! Comptime property registry (FR-DM-7), Zender's counterpart of Blender's RNA.
//!
//! Each datablock type declares `pub const props` once: agent-facing name,
//! struct field, kind, unit, range and doc string. Defaults come from the
//! struct's own field defaults. From that one table the registry derives
//! validation, unit conversion at the agent boundary (radians ⇄ degrees),
//! JSON Schema for MCP tools, `schema.describe` docs and canonical JSON.

const std = @import("std");
const Stringify = std.json.Stringify;

pub const Kind = enum { float, int, bool, enumeration, vec2, vec3, vec4, color3, color4 };

pub const Unit = enum {
    none,
    /// metres
    length,
    /// stored in radians, degrees at the agent boundary
    angle,
    /// millimetres (camera lens and sensor)
    millimetre,
    /// watts
    power,
    /// W/m² (sun strength)
    irradiance,
    /// 0..1
    factor,
    pixels,
    percent,
    frames,
    per_second,

    pub fn label(u: Unit) []const u8 {
        return switch (u) {
            .none => "",
            .length => "m",
            .angle => "deg",
            .millimetre => "mm",
            .power => "W",
            .irradiance => "W/m^2",
            .factor => "factor",
            .pixels => "px",
            .percent => "%",
            .frames => "frames",
            .per_second => "1/s",
        };
    }
};

pub const Prop = struct {
    /// Agent-facing name; matches Blender's RNA identifier where one exists.
    name: []const u8,
    /// Zig struct field holding the value.
    field: []const u8,
    kind: Kind,
    unit: Unit = .none,
    min: ?f64 = null,
    max: ?f64 = null,
    doc: []const u8,
    /// DNA struct member name, for the .blend mapping (P2).
    blend: ?[]const u8 = null,
    read_only: bool = false,
};

pub fn propsOf(comptime T: type) []const Prop {
    return &T.props;
}

pub fn find(comptime T: type, name: []const u8) ?Prop {
    inline for (T.props) |p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

/// Why a property write was refused, in terms an agent can act on.
pub const Diag = struct {
    message: []const u8 = "",
    hint: []const u8 = "",
    /// Owned by the caller's arena when set.
    valid_values: []const []const u8 = &.{},
};

pub const SetError = error{ UnknownProperty, ReadOnly, InvalidValue, OutOfRange };

fn toAgent(unit: Unit, v: f32) f64 {
    if (unit == .angle) {
        // Rounded so 90° does not come back as 90.00000250447816.
        const deg = @as(f64, v) * (180.0 / std.math.pi);
        return @round(deg * 1e4) / 1e4;
    }
    return v;
}

fn fromAgent(unit: Unit, v: f64) f32 {
    if (unit == .angle) return @floatCast(v * (std.math.pi / 180.0));
    return @floatCast(v);
}

/// Writes an f32 using its shortest round-trip form; non-finite values,
/// which JSON cannot carry, become null.
pub fn writeF32(w: *Stringify, v: f32) !void {
    if (!std.math.isFinite(v)) return w.write(null);
    try w.beginWriteRaw();
    try w.writer.print("{d}", .{v});
    w.endWriteRaw();
}

pub fn writeF64(w: *Stringify, v: f64) !void {
    if (!std.math.isFinite(v)) return w.write(null);
    try w.beginWriteRaw();
    try w.writer.print("{d}", .{v});
    w.endWriteRaw();
}

/// Writes a schema bound or default; whole numbers with four or more
/// trailing zeros (1e9) in exponent form, which is valid JSON and keeps
/// tools/list short.
pub fn writeBound(w: *Stringify, x: f64) Stringify.Error!void {
    if (!std.math.isFinite(x)) return w.write(null);
    try w.beginWriteRaw();
    var m = @abs(x);
    var exp: u32 = 0;
    if (m >= 1e4 and m < 1e18 and @floor(m) == m) {
        while (@mod(m, 10) == 0) : (exp += 1) m /= 10;
    }
    if (exp >= 4) {
        try w.writer.print("{s}{d}e{d}", .{ if (x < 0) "-" else "", m, exp });
    } else {
        try w.writer.print("{d}", .{x});
    }
    w.endWriteRaw();
}

fn writeAgentFloat(w: *Stringify, unit: Unit, v: f32) !void {
    if (unit == .angle) return writeF64(w, toAgent(unit, v));
    return writeF32(w, v);
}

fn writeField(comptime p: Prop, w: *Stringify, value: anytype) !void {
    switch (p.kind) {
        .float => try writeAgentFloat(w, p.unit, value),
        .int => try w.write(value),
        .bool => try w.write(value),
        .enumeration => try w.write(@tagName(value)),
        .vec2, .vec3, .vec4, .color3, .color4 => {
            try w.beginArray();
            for (value) |c| try writeAgentFloat(w, p.unit, c);
            try w.endArray();
        },
    }
}

/// Writes every registered property of `v` as one JSON object, in
/// declaration order, in stored units (radians), for scene.json.
pub fn writeStoredValues(comptime T: type, v: *const T, w: *Stringify) !void {
    try w.beginObject();
    inline for (T.props) |p| {
        try w.objectField(p.name);
        const value = @field(v, p.field);
        switch (p.kind) {
            .float => try writeF32(w, value),
            .int, .bool => try w.write(value),
            .enumeration => try w.write(@tagName(value)),
            .vec2, .vec3, .vec4, .color3, .color4 => {
                try w.beginArray();
                for (value) |c| try writeF32(w, c);
                try w.endArray();
            },
        }
    }
    try w.endObject();
}

/// Writes every registered property of `v` as one JSON object, in
/// declaration order, using agent-facing units.
pub fn writeValues(comptime T: type, v: *const T, w: *Stringify) !void {
    try w.beginObject();
    inline for (T.props) |p| {
        try w.objectField(p.name);
        try writeField(p, w, @field(v, p.field));
    }
    try w.endObject();
}

fn numberOf(j: std.json.Value) ?f64 {
    return switch (j) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// A stored bound as agents see it (degrees for angles).
fn agentBound(comptime p: Prop, x: f64) f64 {
    return if (p.unit == .angle) @round(x * (180.0 / std.math.pi) * 1e4) / 1e4 else x;
}

fn checkRange(comptime p: Prop, x_agent: f64, diag: *Diag) SetError!void {
    if (!std.math.isFinite(x_agent)) {
        diag.message = "value must be a finite number";
        return error.InvalidValue;
    }
    // Bounds are in stored units (radians for angles); agents give degrees.
    const x = if (p.unit == .angle) x_agent * (std.math.pi / 180.0) else x_agent;
    if (p.min) |lo| if (x < lo) {
        diag.message = "value below minimum";
        diag.hint = "see schema.describe for the valid range";
        return error.OutOfRange;
    };
    if (p.max) |hi| if (x > hi) {
        diag.message = "value above maximum";
        diag.hint = "see schema.describe for the valid range";
        return error.OutOfRange;
    };
}

fn parseVector(comptime p: Prop, comptime n: usize, j: std.json.Value, diag: *Diag) SetError![n]f32 {
    const arr = switch (j) {
        .array => |a| a.items,
        else => {
            diag.message = std.fmt.comptimePrint("expected an array of {d} numbers", .{n});
            return error.InvalidValue;
        },
    };
    // Colours may omit alpha.
    const min_len = if (p.kind == .color4) 3 else n;
    if (arr.len < min_len or arr.len > n) {
        diag.message = std.fmt.comptimePrint("expected an array of {d} numbers", .{n});
        return error.InvalidValue;
    }
    var out: [n]f32 = undefined;
    if (p.kind == .color4) out[3] = 1;
    for (arr, 0..) |item, i| {
        const x = numberOf(item) orelse {
            diag.message = "array items must be numbers";
            return error.InvalidValue;
        };
        try checkRange(p, x, diag);
        out[i] = fromAgent(p.unit, x);
    }
    return out;
}

fn setField(comptime p: Prop, comptime F: type, dst: *F, j: std.json.Value, diag: *Diag, arena: std.mem.Allocator) SetError!void {
    switch (p.kind) {
        .float => {
            const x = numberOf(j) orelse {
                diag.message = "expected a number";
                return error.InvalidValue;
            };
            try checkRange(p, x, diag);
            dst.* = fromAgent(p.unit, x);
        },
        .int => {
            const x = numberOf(j) orelse {
                diag.message = "expected an integer";
                return error.InvalidValue;
            };
            if (@floor(x) != x) {
                diag.message = "expected an integer";
                return error.InvalidValue;
            }
            try checkRange(p, x, diag);
            const lo: f64 = @floatFromInt(std.math.minInt(F));
            const hi: f64 = @floatFromInt(std.math.maxInt(F));
            if (x < lo or x > hi) {
                diag.message = "integer out of range";
                return error.OutOfRange;
            }
            dst.* = @intFromFloat(x);
        },
        .bool => switch (j) {
            .bool => |b| dst.* = b,
            else => {
                diag.message = "expected true or false";
                return error.InvalidValue;
            },
        },
        .enumeration => {
            const s = switch (j) {
                .string => |s| s,
                else => "",
            };
            if (std.meta.stringToEnum(F, s)) |e| {
                dst.* = e;
                return;
            }
            diag.message = "unknown value";
            diag.valid_values = enumNames(F, arena);
            return error.InvalidValue;
        },
        .vec2 => dst.* = try parseVector(p, 2, j, diag),
        .vec3, .color3 => dst.* = try parseVector(p, 3, j, diag),
        .vec4, .color4 => dst.* = try parseVector(p, 4, j, diag),
    }
}

fn enumNames(comptime E: type, arena: std.mem.Allocator) []const []const u8 {
    const fields = std.meta.fields(E);
    const names = arena.alloc([]const u8, fields.len) catch return &.{};
    inline for (fields, 0..) |f, i| names[i] = f.name;
    return names;
}

/// Sets one property from agent-facing JSON, validating type and range.
/// On error, `diag` says what was wrong; `v` is unchanged.
pub fn set(comptime T: type, v: *T, name: []const u8, j: std.json.Value, diag: *Diag, arena: std.mem.Allocator) SetError!void {
    inline for (T.props) |p| {
        if (std.mem.eql(u8, p.name, name)) {
            if (p.read_only) {
                diag.message = "property is read-only";
                diag.hint = "use the dedicated tool for this property";
                return error.ReadOnly;
            }
            const F = @TypeOf(@field(v, p.field));
            return setField(p, F, &@field(v, p.field), j, diag, arena);
        }
    }
    diag.message = "unknown property";
    diag.valid_values = writableNames(T, arena);
    return error.UnknownProperty;
}

fn writableNames(comptime T: type, arena: std.mem.Allocator) []const []const u8 {
    comptime var n = 0;
    inline for (T.props) |p| if (!p.read_only) {
        n += 1;
    };
    const names = arena.alloc([]const u8, n) catch return &.{};
    var i: usize = 0;
    inline for (T.props) |p| if (!p.read_only) {
        names[i] = p.name;
        i += 1;
    };
    return names;
}

fn writePropSchema(comptime T: type, comptime p: Prop, w: *Stringify, with_default: bool) !void {
    const defaults: T = .{};
    try w.beginObject();
    const F = @TypeOf(@field(defaults, p.field));
    switch (p.kind) {
        .float => {
            try w.objectField("type");
            try w.write("number");
        },
        .int => {
            try w.objectField("type");
            try w.write("integer");
        },
        .bool => {
            try w.objectField("type");
            try w.write("boolean");
        },
        .enumeration => {
            try w.objectField("enum");
            try w.beginArray();
            inline for (std.meta.fields(F)) |f| try w.write(f.name);
            try w.endArray();
        },
        .vec2, .vec3, .vec4, .color3, .color4 => {
            const n = @typeInfo(F).array.len;
            try w.objectField("type");
            try w.write("array");
            try w.objectField("items");
            try w.beginObject();
            try w.objectField("type");
            try w.write("number");
            if (p.min) |lo| {
                try w.objectField("minimum");
                try writeBound(w, agentBound(p, lo));
            }
            if (p.max) |hi| {
                try w.objectField("maximum");
                try writeBound(w, agentBound(p, hi));
            }
            try w.endObject();
            try w.objectField("minItems");
            try w.write(if (p.kind == .color4) 3 else n);
            try w.objectField("maxItems");
            try w.write(n);
        },
    }
    if (p.kind == .float or p.kind == .int) {
        if (p.min) |lo| {
            try w.objectField("minimum");
            try writeBound(w, agentBound(p, lo));
        }
        if (p.max) |hi| {
            try w.objectField("maximum");
            try writeBound(w, agentBound(p, hi));
        }
    }
    if (with_default) {
        try w.objectField("default");
        try writeField(p, w, @field(defaults, p.field));
    }
    try w.objectField("description");
    if (p.unit != .none and p.unit != .factor) {
        try w.write(comptime std.fmt.comptimePrint("{s} ({s})", .{ p.doc, p.unit.label() }));
    } else {
        try w.write(p.doc);
    }
    try w.endObject();
}

/// JSON Schema (2020-12) for a partial property object of `T`: every
/// writable property optional, nothing else allowed.
pub fn writeSchema(comptime T: type, w: *Stringify) !void {
    try w.beginObject();
    try w.objectField("type");
    try w.write("object");
    try w.objectField("properties");
    try w.beginObject();
    inline for (T.props) |p| {
        if (!p.read_only) {
            try w.objectField(p.name);
            try writePropSchema(T, p, w, false);
        }
    }
    try w.endObject();
    try w.objectField("additionalProperties");
    try w.write(false);
    try w.endObject();
}

/// Full reference for `schema.describe`: one entry per property with kind,
/// unit, range, default and doc.
pub fn writeDescription(comptime T: type, w: *Stringify) !void {
    try w.beginArray();
    inline for (T.props) |p| {
        try w.beginObject();
        try w.objectField("name");
        try w.write(p.name);
        try w.objectField("kind");
        try w.write(@tagName(p.kind));
        if (p.unit != .none) {
            try w.objectField("unit");
            try w.write(p.unit.label());
        }
        try w.objectField("schema");
        try writePropSchema(T, p, w, true);
        if (p.read_only) {
            try w.objectField("read_only");
            try w.write(true);
        }
        try w.endObject();
    }
    try w.endArray();
}

const testing = std.testing;

const Sample = struct {
    size: f32 = 2,
    angle: f32 = 0,
    count: u16 = 8,
    mode: enum { fast, exact } = .exact,
    color: [4]f32 = .{ 0.8, 0.8, 0.8, 1 },

    pub const props = [_]Prop{
        .{ .name = "size", .field = "size", .kind = .float, .unit = .length, .min = 0, .doc = "Size" },
        .{ .name = "angle", .field = "angle", .kind = .float, .unit = .angle, .doc = "Angle" },
        .{ .name = "count", .field = "count", .kind = .int, .min = 3, .max = 512, .doc = "Count" },
        .{ .name = "mode", .field = "mode", .kind = .enumeration, .doc = "Mode" },
        .{ .name = "color", .field = "color", .kind = .color4, .unit = .factor, .min = 0, .doc = "Colour" },
    };
};

test "set converts degrees and validates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s: Sample = .{};
    var diag: Diag = .{};
    try set(Sample, &s, "angle", .{ .integer = 90 }, &diag, arena);
    try testing.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), s.angle, 1e-6);
    try testing.expectError(error.OutOfRange, set(Sample, &s, "count", .{ .integer = 2 }, &diag, arena));
    try testing.expectError(error.InvalidValue, set(Sample, &s, "mode", .{ .string = "slow" }, &diag, arena));
    try testing.expectEqual(@as(usize, 2), diag.valid_values.len);
    try testing.expectError(error.UnknownProperty, set(Sample, &s, "nope", .{ .integer = 1 }, &diag, arena));

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var w: Stringify = .{ .writer = &out.writer };
    try writeValues(Sample, &s, &w);
    try testing.expectEqualStrings(
        \\{"size":2,"angle":90,"count":8,"mode":"exact","color":[0.8,0.8,0.8,1]}
    , out.written());
}

test "schema bounds use exponent form for round numbers" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    var w: Stringify = .{ .writer = &buf.writer };
    try w.beginArray();
    for ([_]f64{ 1e9, -1e6, 1e12, 4096, 4294967295, 0.25, 1e-6, 12000 }) |x| try writeBound(&w, x);
    try w.endArray();
    try std.testing.expectEqualStrings("[1e9,-1e6,1e12,4096,4294967295,0.25,0.000001,12000]", buf.written());
}
