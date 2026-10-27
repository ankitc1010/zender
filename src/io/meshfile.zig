//! What the polygon-mesh formats (OBJ, STL, PLY) share: the result of an
//! import, and the meshes an export writes. These formats carry meshes
//! only, with world transforms applied (as Blender's exporters do by
//! default); everything else is reported as dropped (FR-IO-2).

const std = @import("std");
const math = @import("math");
const ir = @import("ir");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const v = math.vec;

/// One imported object, in engine conventions (Z up, metres).
pub const Object = struct {
    name: []const u8,
    positions: []const Vec3,
    face_offsets: []const u32,
    corner_verts: []const u32,
    /// Per corner, or empty for no UV map.
    corner_uvs: []const [2]f32 = &.{},
    /// Per face, or empty when every face is smooth.
    sharp_face: []const bool = &.{},
    /// Slot per face, or empty for slot 0 everywhere.
    material_index: []const i32 = &.{},
    /// Per slot: an index into `Imported.materials`.
    slots: []const u32 = &.{},
};

pub const Imported = struct {
    objects: []const Object,
    materials: []const ir.Material,
    /// Things the importer could not carry, one line each.
    dropped: []const []const u8,
};

pub const ExportOptions = struct {
    /// Skip render-hidden objects.
    skip_hidden: bool = true,
};

pub const Report = struct {
    objects: usize = 0,
    faces: usize = 0,
    triangles: usize = 0,
    bytes: usize = 0,
    dropped: []const []const u8 = &.{},
};

/// The mesh nodes an exporter writes, in node order; other nodes are
/// reported as dropped.
pub fn meshNodes(arena: Allocator, scene: ir.Scene, opts: ExportOptions, format: []const u8, dropped: *std.ArrayList([]const u8)) Allocator.Error![]const u32 {
    var out: std.ArrayList(u32) = .empty;
    var others: [3]usize = .{ 0, 0, 0 };
    for (scene.nodes, 0..) |n, i| {
        if (opts.skip_hidden and n.hide_render) continue;
        switch (n.kind) {
            .mesh => try out.append(arena, @intCast(i)),
            .camera => others[0] += 1,
            .light => others[1] += 1,
            .empty => others[2] += 1,
        }
    }
    for (others, [_][]const u8{ "camera", "light", "empty" }) |count, what| {
        if (count > 0) try dropped.append(arena, try std.fmt.allocPrint(arena, "{d} {s}(s) ({s} carries meshes only)", .{ count, what, format }));
    }
    return out.items;
}

/// A mesh's positions moved by its node's world matrix.
pub fn worldPositions(arena: Allocator, m: ir.Mesh, world: math.Mat4) Allocator.Error![]Vec3 {
    const out = try arena.alloc(Vec3, m.positions.len);
    for (m.positions, out) |p, *o| o.* = v.transformPoint(world, p);
    return out;
}

/// Triangles of face `f` as corner offsets within the face, appended to
/// `out` (ear clipping, so concave faces are fine).
pub fn triangulateFace(arena: Allocator, pos: []const Vec3, m: ir.Mesh, f: usize, out: *std.ArrayList(u32)) Allocator.Error!void {
    out.clearRetainingCapacity();
    try math.triangulate.triangulate(arena, pos, m.faceCorners(f), out);
}

/// Line reader that accepts \n and \r\n endings.
pub const Lines = struct {
    it: std.mem.SplitIterator(u8, .scalar),

    pub fn init(bytes: []const u8) Lines {
        return .{ .it = std.mem.splitScalar(u8, bytes, '\n') };
    }

    pub fn next(l: *Lines) ?[]const u8 {
        const line = l.it.next() orelse return null;
        return std.mem.trimEnd(u8, line, "\r");
    }
};

pub fn parseF32(s: []const u8) ?f32 {
    const x = std.fmt.parseFloat(f32, s) catch return null;
    return if (std.math.isFinite(x)) x else null;
}
