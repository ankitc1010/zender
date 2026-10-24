//! Building `Mesh` storage from polygon lists.

const std = @import("std");
const math = @import("math");
const core = @import("../core/root.zig");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const Mesh = core.types.Mesh;
const Shared = core.Shared;

pub const Polygons = struct {
    positions: []const Vec3,
    /// Face `f` owns corners `face_offsets[f] .. face_offsets[f + 1]`.
    face_offsets: []const u32,
    corner_verts: []const u32,
    /// Per corner, or empty for no UV map.
    corner_uvs: []const [2]f32 = &.{},
    /// Per face, or empty for all smooth.
    sharp_face: []const bool = &.{},
    /// Per face, or empty for slot 0 everywhere.
    material_index: []const i32 = &.{},
};

pub const BuildError = Allocator.Error || error{ InvalidTopology, TooManyAttributes };

/// Creates a Mesh with edges derived from face boundaries. Edges are numbered
/// in order of first appearance while walking faces and corners, so the
/// result depends only on the input.
pub fn fromPolygons(gpa: Allocator, p: Polygons) BuildError!Mesh {
    const n_faces = if (p.face_offsets.len == 0) 0 else p.face_offsets.len - 1;
    if (n_faces > 0 and p.face_offsets[n_faces] != p.corner_verts.len) return error.InvalidTopology;
    for (p.corner_verts) |v| if (v >= p.positions.len) return error.InvalidTopology;
    if (p.corner_uvs.len != 0 and p.corner_uvs.len != p.corner_verts.len) return error.InvalidTopology;

    var edge_map: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer edge_map.deinit(gpa);
    var edges: std.ArrayList([2]u32) = .empty;
    defer edges.deinit(gpa);
    const corner_edges = try gpa.alloc(u32, p.corner_verts.len);
    var corner_edges_owned = true;
    defer if (corner_edges_owned) gpa.free(corner_edges);

    for (0..n_faces) |f| {
        const start = p.face_offsets[f];
        const end = p.face_offsets[f + 1];
        if (end < start + 3) return error.InvalidTopology;
        for (start..end) |c| {
            const a = p.corner_verts[c];
            const b = p.corner_verts[if (c + 1 == end) start else c + 1];
            if (a == b) return error.InvalidTopology;
            const key = edgeKey(a, b);
            const gop = try edge_map.getOrPut(gpa, key);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(edges.items.len);
                try edges.append(gpa, .{ @min(a, b), @max(a, b) });
            }
            corner_edges[c] = gop.value_ptr.*;
        }
    }

    var m: Mesh = .{};
    errdefer m.releaseRefs(gpa);
    m.positions = try .fromSlice(gpa, p.positions);
    m.edges = try .fromSlice(gpa, edges.items);
    m.face_offsets = try .fromSlice(gpa, p.face_offsets);
    m.corner_verts = try .fromSlice(gpa, p.corner_verts);
    corner_edges_owned = false;
    m.corner_edges = try .fromOwned(gpa, corner_edges);
    if (p.corner_uvs.len > 0) {
        try m.setAttribute(gpa, Mesh.uv_name, .corner, .{ .float2 = try .fromSlice(gpa, p.corner_uvs) });
    }
    if (p.sharp_face.len > 0) {
        if (p.sharp_face.len != n_faces) return error.InvalidTopology;
        try m.setAttribute(gpa, "sharp_face", .face, .{ .boolean = try .fromSlice(gpa, p.sharp_face) });
    }
    if (p.material_index.len > 0) {
        if (p.material_index.len != n_faces) return error.InvalidTopology;
        try m.setAttribute(gpa, "material_index", .face, .{ .int = try .fromSlice(gpa, p.material_index) });
    }
    return m;
}

fn edgeKey(a: u32, b: u32) u64 {
    return (@as(u64, @min(a, b)) << 32) | @max(a, b);
}

/// Copy for duplicating object data; buffers stay shared until written.
pub fn copy(m: *const Mesh) Mesh {
    var out = m.*;
    out.retainRefs();
    return out;
}

/// Checks the invariants every operator must keep (FR-GEO-3); returns a
/// description of the first violation, or null.
pub fn validate(m: *const Mesh) ?[]const u8 {
    const n_verts = m.vertCount();
    const off = m.face_offsets.slice();
    const cv = m.corner_verts.slice();
    if (off.len == 1) return "face_offsets has one entry";
    if (off.len > 0) {
        if (off[0] != 0) return "face_offsets must start at 0";
        if (off[off.len - 1] != cv.len) return "face_offsets must end at the corner count";
        for (0..off.len - 1) |f| if (off[f + 1] < off[f] + 3) return "face with fewer than 3 corners";
    } else if (cv.len != 0) return "corners without faces";
    for (cv) |v| if (v >= n_verts) return "corner references a missing vertex";
    for (m.edges.slice()) |e| {
        if (e[0] >= n_verts or e[1] >= n_verts) return "edge references a missing vertex";
        if (e[0] == e[1]) return "degenerate edge";
    }
    if (m.corner_edges.len() != cv.len) return "corner_edges length mismatch";
    for (m.attrs[0..m.attr_count]) |a| {
        const want: usize = switch (a.domain) {
            .point => n_verts,
            .edge => m.edgeCount(),
            .face => m.faceCount(),
            .corner => cv.len,
        };
        if (a.data.len() != want) return "attribute length does not match its domain";
    }
    for (m.positions.slice()) |p| {
        for (p) |c| if (!std.math.isFinite(c)) return "non-finite vertex position";
    }
    return null;
}

test "cube-like quad strip derives shared edges" {
    const gpa = std.testing.allocator;
    var m = try fromPolygons(gpa, .{
        .positions = &.{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 0, 1, 0 }, .{ 2, 0, 0 }, .{ 2, 1, 0 } },
        .face_offsets = &.{ 0, 4, 8 },
        .corner_verts = &.{ 0, 1, 2, 3, 1, 4, 5, 2 },
    });
    defer m.releaseRefs(gpa);
    try std.testing.expectEqual(@as(usize, 7), m.edgeCount());
    try std.testing.expect(validate(&m) == null);
    // The shared edge 1-2 is used by both faces.
    try std.testing.expectEqual(m.corner_edges.slice()[1], m.corner_edges.slice()[7]);
}
