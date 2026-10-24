//! Datablock identity: ID types, generational handles and names.

const std = @import("std");

/// Top-level datablock types (TRD §6). The order is part of the handle
/// encoding and of canonical output, so append only.
pub const IdType = enum(u8) {
    scene,
    collection,
    object,
    mesh,
    camera,
    light,
    material,
    image,
    world,
    action,

    /// Blender's two-letter ID code, used in handle strings and .blend I/O.
    pub fn code(t: IdType) []const u8 {
        return switch (t) {
            .scene => "SC",
            .collection => "GR",
            .object => "OB",
            .mesh => "ME",
            .camera => "CA",
            .light => "LA",
            .material => "MA",
            .image => "IM",
            .world => "WO",
            .action => "AC",
        };
    }

    pub fn fromCode(s: []const u8) ?IdType {
        inline for (std.meta.fields(IdType)) |f| {
            const t: IdType = @enumFromInt(f.value);
            if (std.mem.eql(u8, s, t.code())) return t;
        }
        return null;
    }
};

/// FR-DM-1: every datablock is addressed by type, slot index and the slot's
/// generation. Reusing a slot bumps its generation, so an old handle to a
/// deleted datablock is detected instead of reaching the new occupant.
pub const IdHandle = struct {
    type: IdType,
    index: u32,
    generation: u32,

    pub fn eql(a: IdHandle, b: IdHandle) bool {
        return a.type == b.type and a.index == b.index and a.generation == b.generation;
    }

    /// Stable text form for agents and logs, e.g. "OB3.1".
    pub fn format(h: IdHandle, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}{d}.{d}", .{ h.type.code(), h.index, h.generation });
    }

    pub fn parse(s: []const u8) ?IdHandle {
        if (s.len < 5) return null;
        const t = IdType.fromCode(s[0..2]) orelse return null;
        const dot = std.mem.indexOfScalarPos(u8, s, 2, '.') orelse return null;
        const index = std.fmt.parseInt(u32, s[2..dot], 10) catch return null;
        const generation = std.fmt.parseInt(u32, s[dot + 1 ..], 10) catch return null;
        return .{ .type = t, .index = index, .generation = generation };
    }
};

/// Datablock name stored inline (FR-DM-2: UTF-8, at most 255 bytes, the
/// Blender 5.x limit). Inline storage keeps datablocks plain values, which
/// makes snapshots for undo a flat copy.
pub const Name = struct {
    len: u8 = 0,
    bytes: [max_len]u8 = undefined,

    pub const max_len = 255;

    /// Copies `s`, cutting it at a UTF-8 boundary if it is too long.
    pub fn init(s: []const u8) Name {
        var n: Name = .{};
        const cut = utf8Prefix(s, max_len);
        @memcpy(n.bytes[0..cut], s[0..cut]);
        n.len = @intCast(cut);
        return n;
    }

    pub fn slice(n: *const Name) []const u8 {
        return n.bytes[0..n.len];
    }

    pub fn eql(n: *const Name, s: []const u8) bool {
        return std.mem.eql(u8, n.slice(), s);
    }
};

/// Longest prefix of `s` of at most `limit` bytes that ends on a UTF-8
/// character boundary.
pub fn utf8Prefix(s: []const u8, limit: usize) usize {
    if (s.len <= limit) return s.len;
    var cut = limit;
    while (cut > 0 and (s[cut] & 0xC0) == 0x80) cut -= 1;
    return cut;
}

/// Splits "Cube.001" into ("Cube", 1); names without a numeric suffix
/// return null for the number.
pub fn splitNumericSuffix(s: []const u8) struct { base: []const u8, number: ?u32 } {
    const dot = std.mem.lastIndexOfScalar(u8, s, '.') orelse return .{ .base = s, .number = null };
    const digits = s[dot + 1 ..];
    if (digits.len == 0 or digits.len > 9 or dot == 0) return .{ .base = s, .number = null };
    for (digits) |c| if (!std.ascii.isDigit(c)) return .{ .base = s, .number = null };
    const n = std.fmt.parseInt(u32, digits, 10) catch return .{ .base = s, .number = null };
    return .{ .base = s[0..dot], .number = n };
}

test "handle text round trip" {
    const h: IdHandle = .{ .type = .object, .index = 12, .generation = 3 };
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{f}", .{h});
    try std.testing.expectEqualStrings("OB12.3", s);
    try std.testing.expect(IdHandle.parse(s).?.eql(h));
    try std.testing.expect(IdHandle.parse("XX1.1") == null);
}

test "names cut on utf-8 boundaries" {
    var long: [300]u8 = undefined;
    @memset(&long, 'a');
    // A 2-byte character straddling byte 255 must be dropped whole.
    long[254] = 0xC3;
    long[255] = 0xA9;
    const n = Name.init(&long);
    try std.testing.expectEqual(@as(u8, 254), n.len);
    const parts = splitNumericSuffix("Cube.012");
    try std.testing.expectEqualStrings("Cube", parts.base);
    try std.testing.expectEqual(@as(?u32, 12), parts.number);
    try std.testing.expectEqual(@as(?u32, null), splitNumericSuffix("v1.2a").number);
}
