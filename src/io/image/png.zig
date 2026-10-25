//! PNG encoder (8-bit RGB / RGBA), deterministic for given pixels and level,
//! and a decoder for 8-bit, non-interlaced greyscale and truecolour images.

const std = @import("std");
const flate = std.compress.flate;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Level = enum { fast, default };

pub const Image = struct {
    width: u32,
    height: u32,
    /// 3 (RGB) or 4 (RGBA) for encode; decode also gives 1 (grey) and
    /// 2 (grey + alpha).
    channels: u8,
    /// Row-major, top row first, `width * height * channels` bytes.
    pixels: []const u8,
};

const signature = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };

pub fn encode(gpa: Allocator, img: Image, level: Level, out: *Writer) (Allocator.Error || Writer.Error)!void {
    std.debug.assert(img.channels == 3 or img.channels == 4);
    std.debug.assert(img.pixels.len == @as(usize, img.width) * img.height * img.channels);
    try out.writeAll(&signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], img.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], img.height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = if (img.channels == 4) 6 else 2; // colour type
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try chunk(out, "IHDR", &ihdr);

    // Filter every row, choosing the filter with the smallest sum of
    // absolute values (the usual heuristic), then deflate with zlib framing.
    const stride = @as(usize, img.width) * img.channels;
    const filtered = try gpa.alloc(u8, (stride + 1) * img.height);
    defer gpa.free(filtered);
    const scratch = try gpa.alloc(u8, stride * 5);
    defer gpa.free(scratch);
    for (0..img.height) |y| {
        const row = img.pixels[y * stride ..][0..stride];
        const prev: ?[]const u8 = if (y == 0) null else img.pixels[(y - 1) * stride ..][0..stride];
        var best: u8 = 0;
        var best_cost: u64 = std.math.maxInt(u64);
        for (0..5) |f| {
            const dst = scratch[f * stride ..][0..stride];
            const cost = filterRow(@intCast(f), row, prev, img.channels, dst);
            if (cost < best_cost) {
                best_cost = cost;
                best = @intCast(f);
            }
        }
        const o = filtered[y * (stride + 1) ..];
        o[0] = best;
        @memcpy(o[1 .. stride + 1], scratch[best * stride ..][0..stride]);
    }

    var z = try std.Io.Writer.Allocating.initCapacity(gpa, filtered.len / 2 + 64);
    defer z.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var c = try flate.Compress.init(&z.writer, window, .zlib, switch (level) {
        .fast => .level_1,
        .default => .default,
    });
    c.writer.writeAll(filtered) catch return error.OutOfMemory;
    c.finish() catch return error.OutOfMemory;
    try chunk(out, "IDAT", z.written());
    try chunk(out, "IEND", "");
}

fn chunk(out: *Writer, kind: *const [4]u8, data: []const u8) Writer.Error!void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.writeAll(&len);
    try out.writeAll(kind);
    try out.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var c: [4]u8 = undefined;
    std.mem.writeInt(u32, &c, crc.final(), .big);
    try out.writeAll(&c);
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

pub const DecodeError = Allocator.Error || error{ NotPng, Unsupported, Corrupt, TooLarge };

/// Largest decoded image accepted, in bytes.
pub const max_decoded = 1 << 30;

/// Decodes an 8-bit, non-interlaced greyscale, grey + alpha, RGB or RGBA
/// PNG, checking every chunk CRC. Palettes, 16-bit samples and Adam7 are
/// reported as Unsupported (image.load in P2 extends this). The returned
/// pixels belong to the caller.
pub fn decode(gpa: Allocator, bytes: []const u8) DecodeError!Image {
    if (bytes.len < signature.len or !std.mem.eql(u8, bytes[0..8], &signature)) return error.NotPng;
    var pos: usize = 8;
    var header: ?Image = null;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    while (true) {
        if (bytes.len - pos < 12) return error.Corrupt;
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        if (len > bytes.len - pos - 12) return error.Corrupt;
        const kind = bytes[pos + 4 ..][0..4];
        const data = bytes[pos + 8 ..][0..len];
        var crc = std.hash.Crc32.init();
        crc.update(kind);
        crc.update(data);
        if (crc.final() != std.mem.readInt(u32, bytes[pos + 8 + len ..][0..4], .big)) return error.Corrupt;
        pos += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len != 13) return error.Corrupt;
            const channels: u8 = switch (data[9]) {
                0 => 1,
                2 => 3,
                4 => 2,
                6 => 4,
                else => return error.Unsupported, // palette or invalid
            };
            if (data[8] != 8 or data[10] != 0 or data[11] != 0 or data[12] != 0) return error.Unsupported;
            header = .{ .width = std.mem.readInt(u32, data[0..4], .big), .height = std.mem.readInt(u32, data[4..8], .big), .channels = channels, .pixels = &.{} };
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        } else if (kind[0] & 0x20 == 0) {
            return error.Unsupported; // an unknown critical chunk
        }
    }
    var img = header orelse return error.Corrupt;
    if (img.width == 0 or img.height == 0) return error.Corrupt;
    const stride = @as(u64, img.width) * img.channels;
    const size = stride * img.height;
    if (size > max_decoded) return error.TooLarge;

    const raw = try gpa.alloc(u8, @intCast((stride + 1) * img.height));
    defer gpa.free(raw);
    var in: std.Io.Reader = .fixed(idat.items);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var z = flate.Decompress.init(&in, .zlib, window);
    z.reader.readSliceAll(raw) catch return error.Corrupt;

    const pixels = try gpa.alloc(u8, @intCast(size));
    errdefer gpa.free(pixels);
    const bpp: usize = img.channels;
    const w: usize = @intCast(stride);
    for (0..img.height) |y| {
        const f = raw[y * (w + 1)];
        const src = raw[y * (w + 1) + 1 ..][0..w];
        const row = pixels[y * w ..][0..w];
        const prev: ?[]const u8 = if (y > 0) pixels[(y - 1) * w ..][0..w] else null;
        for (src, 0..) |x, i| {
            const a: u8 = if (i >= bpp) row[i - bpp] else 0;
            const b: u8 = if (prev) |p| p[i] else 0;
            const c: u8 = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;
            const pred: u8 = switch (f) {
                0 => 0,
                1 => a,
                2 => b,
                3 => @intCast((@as(u16, a) + b) / 2),
                4 => paeth(a, b, c),
                else => return error.Corrupt,
            };
            row[i] = x +% pred;
        }
    }
    img.pixels = pixels;
    return img;
}

fn filterRow(f: u8, row: []const u8, prev: ?[]const u8, bpp: usize, dst: []u8) u64 {
    var cost: u64 = 0;
    for (row, 0..) |x, i| {
        const a: u8 = if (i >= bpp) row[i - bpp] else 0;
        const b: u8 = if (prev) |p| p[i] else 0;
        const c: u8 = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;
        const pred: u8 = switch (f) {
            0 => 0,
            1 => a,
            2 => b,
            3 => @intCast((@as(u16, a) + b) / 2),
            else => paeth(a, b, c),
        };
        const r = x -% pred;
        dst[i] = r;
        cost += @abs(@as(i8, @bitCast(r)));
    }
    return cost;
}

test "encodes a small image with valid chunk CRCs" {
    const gpa = std.testing.allocator;
    var px: [4 * 3 * 3]u8 = undefined;
    for (&px, 0..) |*p, i| p.* = @intCast(i * 7 % 256);
    var out = std.Io.Writer.Allocating.init(gpa);
    defer out.deinit();
    try encode(gpa, .{ .width = 3, .height = 3, .channels = 4, .pixels = &px }, .default, &out.writer);
    const bytes = out.written();
    try std.testing.expectEqualSlices(u8, &signature, bytes[0..8]);
    try std.testing.expectEqualStrings("IHDR", bytes[12..16]);
    try std.testing.expectEqualStrings("IEND", bytes[bytes.len - 8 .. bytes.len - 4]);
}

test "decode inverts encode and rejects damaged files" {
    const gpa = std.testing.allocator;
    var px: [4 * 17 * 9]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(42);
    for (&px, 0..) |*p, i| p.* = if (i % 3 == 0) rng.random().int(u8) else @intCast(i * 5 % 256);
    for ([_]u8{ 3, 4 }) |channels| {
        const n = 17 * 9 * @as(usize, channels);
        var out = std.Io.Writer.Allocating.init(gpa);
        defer out.deinit();
        try encode(gpa, .{ .width = 17, .height = 9, .channels = channels, .pixels = px[0..n] }, .default, &out.writer);
        const img = try decode(gpa, out.written());
        defer gpa.free(img.pixels);
        try std.testing.expectEqual(@as(u32, 17), img.width);
        try std.testing.expectEqual(channels, img.channels);
        try std.testing.expectEqualSlices(u8, px[0..n], img.pixels);

        const bad = try gpa.dupe(u8, out.written());
        defer gpa.free(bad);
        bad[bad.len - 20] ^= 1; // inside IDAT
        try std.testing.expectError(error.Corrupt, decode(gpa, bad));
    }
    try std.testing.expectError(error.NotPng, decode(gpa, "GIF89a"));
}
