//! Interchange representation: a flat, read-only snapshot of an evaluated
//! scene. The engine produces it; render and file I/O consume it (and the
//! importers produce it), so neither of those layers depends on the database.
//!
//! Everything is in engine conventions: Z-up, metres, radians, scene-linear
//! Rec.709. Exporters convert at their own boundary.

const std = @import("std");
const math = @import("math");
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const Quat = math.Quat;
const Mat4 = math.Mat4;

pub const Scene = struct {
    name: []const u8,
    nodes: []const Node,
    meshes: []const Mesh,
    materials: []const Material,
    cameras: []const Camera,
    lights: []const Light,
    world: World,
    /// Node index of the active camera.
    active_camera: ?u32,
    /// Final render size in pixels (resolution × percentage already applied).
    resolution: [2]u32,
    fps: f32,
    frame_start: i32,
    frame_end: i32,
};

pub const NodeKind = union(enum) {
    empty,
    mesh: u32,
    camera: u32,
    light: u32,
};

pub const Node = struct {
    name: []const u8,
    /// Index into `Scene.nodes`; parents always come before children.
    parent: ?u32,
    /// Local matrix relative to the parent (parent inverse already folded in).
    local: Mat4,
    world: Mat4,
    kind: NodeKind,
    /// Material per slot, for mesh nodes. `null` slots render with a default.
    materials: []const ?u32,
    hide_render: bool,
};

pub const Mesh = struct {
    name: []const u8,
    positions: []const Vec3,
    /// Face `f` owns corners `face_offsets[f] .. face_offsets[f + 1]`.
    face_offsets: []const u32,
    corner_verts: []const u32,
    /// Evaluated per-corner normals (face normals on flat faces).
    corner_normals: []const Vec3,
    /// Active UV map, per corner, or empty.
    corner_uvs: []const [2]f32,
    /// Material slot per face, or empty for slot 0 everywhere.
    face_material: []const u16,
    /// Edge vertex pairs, for wireframe overlays and edge-based exporters.
    edges: []const [2]u32,

    pub fn faceCount(m: Mesh) usize {
        return if (m.face_offsets.len == 0) 0 else m.face_offsets.len - 1;
    }

    pub fn faceCorners(m: Mesh, f: usize) []const u32 {
        return m.corner_verts[m.face_offsets[f]..m.face_offsets[f + 1]];
    }

    pub fn triangleCount(m: Mesh) usize {
        var n: usize = 0;
        for (0..m.faceCount()) |f| {
            const c = m.face_offsets[f + 1] - m.face_offsets[f];
            if (c >= 3) n += c - 2;
        }
        return n;
    }
};

pub const AlphaMode = enum { opaque_, blend };

pub const Material = struct {
    name: []const u8,
    base_color: Vec4,
    metallic: f32,
    roughness: f32,
    ior: f32,
    transmission: f32,
    emission_color: Vec3,
    emission_strength: f32,
    alpha: f32,
    double_sided: bool,
};

pub const Projection = enum { perspective, orthographic };
pub const SensorFit = enum { auto, horizontal, vertical };

pub const Camera = struct {
    name: []const u8,
    projection: Projection,
    lens_mm: f32,
    sensor_width_mm: f32,
    sensor_height_mm: f32,
    sensor_fit: SensorFit,
    ortho_scale: f32,
    clip_start: f32,
    clip_end: f32,
    shift: [2]f32,

    pub const Fov = struct {
        /// Full field of view in radians (perspective only).
        x: f32,
        y: f32,
        /// Half extents of the view volume (orthographic only).
        half_w: f32,
        half_h: f32,
    };

    /// Field of view for an image of the given width / height, following
    /// Blender's sensor-fit rules.
    pub fn fov(c: Camera, aspect: f32) Fov {
        const horizontal = switch (c.sensor_fit) {
            .auto => aspect >= 1,
            .horizontal => true,
            .vertical => false,
        };
        const sensor = if (c.sensor_fit == .vertical) c.sensor_height_mm else c.sensor_width_mm;
        const fit_angle = 2 * std.math.atan(sensor / (2 * c.lens_mm));
        const half_fit = c.ortho_scale / 2;
        if (horizontal) {
            return .{
                .x = fit_angle,
                .y = 2 * std.math.atan(@tan(fit_angle / 2) / aspect),
                .half_w = half_fit,
                .half_h = half_fit / aspect,
            };
        }
        return .{
            .x = 2 * std.math.atan(@tan(fit_angle / 2) * aspect),
            .y = fit_angle,
            .half_w = half_fit * aspect,
            .half_h = half_fit,
        };
    }
};

pub const LightKind = enum { point, sun, spot, area };

pub const Light = struct {
    name: []const u8,
    kind: LightKind,
    color: Vec3,
    /// Radiant power in watts for point, spot and area; irradiance in W/m²
    /// for sun (Blender's "strength").
    power: f32,
    radius: f32,
    /// Full cone angle in radians (spot only).
    spot_size: f32,
    spot_blend: f32,
    area_size: [2]f32,
};

pub const World = struct {
    color: Vec3,
    strength: f32,
};

test "camera fov follows sensor fit" {
    const cam: Camera = .{
        .name = "c",
        .projection = .perspective,
        .lens_mm = 50,
        .sensor_width_mm = 36,
        .sensor_height_mm = 24,
        .sensor_fit = .auto,
        .ortho_scale = 6,
        .clip_start = 0.1,
        .clip_end = 100,
        .shift = .{ 0, 0 },
    };
    const wide = cam.fov(16.0 / 9.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6911), wide.x, 1e-3); // 39.6°
    try std.testing.expect(wide.y < wide.x);
    const tall = cam.fov(0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6911), tall.y, 1e-3);
}
