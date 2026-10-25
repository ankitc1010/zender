//! Datablock structs (TRD §6). Each is a plain value: inline name, fixed-size
//! fields and copy-on-write arrays, so a database snapshot is a flat copy
//! plus reference-count bumps. Field defaults are Blender's DNA defaults and
//! double as the registry defaults.

const std = @import("std");
const math = @import("math");
const ids = @import("ids.zig");
const registry = @import("registry.zig");
const shared = @import("shared.zig");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const Quat = math.Quat;
const Mat4 = math.Mat4;
const Prop = registry.Prop;
const Name = ids.Name;
const IdHandle = ids.IdHandle;
const Shared = shared.Shared;

pub const Scene = struct {
    name: Name = .{},
    /// Active camera object.
    camera: ?IdHandle = null,
    world: ?IdHandle = null,
    /// Master collection; every object in the scene is reachable from it.
    collection: ?IdHandle = null,
    frame_start: i32 = 1,
    frame_end: i32 = 250,
    frame_current: i32 = 1,
    fps: f32 = 24,
    resolution_x: u32 = 1920,
    resolution_y: u32 = 1080,
    resolution_percentage: u32 = 100,
    unit_scale: f32 = 1,

    pub const props = [_]Prop{
        .{ .name = "frame_start", .field = "frame_start", .kind = .int, .unit = .frames, .min = 0, .max = 1048574, .doc = "First frame of the animation range", .blend = "r.sfra" },
        .{ .name = "frame_end", .field = "frame_end", .kind = .int, .unit = .frames, .min = 0, .max = 1048574, .doc = "Last frame of the animation range", .blend = "r.efra" },
        .{ .name = "frame_current", .field = "frame_current", .kind = .int, .unit = .frames, .min = -1048574, .max = 1048574, .doc = "Current frame", .blend = "r.cfra" },
        .{ .name = "fps", .field = "fps", .kind = .float, .unit = .per_second, .min = 1, .max = 32767, .doc = "Frames per second", .blend = "r.frs_sec" },
        .{ .name = "resolution_x", .field = "resolution_x", .kind = .int, .unit = .pixels, .min = 4, .max = 65536, .doc = "Render width", .blend = "r.xsch" },
        .{ .name = "resolution_y", .field = "resolution_y", .kind = .int, .unit = .pixels, .min = 4, .max = 65536, .doc = "Render height", .blend = "r.ysch" },
        .{ .name = "resolution_percentage", .field = "resolution_percentage", .kind = .int, .unit = .percent, .min = 1, .max = 32767, .doc = "Scale applied to the render resolution", .blend = "r.size" },
        .{ .name = "unit_scale", .field = "unit_scale", .kind = .float, .min = 1e-9, .max = 1e5, .doc = "Scene unit scale; 1 means 1 unit = 1 m", .blend = "unit.scale_length" },
    };

    pub fn retainRefs(_: *Scene) void {}
    pub fn releaseRefs(_: *Scene, _: Allocator) void {}
};

pub const Collection = struct {
    name: Name = .{},
    objects: Shared(IdHandle) = .empty,
    children: Shared(IdHandle) = .empty,
    hide_render: bool = false,
    hide_viewport: bool = false,

    pub const props = [_]Prop{
        .{ .name = "hide_render", .field = "hide_render", .kind = .bool, .doc = "Exclude the collection's objects and child collections from renders and exports", .blend = "flag" },
        .{ .name = "hide_viewport", .field = "hide_viewport", .kind = .bool, .doc = "Hide the collection's objects and child collections in previews", .blend = "flag" },
    };

    pub fn retainRefs(c: *Collection) void {
        _ = c.objects.retain();
        _ = c.children.retain();
    }
    pub fn releaseRefs(c: *Collection, gpa: Allocator) void {
        c.objects.release(gpa);
        c.children.release(gpa);
    }
};

pub const ObjectKind = enum { empty, mesh, camera, light };

/// Blender's rotation modes; Euler orders name the order axes are applied.
pub const RotationMode = enum { quaternion, xyz, xzy, yxz, yzx, zxy, zyx };

pub const Object = struct {
    name: Name = .{},
    kind: ObjectKind = .empty,
    data: ?IdHandle = null,
    parent: ?IdHandle = null,
    /// Captured when parenting with "keep transform", as Blender does.
    parent_inverse: Mat4 = math.vec.identity,
    location: Vec3 = .{ 0, 0, 0 },
    rotation_mode: RotationMode = .xyz,
    rotation_euler: Vec3 = .{ 0, 0, 0 },
    /// (x, y, z, w)
    rotation_quaternion: Quat = math.vec.quat_identity,
    scale: Vec3 = .{ 1, 1, 1 },
    hide_render: bool = false,
    hide_viewport: bool = false,

    pub const props = [_]Prop{
        .{ .name = "type", .field = "kind", .kind = .enumeration, .read_only = true, .doc = "Object type, set at creation", .blend = "type" },
        .{ .name = "location", .field = "location", .kind = .vec3, .unit = .length, .min = -1e9, .max = 1e9, .doc = "Origin position in parent space", .blend = "loc" },
        .{ .name = "rotation_mode", .field = "rotation_mode", .kind = .enumeration, .doc = "Which rotation field applies; xyz applies X, then Y, then Z", .blend = "rotmode" },
        .{ .name = "rotation_euler", .field = "rotation_euler", .kind = .vec3, .unit = .angle, .min = -1e6, .max = 1e6, .doc = "Euler rotation", .blend = "rot" },
        .{ .name = "rotation_quaternion", .field = "rotation_quaternion", .kind = .vec4, .read_only = true, .doc = "Quaternion rotation (x, y, z, w); set through object.transform", .blend = "quat" },
        .{ .name = "scale", .field = "scale", .kind = .vec3, .min = -1e6, .max = 1e6, .doc = "Scale factors per axis", .blend = "scale" },
        .{ .name = "hide_render", .field = "hide_render", .kind = .bool, .doc = "Exclude from renders and exports", .blend = "visibility_flag" },
        .{ .name = "hide_viewport", .field = "hide_viewport", .kind = .bool, .doc = "Hide in previews", .blend = "visibility_flag" },
    };

    pub fn rotation(o: *const Object) Quat {
        return switch (o.rotation_mode) {
            .quaternion => math.vec.quatNormalize(o.rotation_quaternion),
            inline else => |m| math.vec.eulerToQuat(o.rotation_euler, @field(math.vec.EulerOrder, @tagName(m))),
        };
    }

    /// Local matrix: parent_inverse · T · R · S.
    pub fn localMatrix(o: *const Object) Mat4 {
        return math.vec.matMul(o.parent_inverse, math.vec.compose(o.location, o.rotation(), o.scale));
    }

    pub fn retainRefs(_: *Object) void {}
    pub fn releaseRefs(_: *Object, _: Allocator) void {}
};

pub const Domain = enum { point, edge, face, corner };

pub const AttrData = union(enum) {
    float: Shared(f32),
    float2: Shared([2]f32),
    float3: Shared([3]f32),
    color: Shared([4]f32),
    int: Shared(i32),
    boolean: Shared(bool),

    pub fn len(d: AttrData) usize {
        return switch (d) {
            inline else => |s| s.len(),
        };
    }
    fn retain(d: AttrData) void {
        switch (d) {
            inline else => |s| _ = s.retain(),
        }
    }
    fn release(d: *AttrData, gpa: Allocator) void {
        switch (d.*) {
            inline else => |*s| s.release(gpa),
        }
    }
    pub fn byteSize(d: AttrData) usize {
        return switch (d) {
            inline else => |s| s.byteSize(),
        };
    }
    pub fn id(d: AttrData) usize {
        return switch (d) {
            inline else => |s| s.id(),
        };
    }
    pub fn serial(d: AttrData) u64 {
        return switch (d) {
            inline else => |s| s.serial(),
        };
    }
};

pub const Attribute = struct {
    name: Name,
    domain: Domain,
    data: AttrData,
};

/// Mesh storage, structure of arrays (FR-DM-3), following Blender 4.x's
/// layout: positions per point, vertex pairs per edge, face offsets into the
/// corner arrays, and named generic attributes per domain.
pub const Mesh = struct {
    name: Name = .{},
    positions: Shared(Vec3) = .empty,
    edges: Shared([2]u32) = .empty,
    /// Length faces + 1 when there are faces, else empty.
    face_offsets: Shared(u32) = .empty,
    corner_verts: Shared(u32) = .empty,
    corner_edges: Shared(u32) = .empty,
    attrs: [max_attrs]Attribute = undefined,
    attr_count: u8 = 0,
    /// Material per slot; objects use their data's slots.
    materials: Shared(?IdHandle) = .empty,

    pub const max_attrs = 16;
    pub const uv_name = "UVMap";

    pub const props = [_]Prop{};

    pub fn vertCount(m: *const Mesh) usize {
        return m.positions.len();
    }
    pub fn edgeCount(m: *const Mesh) usize {
        return m.edges.len();
    }
    pub fn faceCount(m: *const Mesh) usize {
        const n = m.face_offsets.len();
        return if (n == 0) 0 else n - 1;
    }
    pub fn cornerCount(m: *const Mesh) usize {
        return m.corner_verts.len();
    }
    pub fn triangleCount(m: *const Mesh) usize {
        const off = m.face_offsets.slice();
        var n: usize = 0;
        for (0..m.faceCount()) |f| {
            const c = off[f + 1] - off[f];
            if (c >= 3) n += c - 2;
        }
        return n;
    }

    pub fn attribute(m: *const Mesh, name: []const u8) ?*const Attribute {
        for (m.attrs[0..m.attr_count]) |*a| if (a.name.eql(name)) return a;
        return null;
    }

    /// Adds or replaces an attribute, taking ownership of `data`.
    pub fn setAttribute(m: *Mesh, gpa: Allocator, name: []const u8, domain: Domain, data: AttrData) error{TooManyAttributes}!void {
        for (m.attrs[0..m.attr_count]) |*a| {
            if (a.name.eql(name)) {
                a.data.release(gpa);
                a.* = .{ .name = .init(name), .domain = domain, .data = data };
                return;
            }
        }
        if (m.attr_count == max_attrs) {
            var d = data;
            d.release(gpa);
            return error.TooManyAttributes;
        }
        m.attrs[m.attr_count] = .{ .name = .init(name), .domain = domain, .data = data };
        m.attr_count += 1;
    }

    pub fn retainRefs(m: *Mesh) void {
        _ = m.positions.retain();
        _ = m.edges.retain();
        _ = m.face_offsets.retain();
        _ = m.corner_verts.retain();
        _ = m.corner_edges.retain();
        _ = m.materials.retain();
        for (m.attrs[0..m.attr_count]) |a| a.data.retain();
    }

    pub fn releaseRefs(m: *Mesh, gpa: Allocator) void {
        m.positions.release(gpa);
        m.edges.release(gpa);
        m.face_offsets.release(gpa);
        m.corner_verts.release(gpa);
        m.corner_edges.release(gpa);
        m.materials.release(gpa);
        for (m.attrs[0..m.attr_count]) |*a| a.data.release(gpa);
        m.attr_count = 0;
    }

    /// Calls `f(ctx, id, bytes)` for every array buffer, for memory accounting.
    pub fn eachBuffer(m: *const Mesh, ctx: anytype, comptime f: fn (@TypeOf(ctx), usize, usize) void) void {
        f(ctx, m.positions.id(), m.positions.byteSize());
        f(ctx, m.edges.id(), m.edges.byteSize());
        f(ctx, m.face_offsets.id(), m.face_offsets.byteSize());
        f(ctx, m.corner_verts.id(), m.corner_verts.byteSize());
        f(ctx, m.corner_edges.id(), m.corner_edges.byteSize());
        for (m.attrs[0..m.attr_count]) |a| f(ctx, a.data.id(), a.data.byteSize());
    }
};

pub const CameraType = enum { perspective, orthographic };
pub const SensorFit = enum { auto, horizontal, vertical };

pub const Camera = struct {
    name: Name = .{},
    type: CameraType = .perspective,
    lens: f32 = 50,
    sensor_width: f32 = 36,
    sensor_height: f32 = 24,
    sensor_fit: SensorFit = .auto,
    ortho_scale: f32 = 6,
    clip_start: f32 = 0.1,
    clip_end: f32 = 1000,
    shift: [2]f32 = .{ 0, 0 },

    pub const props = [_]Prop{
        .{ .name = "type", .field = "type", .kind = .enumeration, .doc = "Projection", .blend = "type" },
        .{ .name = "lens", .field = "lens", .kind = .float, .unit = .millimetre, .min = 1, .max = 5000, .doc = "Focal length", .blend = "lens" },
        .{ .name = "sensor_width", .field = "sensor_width", .kind = .float, .unit = .millimetre, .min = 1, .max = 1000, .doc = "Sensor width", .blend = "sensor_x" },
        .{ .name = "sensor_height", .field = "sensor_height", .kind = .float, .unit = .millimetre, .min = 1, .max = 1000, .doc = "Sensor height", .blend = "sensor_y" },
        .{ .name = "sensor_fit", .field = "sensor_fit", .kind = .enumeration, .doc = "Which sensor dimension maps to the image; auto uses the larger image side", .blend = "sensor_fit" },
        .{ .name = "ortho_scale", .field = "ortho_scale", .kind = .float, .unit = .length, .min = 1e-6, .max = 1e6, .doc = "Orthographic view width along the fitted side", .blend = "ortho_scale" },
        .{ .name = "clip_start", .field = "clip_start", .kind = .float, .unit = .length, .min = 1e-6, .max = 1e9, .doc = "Near clipping distance", .blend = "clip_start" },
        .{ .name = "clip_end", .field = "clip_end", .kind = .float, .unit = .length, .min = 1e-6, .max = 1e9, .doc = "Far clipping distance", .blend = "clip_end" },
        .{ .name = "shift", .field = "shift", .kind = .vec2, .min = -10, .max = 10, .doc = "Lens shift (x, y) as a fraction of the larger image side", .blend = "shiftx" },
    };

    pub fn retainRefs(_: *Camera) void {}
    pub fn releaseRefs(_: *Camera, _: Allocator) void {}
};

pub const LightType = enum { point, sun, spot, area };

pub const Light = struct {
    name: Name = .{},
    type: LightType = .point,
    color: Vec3 = .{ 1, 1, 1 },
    /// Watts for point, spot and area; W/m² for sun.
    energy: f32 = 10,
    /// Soft-shadow radius (Blender's shadow_soft_size).
    radius: f32 = 0.25,
    spot_size: f32 = std.math.pi / 4.0,
    spot_blend: f32 = 0.15,
    size: f32 = 0.25,
    size_y: f32 = 0.25,

    pub const props = [_]Prop{
        .{ .name = "type", .field = "type", .kind = .enumeration, .doc = "Light type", .blend = "type" },
        .{ .name = "color", .field = "color", .kind = .color3, .unit = .factor, .min = 0, .max = 1e6, .doc = "Light colour, scene-linear RGB", .blend = "r" },
        .{ .name = "energy", .field = "energy", .kind = .float, .min = 0, .max = 1e12, .doc = "Power in W (point, spot, area) or strength in W/m^2 (sun)", .blend = "energy" },
        .{ .name = "radius", .field = "radius", .kind = .float, .unit = .length, .min = 0, .max = 1e6, .doc = "Light size for soft shadows", .blend = "radius" },
        .{ .name = "spot_size", .field = "spot_size", .kind = .float, .unit = .angle, .min = 1, .max = 180, .doc = "Full spot cone angle", .blend = "spotsize" },
        .{ .name = "spot_blend", .field = "spot_blend", .kind = .float, .unit = .factor, .min = 0, .max = 1, .doc = "Softness of the spot edge", .blend = "spotblend" },
        .{ .name = "size", .field = "size", .kind = .float, .unit = .length, .min = 0, .max = 1e6, .doc = "Area light width", .blend = "area_size" },
        .{ .name = "size_y", .field = "size_y", .kind = .float, .unit = .length, .min = 0, .max = 1e6, .doc = "Area light height", .blend = "area_sizey" },
    };

    pub fn retainRefs(_: *Light) void {}
    pub fn releaseRefs(_: *Light, _: Allocator) void {}
};

/// Principled BSDF parameters (Blender 4.x node defaults).
pub const Material = struct {
    name: Name = .{},
    base_color: [4]f32 = .{ 0.8, 0.8, 0.8, 1 },
    metallic: f32 = 0,
    roughness: f32 = 0.5,
    ior: f32 = 1.5,
    alpha: f32 = 1,
    transmission: f32 = 0,
    emission_color: Vec3 = .{ 1, 1, 1 },
    emission_strength: f32 = 0,
    use_backface_culling: bool = false,

    pub const props = [_]Prop{
        .{ .name = "base_color", .field = "base_color", .kind = .color4, .unit = .factor, .min = 0, .max = 1, .doc = "Base colour, scene-linear RGBA" },
        .{ .name = "metallic", .field = "metallic", .kind = .float, .unit = .factor, .min = 0, .max = 1, .doc = "0 = dielectric, 1 = metal" },
        .{ .name = "roughness", .field = "roughness", .kind = .float, .unit = .factor, .min = 0, .max = 1, .doc = "Microfacet roughness" },
        .{ .name = "ior", .field = "ior", .kind = .float, .min = 1, .max = 4, .doc = "Index of refraction" },
        .{ .name = "alpha", .field = "alpha", .kind = .float, .unit = .factor, .min = 0, .max = 1, .doc = "Opacity" },
        .{ .name = "transmission", .field = "transmission", .kind = .float, .unit = .factor, .min = 0, .max = 1, .doc = "Transmission weight (glass)" },
        .{ .name = "emission_color", .field = "emission_color", .kind = .color3, .unit = .factor, .min = 0, .max = 1, .doc = "Emission colour, scene-linear RGB" },
        .{ .name = "emission_strength", .field = "emission_strength", .kind = .float, .min = 0, .max = 1e6, .doc = "Emission strength; 0 = none" },
        .{ .name = "use_backface_culling", .field = "use_backface_culling", .kind = .bool, .doc = "Hide back faces (exports as single-sided)" },
    };

    pub fn retainRefs(_: *Material) void {}
    pub fn releaseRefs(_: *Material, _: Allocator) void {}
};

pub const World = struct {
    name: Name = .{},
    color: Vec3 = .{ 0.050876088, 0.050876088, 0.050876088 },
    strength: f32 = 1,

    pub const props = [_]Prop{
        .{ .name = "color", .field = "color", .kind = .color3, .unit = .factor, .min = 0, .max = 1e6, .doc = "Background colour, scene-linear RGB", .blend = "horr" },
        .{ .name = "strength", .field = "strength", .kind = .float, .min = 0, .max = 1e6, .doc = "Background strength" },
    };

    pub fn retainRefs(_: *World) void {}
    pub fn releaseRefs(_: *World, _: Allocator) void {}
};

/// Maps an ID type to its struct.
pub fn TypeOf(comptime t: ids.IdType) type {
    return switch (t) {
        .scene => Scene,
        .collection => Collection,
        .object => Object,
        .mesh => Mesh,
        .camera => Camera,
        .light => Light,
        .material => Material,
        .world => World,
        .image, .action => @compileError("not implemented before P2"),
    };
}

/// ID types the database stores today, in canonical order.
pub const stored_types = [_]ids.IdType{ .scene, .collection, .object, .mesh, .camera, .light, .material, .world };
