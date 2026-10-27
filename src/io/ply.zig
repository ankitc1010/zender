//! PLY (Stanford polygon format), ASCII and binary in either byte order,
//! read and written Z up and unscaled as Blender's PLY importer and
//! exporter do by default. Reading takes vertex x y z, per-vertex UVs
//! (s t, u v or texture_u texture_v) and faces as `vertex_indices` (or
//! `vertex_index`) lists, n-gons kept; normals, colours, other properties
//! and other elements are reported as dropped. Writing produces binary
//! little-endian PLY with positions, per-vertex UVs (vertices split where
//! UVs differ) and polygon faces, all objects merged with their world
//! transforms applied.

const std = @import("std");
const math = @import("math");
const ir = @import("ir");
const mf = @import("meshfile.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Vec3 = math.Vec3;

pub const ParseError = Allocator.Error || error{InvalidFile};

const Scalar = enum {
    i8,
    u8,
    i16,
    u16,
    i32,
    u32,
    f32,
    f64,

    fn parse(s: []const u8) ?Scalar {
        const names = [_]struct { []const u8, Scalar }{
            .{ "char", .i8 },   .{ "int8", .i8 },     .{ "uchar", .u8 },   .{ "uint8", .u8 },
            .{ "short", .i16 }, .{ "int16", .i16 },   .{ "ushort", .u16 }, .{ "uint16", .u16 },
            .{ "int", .i32 },   .{ "int32", .i32 },   .{ "uint", .u32 },   .{ "uint32", .u32 },
            .{ "float", .f32 }, .{ "float32", .f32 }, .{ "double", .f64 }, .{ "float64", .f64 },
        };
        for (names) |n| if (std.mem.eql(u8, n[0], s)) return n[1];
        return null;
    }

    fn size(s: Scalar) usize {
        return switch (s) {
            .i8, .u8 => 1,
            .i16, .u16 => 2,
            .i32, .u32, .f32 => 4,
            .f64 => 8,
        };
    }
};

const Property = struct {
    name: []const u8,
    type: Scalar,
    /// For lists: the type of the count.
    count: ?Scalar = null,
};

const Element = struct {
    name: []const u8,
    count: usize,
    props: std.ArrayList(Property) = .empty,
};

const Format = enum { ascii, binary_little_endian, binary_big_endian };

/// Reads values in the file's encoding.
const Reader = struct {
    bytes: []const u8,
    pos: usize,
    format: Format,
    toks: std.mem.TokenIterator(u8, .any) = undefined,

    fn value(r: *Reader, t: Scalar) ParseError!f64 {
        if (r.format == .ascii) {
            while (true) {
                if (r.toks.next()) |tok| return std.fmt.parseFloat(f64, tok) catch error.InvalidFile;
                const end = std.mem.indexOfScalarPos(u8, r.bytes, r.pos, '\n') orelse r.bytes.len;
                if (r.pos >= r.bytes.len) return error.InvalidFile;
                r.toks = std.mem.tokenizeAny(u8, r.bytes[r.pos..end], " \t\r");
                r.pos = end + 1;
            }
        }
        const n = t.size();
        if (r.pos + n > r.bytes.len) return error.InvalidFile;
        const b = r.bytes[r.pos..][0..n];
        r.pos += n;
        const e: std.builtin.Endian = if (r.format == .binary_little_endian) .little else .big;
        return switch (t) {
            .i8 => @floatFromInt(@as(i8, @bitCast(b[0]))),
            .u8 => @floatFromInt(b[0]),
            .i16 => @floatFromInt(std.mem.readInt(i16, b[0..2], e)),
            .u16 => @floatFromInt(std.mem.readInt(u16, b[0..2], e)),
            .i32 => @floatFromInt(std.mem.readInt(i32, b[0..4], e)),
            .u32 => @floatFromInt(std.mem.readInt(u32, b[0..4], e)),
            .f32 => @as(f32, @bitCast(std.mem.readInt(u32, b[0..4], e))),
            .f64 => @bitCast(std.mem.readInt(u64, b[0..8], e)),
        };
    }
};

fn findProp(props: []const Property, names: []const []const u8) ?usize {
    for (names) |n| for (props, 0..) |p, i| if (std.mem.eql(u8, p.name, n)) return i;
    return null;
}

pub fn parse(arena: Allocator, bytes: []const u8, default_name: []const u8) ParseError!mf.Imported {
    if (!std.mem.startsWith(u8, bytes, "ply")) return error.InvalidFile;
    const end_tag = "end_header";
    const at = std.mem.indexOf(u8, bytes, end_tag) orelse return error.InvalidFile;
    const body = (std.mem.indexOfScalarPos(u8, bytes, at, '\n') orelse return error.InvalidFile) + 1;
    var format: ?Format = null;
    var elements: std.ArrayList(Element) = .empty;
    var lines = mf.Lines.init(bytes[0..at]);
    while (lines.next()) |line| {
        var toks = std.mem.tokenizeAny(u8, line, " \t");
        const key = toks.next() orelse continue;
        if (std.mem.eql(u8, key, "format")) {
            format = std.meta.stringToEnum(Format, toks.next() orelse "") orelse return error.InvalidFile;
        } else if (std.mem.eql(u8, key, "element")) {
            const name = toks.next() orelse return error.InvalidFile;
            const count = std.fmt.parseInt(usize, toks.next() orelse "", 10) catch return error.InvalidFile;
            try elements.append(arena, .{ .name = name, .count = count });
        } else if (std.mem.eql(u8, key, "property")) {
            if (elements.items.len == 0) return error.InvalidFile;
            const t = toks.next() orelse return error.InvalidFile;
            var prop: Property = undefined;
            if (std.mem.eql(u8, t, "list")) {
                const ct = Scalar.parse(toks.next() orelse "") orelse return error.InvalidFile;
                const it = Scalar.parse(toks.next() orelse "") orelse return error.InvalidFile;
                prop = .{ .name = toks.next() orelse return error.InvalidFile, .type = it, .count = ct };
            } else {
                prop = .{ .name = toks.next() orelse return error.InvalidFile, .type = Scalar.parse(t) orelse return error.InvalidFile };
            }
            try elements.items[elements.items.len - 1].props.append(arena, prop);
        }
    }
    var r: Reader = .{ .bytes = bytes, .pos = body, .format = format orelse return error.InvalidFile };
    if (r.format == .ascii) r.toks = std.mem.tokenizeAny(u8, "", " ");

    var dropped: std.ArrayList([]const u8) = .empty;
    var positions: std.ArrayList(Vec3) = .empty;
    var vuv: std.ArrayList([2]f32) = .empty;
    var offsets: std.ArrayList(u32) = .empty;
    var corners: std.ArrayList(u32) = .empty;
    var bad_faces: usize = 0;
    var saw_vertex = false;
    var row: std.ArrayList(f64) = .empty;
    for (elements.items) |el| {
        const is_vertex = std.mem.eql(u8, el.name, "vertex");
        const is_face = std.mem.eql(u8, el.name, "face");
        if (!is_vertex and !is_face and el.count > 0) try dropped.append(arena, try std.fmt.allocPrint(arena, "{d} '{s}' element(s)", .{ el.count, el.name }));
        const props = el.props.items;
        const xyz = [3]?usize{ findProp(props, &.{"x"}), findProp(props, &.{"y"}), findProp(props, &.{"z"}) };
        const uvp = [2]?usize{ findProp(props, &.{ "s", "u", "texture_u" }), findProp(props, &.{ "t", "v", "texture_v" }) };
        const list = findProp(props, &.{ "vertex_indices", "vertex_index" });
        if (is_vertex) {
            if (xyz[0] == null or xyz[1] == null or xyz[2] == null) return error.InvalidFile;
            saw_vertex = true;
            for (props, 0..) |p, i| {
                const used = i == xyz[0].? or i == xyz[1].? or i == xyz[2].? or (uvp[0] != null and i == uvp[0].?) or (uvp[1] != null and i == uvp[1].?);
                if (!used) try dropped.append(arena, try std.fmt.allocPrint(arena, "vertex property '{s}'", .{p.name}));
            }
        }
        if (is_face) {
            if (list == null) return error.InvalidFile;
            for (props, 0..) |p, i| if (i != list.?) try dropped.append(arena, try std.fmt.allocPrint(arena, "face property '{s}'", .{p.name}));
        }
        try row.resize(arena, props.len);
        for (0..el.count) |_| {
            const start: u32 = @intCast(corners.items.len);
            var in_range = true;
            for (props, 0..) |p, i| {
                if (p.count) |ct| {
                    const n: usize = @intFromFloat(@max(0, try r.value(ct)));
                    for (0..n) |_| {
                        const x = try r.value(p.type);
                        if (!is_face or i != list.?) continue;
                        if (x < 0 or x >= @as(f64, @floatFromInt(positions.items.len))) {
                            in_range = false;
                        } else try corners.append(arena, @intFromFloat(x));
                    }
                } else row.items[i] = try r.value(p.type);
            }
            if (is_vertex) {
                try positions.append(arena, .{ @floatCast(row.items[xyz[0].?]), @floatCast(row.items[xyz[1].?]), @floatCast(row.items[xyz[2].?]) });
                if (uvp[0] != null and uvp[1] != null) try vuv.append(arena, .{ @floatCast(row.items[uvp[0].?]), @floatCast(row.items[uvp[1].?]) });
            }
            if (is_face) {
                const cs = corners.items[start..];
                if (!in_range or cs.len < 3 or !distinct(cs)) {
                    corners.items.len = start;
                    bad_faces += 1;
                    continue;
                }
                try offsets.append(arena, start);
            }
        }
    }
    if (!saw_vertex) return error.InvalidFile;
    if (bad_faces > 0) try dropped.append(arena, try std.fmt.allocPrint(arena, "{d} face(s) with bad indices or fewer than 3 distinct corners", .{bad_faces}));
    if (offsets.items.len > 0) try offsets.append(arena, @intCast(corners.items.len));
    var uvs: []const [2]f32 = &.{};
    if (vuv.items.len == positions.items.len and vuv.items.len > 0) {
        const per_corner = try arena.alloc([2]f32, corners.items.len);
        for (corners.items, per_corner) |x, *o| o.* = vuv.items[x];
        uvs = per_corner;
    }
    const sharp = try arena.alloc(bool, if (offsets.items.len == 0) 0 else offsets.items.len - 1);
    @memset(sharp, true);
    const objects = try arena.alloc(mf.Object, 1);
    objects[0] = .{ .name = default_name, .positions = positions.items, .face_offsets = offsets.items, .corner_verts = corners.items, .corner_uvs = uvs, .sharp_face = sharp };
    return .{ .objects = objects, .materials = &.{}, .dropped = dropped.items };
}

fn distinct(xs: []const u32) bool {
    for (xs, 0..) |a, i| for (xs[i + 1 ..]) |b| if (a == b) return false;
    return true;
}

/// Writes `scene`'s meshes as one binary little-endian PLY.
pub fn write(arena: Allocator, scene: ir.Scene, opts: mf.ExportOptions, generator: []const u8, out: *Writer) (Allocator.Error || Writer.Error)!mf.Report {
    var report: mf.Report = .{};
    var dropped: std.ArrayList([]const u8) = .empty;
    const nodes = try mf.meshNodes(arena, scene, opts, "PLY", &dropped);
    // Output vertices: one per distinct (position, UV) pair.
    var out_pos: std.ArrayList(Vec3) = .empty;
    var out_uv: std.ArrayList([2]f32) = .empty;
    var faces: std.ArrayList(u32) = .empty;
    var sizes: std.ArrayList(u8) = .empty;
    var any_uv = false;
    var any_mat = false;
    var big_faces: usize = 0;
    var tri: std.ArrayList(u32) = .empty;
    for (nodes) |ni| any_uv = any_uv or scene.meshes[scene.nodes[ni].kind.mesh].corner_uvs.len > 0;
    for (nodes) |ni| {
        const node = scene.nodes[ni];
        const m = scene.meshes[node.kind.mesh];
        report.objects += 1;
        for (node.materials) |s| any_mat = any_mat or s != null;
        const pos = try mf.worldPositions(arena, m, node.world);
        var map: std.AutoHashMapUnmanaged([3]u32, u32) = .empty;
        for (0..m.faceCount()) |f| {
            const lo = m.face_offsets[f];
            const hi = m.face_offsets[f + 1];
            // List counts are written as uchar; bigger faces are fanned.
            if (hi - lo > 255) big_faces += 1;
            var ids: std.ArrayList(u32) = .empty;
            for (lo..hi) |k| {
                const x = m.corner_verts[k];
                const uv: [2]f32 = if (m.corner_uvs.len > 0) m.corner_uvs[k] else .{ 0, 0 };
                const key: [3]u32 = .{ x, @bitCast(uv[0]), @bitCast(uv[1]) };
                const gop = try map.getOrPut(arena, key);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(out_pos.items.len);
                    try out_pos.append(arena, pos[x]);
                    try out_uv.append(arena, uv);
                }
                try ids.append(arena, gop.value_ptr.*);
            }
            if (ids.items.len <= 255) {
                try sizes.append(arena, @intCast(ids.items.len));
                try faces.appendSlice(arena, ids.items);
            } else {
                try mf.triangulateFace(arena, pos, m, f, &tri);
                var i: usize = 0;
                while (i + 2 < tri.items.len) : (i += 3) {
                    try sizes.append(arena, 3);
                    for (0..3) |j| try faces.append(arena, ids.items[tri.items[i + j]]);
                }
            }
            report.faces += 1;
            try mf.triangulateFace(arena, pos, m, f, &tri);
            report.triangles += tri.items.len / 3;
        }
    }
    if (any_mat) try dropped.append(arena, "materials (PLY has none)");
    if (report.objects > 1) try dropped.append(arena, try std.fmt.allocPrint(arena, "object boundaries: {d} objects written as one mesh", .{report.objects}));
    if (big_faces > 0) try dropped.append(arena, try std.fmt.allocPrint(arena, "{d} face(s) over 255 corners, written as triangles", .{big_faces}));
    try out.print("ply\nformat binary_little_endian 1.0\ncomment {s}\nelement vertex {d}\nproperty float x\nproperty float y\nproperty float z\n", .{ generator, out_pos.items.len });
    if (any_uv) try out.writeAll("property float s\nproperty float t\n");
    try out.print("element face {d}\nproperty list uchar uint vertex_indices\nend_header\n", .{sizes.items.len});
    for (out_pos.items, out_uv.items) |p, uv| {
        for (p) |x| try out.writeInt(u32, @bitCast(x), .little);
        if (any_uv) for (uv) |x| try out.writeInt(u32, @bitCast(x), .little);
    }
    var at: usize = 0;
    for (sizes.items) |n| {
        try out.writeByte(n);
        for (faces.items[at..][0..n]) |x| try out.writeInt(u32, x, .little);
        at += n;
    }
    report.dropped = dropped.items;
    return report;
}

const testing = std.testing;

test "PLY: ASCII and binary headers, n-gons, UVs and unknown properties" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ascii =
        \\ply
        \\format ascii 1.0
        \\comment a pentagon and a triangle
        \\element vertex 6
        \\property float x
        \\property float y
        \\property float z
        \\property uchar red
        \\property float s
        \\property float t
        \\element face 3
        \\property list uchar int vertex_indices
        \\end_header
        \\0 0 0 255 0 0
        \\1 0 0 255 1 0
        \\1.5 1 0 255 1 0.5
        \\0.5 2 0 255 0.5 1
        \\-0.5 1 0 255 0 0.5
        \\0 0 1 0 0 0
        \\5 0 1 2 3 4
        \\3 0 1 5
        \\3 0 0 1
        \\
    ;
    const a = try parse(arena, ascii, "Mesh");
    const o = a.objects[0];
    try testing.expectEqual(@as(usize, 6), o.positions.len);
    try testing.expectEqualSlices(u32, &.{ 0, 5, 8 }, o.face_offsets);
    try testing.expectEqual([2]f32{ 1, 0.5 }, o.corner_uvs[2]);
    // 'red' and the degenerate third face are reported.
    try testing.expectEqual(@as(usize, 2), a.dropped.len);

    // Binary big-endian with a uint index list.
    var buf: std.Io.Writer.Allocating = .init(arena);
    try buf.writer.writeAll("ply\nformat binary_big_endian 1.0\nelement vertex 3\nproperty double x\nproperty double y\nproperty double z\nelement face 1\nproperty list uchar uint vertex_indices\nend_header\n");
    for ([_]f64{ 0, 0, 0, 1, 0, 0, 0, 1, 0 }) |x| try buf.writer.writeInt(u64, @bitCast(x), .big);
    try buf.writer.writeByte(3);
    for ([_]u32{ 0, 1, 2 }) |x| try buf.writer.writeInt(u32, x, .big);
    const b = try parse(arena, buf.written(), "Mesh");
    try testing.expectEqual(Vec3{ 0, 1, 0 }, b.objects[0].positions[2]);
    try testing.expectEqual(@as(usize, 3), b.objects[0].corner_verts.len);
    try testing.expectError(error.InvalidFile, parse(arena, "ply\nformat ascii 1.0\nend_header\n", "Mesh"));
}
