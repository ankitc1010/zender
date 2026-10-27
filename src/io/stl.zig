//! STL, binary and ASCII, read and written Z up and unscaled as Blender's
//! STL importer and exporter do by default. Reading welds corners with
//! identical coordinates into shared vertices, so the triangles form one
//! connected mesh; facet normals and attribute bytes are not kept.
//! Writing produces binary STL, every face triangulated, all objects in one
//! file with their world transforms applied.

const std = @import("std");
const math = @import("math");
const ir = @import("ir");
const mf = @import("meshfile.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Vec3 = math.Vec3;
const v = math.vec;

pub const ParseError = Allocator.Error || error{InvalidFile};

/// Binary when the size matches the triangle count in the header, which
/// also covers binary files whose header starts with "solid".
fn isBinary(bytes: []const u8) bool {
    if (bytes.len < 84) return false;
    const n = std.mem.readInt(u32, bytes[80..84], .little);
    return @as(u64, 84) + @as(u64, n) * 50 == bytes.len;
}

pub fn parse(arena: Allocator, bytes: []const u8, default_name: []const u8) ParseError!mf.Imported {
    var b: Welder = .{};
    var dropped: std.ArrayList([]const u8) = .empty;
    var name = default_name;
    if (isBinary(bytes)) {
        const n = std.mem.readInt(u32, bytes[80..84], .little);
        try b.reserve(arena, n);
        var attrs = false;
        for (0..n) |i| {
            const rec = bytes[84 + i * 50 ..][0..50];
            var tri: [3]Vec3 = undefined;
            for (&tri, 0..) |*p, k| for (p, 0..) |*x, d| {
                x.* = @bitCast(std.mem.readInt(u32, rec[12 + k * 12 + d * 4 ..][0..4], .little));
            };
            if (std.mem.readInt(u16, rec[48..50], .little) != 0) attrs = true;
            try b.triangle(arena, tri);
        }
        if (attrs) try dropped.append(arena, "per-triangle attribute bytes (some tools store colours there)");
    } else {
        var lines = mf.Lines.init(bytes);
        var tri: [3]Vec3 = undefined;
        var k: usize = 0;
        var any = false;
        while (lines.next()) |line| {
            var toks = std.mem.tokenizeAny(u8, line, " \t");
            const key = toks.next() orelse continue;
            if (std.mem.eql(u8, key, "solid")) {
                const rest = std.mem.trim(u8, toks.rest(), " \t");
                if (rest.len > 0 and !any) name = try arena.dupe(u8, rest);
            } else if (std.mem.eql(u8, key, "vertex")) {
                if (k == 3) return error.InvalidFile;
                for (&tri[k]) |*x| x.* = mf.parseF32(toks.next() orelse "") orelse return error.InvalidFile;
                k += 1;
            } else if (std.mem.eql(u8, key, "endloop")) {
                if (k != 3) return error.InvalidFile;
                try b.triangle(arena, tri);
                k = 0;
                any = true;
            }
        }
        if (!any) return error.InvalidFile;
    }
    if (b.degenerate > 0) try dropped.append(arena, try std.fmt.allocPrint(arena, "{d} triangle(s) with repeated corners", .{b.degenerate}));
    const objects = try arena.alloc(mf.Object, 1);
    objects[0] = try b.object(arena, name);
    return .{ .objects = objects, .materials = &.{}, .dropped = dropped.items };
}

/// Builds shared vertices from unindexed triangles by exact coordinates.
pub const Welder = struct {
    map: std.AutoHashMapUnmanaged([3]u32, u32) = .empty,
    positions: std.ArrayList(Vec3) = .empty,
    corners: std.ArrayList(u32) = .empty,
    degenerate: usize = 0,

    pub fn reserve(w: *Welder, arena: Allocator, tris: usize) Allocator.Error!void {
        try w.corners.ensureTotalCapacity(arena, 3 * tris);
        try w.map.ensureTotalCapacity(arena, @intCast(@min(3 * tris, std.math.maxInt(u32))));
    }

    pub fn vertex(w: *Welder, arena: Allocator, p: Vec3) Allocator.Error!u32 {
        // +0 and -0 weld together.
        const q: Vec3 = .{ p[0] + 0, p[1] + 0, p[2] + 0 };
        const gop = try w.map.getOrPut(arena, .{ @bitCast(q[0]), @bitCast(q[1]), @bitCast(q[2]) });
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(w.positions.items.len);
            try w.positions.append(arena, q);
        }
        return gop.value_ptr.*;
    }

    pub fn triangle(w: *Welder, arena: Allocator, tri: [3]Vec3) Allocator.Error!void {
        var ids: [3]u32 = undefined;
        for (tri, &ids) |p, *i| i.* = try w.vertex(arena, p);
        if (ids[0] == ids[1] or ids[1] == ids[2] or ids[0] == ids[2]) {
            w.degenerate += 1;
            return;
        }
        try w.corners.appendSlice(arena, &ids);
    }

    pub fn object(w: *Welder, arena: Allocator, name: []const u8) Allocator.Error!mf.Object {
        const n = w.corners.items.len / 3;
        const offsets = try arena.alloc(u32, if (n == 0) 0 else n + 1);
        for (offsets, 0..) |*o, i| o.* = @intCast(3 * i);
        // Blender's STL importer leaves faces flat.
        const sharp = try arena.alloc(bool, n);
        @memset(sharp, true);
        return .{ .name = name, .positions = w.positions.items, .face_offsets = offsets, .corner_verts = w.corners.items, .sharp_face = sharp };
    }
};

/// Writes `scene`'s meshes as one binary STL.
pub fn write(arena: Allocator, scene: ir.Scene, opts: mf.ExportOptions, out: *Writer) (Allocator.Error || Writer.Error)!mf.Report {
    var report: mf.Report = .{};
    var dropped: std.ArrayList([]const u8) = .empty;
    const nodes = try mf.meshNodes(arena, scene, opts, "STL", &dropped);
    var tris: std.ArrayList([3]Vec3) = .empty;
    var tri: std.ArrayList(u32) = .empty;
    var any_uv = false;
    var any_mat = false;
    for (nodes) |ni| {
        const node = scene.nodes[ni];
        const m = scene.meshes[node.kind.mesh];
        report.objects += 1;
        report.faces += m.faceCount();
        any_uv = any_uv or m.corner_uvs.len > 0;
        for (node.materials) |s| any_mat = any_mat or s != null;
        const pos = try mf.worldPositions(arena, m, node.world);
        for (0..m.faceCount()) |f| {
            try mf.triangulateFace(arena, pos, m, f, &tri);
            const cs = m.faceCorners(f);
            var i: usize = 0;
            while (i + 2 < tri.items.len) : (i += 3) {
                try tris.append(arena, .{ pos[cs[tri.items[i]]], pos[cs[tri.items[i + 1]]], pos[cs[tri.items[i + 2]]] });
            }
        }
    }
    if (any_uv) try dropped.append(arena, "UV maps (STL has none)");
    if (any_mat) try dropped.append(arena, "materials (STL has none)");
    if (report.objects > 1) try dropped.append(arena, try std.fmt.allocPrint(arena, "object boundaries: {d} objects written as one mesh", .{report.objects}));
    var header: [80]u8 = @splat(' ');
    const text = "Zender binary STL";
    @memcpy(header[0..text.len], text);
    try out.writeAll(&header);
    try out.writeInt(u32, @intCast(tris.items.len), .little);
    for (tris.items) |t| {
        const n = v.normalize(v.cross(v.sub(t[1], t[0]), v.sub(t[2], t[0])));
        for ([_]Vec3{ n, t[0], t[1], t[2] }) |p| for (p) |x| try out.writeInt(u32, @bitCast(x), .little);
        try out.writeInt(u16, 0, .little);
    }
    report.triangles = tris.items.len;
    report.bytes = 84 + 50 * tris.items.len;
    report.dropped = dropped.items;
    return report;
}

const testing = std.testing;

test "STL: ASCII and binary parse to the same welded mesh" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ascii =
        \\solid square
        \\ facet normal 0 0 1
        \\  outer loop
        \\   vertex 0 0 0
        \\   vertex 1 0 0
        \\   vertex 1 1 0
        \\  endloop
        \\ endfacet
        \\ facet normal 0 0 1
        \\  outer loop
        \\   vertex 0 0 0
        \\   vertex 1 1 0
        \\   vertex 0 1 0
        \\  endloop
        \\ endfacet
        \\endsolid square
        \\
    ;
    const a = try parse(arena, ascii, "Mesh");
    try testing.expectEqualStrings("square", a.objects[0].name);
    try testing.expectEqual(@as(usize, 4), a.objects[0].positions.len);
    try testing.expectEqual(@as(usize, 6), a.objects[0].corner_verts.len);

    // The same two triangles in binary, header starting with "solid".
    var buf: std.Io.Writer.Allocating = .init(arena);
    var header: [80]u8 = @splat(0);
    @memcpy(header[0..5], "solid");
    try buf.writer.writeAll(&header);
    try buf.writer.writeInt(u32, 2, .little);
    const tris = [2][3]Vec3{ .{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 1, 0 } }, .{ .{ 0, 0, 0 }, .{ 1, 1, 0 }, .{ 0, 1, 0 } } };
    for (tris) |t| {
        for ([_]Vec3{ .{ 0, 0, 1 }, t[0], t[1], t[2] }) |p| for (p) |x| try buf.writer.writeInt(u32, @bitCast(x), .little);
        try buf.writer.writeInt(u16, 0, .little);
    }
    const b = try parse(arena, buf.written(), "Mesh");
    try testing.expectEqualSlices(u32, a.objects[0].corner_verts, b.objects[0].corner_verts);
    try testing.expectEqualSlices(Vec3, a.objects[0].positions, b.objects[0].positions);
    try testing.expectError(error.InvalidFile, parse(arena, "solid x\nendsolid x\n", "Mesh"));
}
