//! Mesh operators (TRD §7). Each is a pure function of the mesh, its
//! parameters and the object's world matrix (FR-GEO-1): no stored
//! selection, no thread-count dependence. Parameters agents give (offsets,
//! distances, pivots) are in world space, as scene.inspect reports bounds;
//! new positions are converted back to the mesh's local space, and
//! vertices an operator does not move keep their exact coordinates.

const std = @import("std");
const math = @import("math");
const select = @import("select.zig");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const v = math.vec;

pub const region = @import("ops/region.zig");
pub const triangulate = @import("ops/triangulate.zig");
pub const merge = @import("ops/merge.zig");
pub const transform = @import("ops/transform.zig");
pub const loopcut = @import("ops/loopcut.zig");
pub const bevel = @import("ops/bevel.zig");
pub const boolean = @import("ops/boolean.zig");

/// The object's world matrix with the inverses operators need.
pub const Xform = struct {
    m: Mat4,
    inv: Mat4,
    /// Inverse-transpose, for normals.
    nm: Mat4,

    /// Null when the matrix is singular (a zero scale), where world-space
    /// parameters have no local meaning.
    pub fn init(world: Mat4) ?Xform {
        const inv = v.invert(world) orelse return null;
        return .{ .m = world, .inv = inv, .nm = v.normalMatrix(world) };
    }

    pub const identity: Xform = .{ .m = v.identity, .inv = v.identity, .nm = v.identity };

    pub fn toWorld(x: Xform, p: Vec3) Vec3 {
        return v.transformPoint(x.m, p);
    }
    pub fn toLocal(x: Xform, p: Vec3) Vec3 {
        return v.transformPoint(x.inv, p);
    }
    pub fn dirToLocal(x: Xform, d: Vec3) Vec3 {
        return v.transformDir(x.inv, d);
    }
    /// A local normal as a unit world-space normal.
    pub fn normalToWorld(x: Xform, n: Vec3) Vec3 {
        return v.normalize(v.transformDir(x.nm, n));
    }
};

/// What an operator did, in EditMesh element indices.
pub const Outcome = struct {
    /// The elements the operator leaves selected, as Blender does: the
    /// extruded caps, the inset faces, the new edges or vertices, the
    /// triangles, the merged vertices, the moved vertices.
    domain: select.Domain,
    selected: std.ArrayList(u32) = .empty,
    /// Faces removed because they collapsed (merge).
    degenerate_faces: usize = 0,
    /// Vertices removed by merging.
    merged_verts: usize = 0,
    /// Loop cut: rings cut. Loop cut and bevel: inputs skipped (seeds
    /// bordering no quad, edges without two faces).
    rings: usize = 0,
    skipped: usize = 0,
    /// Bevel: the width used, after any reduction to avoid overlaps.
    width_used: f32 = 0,

    pub fn deinit(o: *Outcome, gpa: Allocator) void {
        o.selected.deinit(gpa);
    }
};

pub const Error = @import("editmesh.zig").Error || math.DeadlineError || error{
    /// Moving along the normal was asked for, but the selection has none
    /// (loose vertices or edges, or normals that cancel out).
    NoNormal,
    /// A vertex of the input lies on a boundary, has more than one fan of
    /// faces, or has neighbours wound the opposite way (bevel).
    NonManifold,
};

test {
    _ = region;
    _ = triangulate;
    _ = merge;
    _ = transform;
    _ = loopcut;
    _ = bevel;
    _ = boolean;
}
