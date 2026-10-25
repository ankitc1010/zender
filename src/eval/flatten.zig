//! Evaluation to the interchange representation: world transforms, evaluated
//! meshes with normals, and resolved material, camera and light data.
//!
//! P0 evaluates everything on each call; P1's depsgraph adds per-ID dirty
//! flags and an evaluated-mesh cache keyed by input hash (TRD §7).

const std = @import("std");
const math = @import("math");
const ir = @import("ir");
const core = @import("../core/root.zig");
const geom = @import("../geom/root.zig");

const Allocator = std.mem.Allocator;
const IdHandle = core.IdHandle;
const Document = core.Document;
const types = core.types;
const v = math.vec;

const Maps = struct {
    mesh: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    camera: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    light: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    material: std.AutoHashMapUnmanaged(u32, u32) = .empty,
};

pub const Error = Allocator.Error || math.DeadlineError;

pub const Context = struct {
    pool: math.Pool,
    /// Evaluated data kept between calls; null evaluates from scratch.
    cache: ?*Cache = null,
};

const Cache = @import("cache.zig").Cache;

/// Builds an `ir.Scene` in `arena`. Every object in the scene becomes a node,
/// parents before children; hidden objects keep their hide flags set, taking
/// collection visibility into account.
/// With a cache, evaluated data is reused and the cache keeps only what this
/// scene uses.
pub fn flatten(arena: Allocator, doc: *Document, ctx: Context) Error!ir.Scene {
    if (ctx.cache) |c| c.begin();
    defer if (ctx.cache) |c| c.sweep();
    const db = &doc.db;
    const scene = doc.sceneData();
    const vis = try core.edit.sceneVisibility(doc, arena);
    const objects = try arena.alloc(IdHandle, vis.len);
    var vis_of: std.AutoHashMapUnmanaged(u32, core.edit.Visibility) = .empty;
    for (vis, objects) |x, *h| {
        h.* = x.handle;
        try vis_of.put(arena, x.handle.index, x);
    }

    // Parents first: depth-first from roots, children in object order.
    var order: std.ArrayList(IdHandle) = .empty;
    var node_of: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    var in_scene: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (objects) |h| try in_scene.put(arena, h.index, {});
    for (objects) |h| {
        const ob = db.get(.object, h).?;
        const root = if (ob.parent) |p| !in_scene.contains(p.index) else true;
        if (root) try visit(arena, db, objects, h, &order, &node_of, 0);
    }

    var maps: Maps = .{};
    var meshes: std.ArrayList(ir.Mesh) = .empty;
    var cameras: std.ArrayList(ir.Camera) = .empty;
    var lights: std.ArrayList(ir.Light) = .empty;
    var materials: std.ArrayList(ir.Material) = .empty;
    const nodes = try arena.alloc(ir.Node, order.items.len);

    for (order.items, 0..) |h, i| {
        const ob = db.get(.object, h).?;
        const parent: ?u32 = if (ob.parent) |p| node_of.get(p.index) else null;
        const local = ob.localMatrix();
        const world = if (parent) |p| v.matMul(nodes[p].world, local) else blk: {
            // A parent outside the scene still contributes its transform.
            break :blk try core.edit.worldMatrix(db, h);
        };
        var kind: ir.NodeKind = .empty;
        var slots: []?u32 = &.{};
        if (ob.data) |d| switch (ob.kind) {
            .mesh => if (db.get(.mesh, d)) |m| {
                kind = .{ .mesh = try meshIndex(arena, ctx, &maps, &meshes, d, m) };
                const mats = m.materials.slice();
                slots = try arena.alloc(?u32, mats.len);
                for (mats, 0..) |mh, s| {
                    slots[s] = if (mh) |x| if (db.get(.material, x)) |mat| try materialIndex(arena, &maps, &materials, x, mat) else null else null;
                }
            },
            .camera => if (db.get(.camera, d)) |c| {
                kind = .{ .camera = try cameraIndex(arena, &maps, &cameras, d, c) };
            },
            .light => if (db.get(.light, d)) |l| {
                kind = .{ .light = try lightIndex(arena, &maps, &lights, d, l) };
            },
            .empty => {},
        };
        nodes[i] = .{
            .name = try arena.dupe(u8, ob.name.slice()),
            .parent = parent,
            .local = if (parent != null) local else world,
            .world = world,
            .kind = kind,
            .materials = slots,
            .hide_render = ob.hide_render or !vis_of.get(h.index).?.render,
            .hide_viewport = ob.hide_viewport or !vis_of.get(h.index).?.viewport,
        };
    }

    const world_data: ir.World = if (scene.world) |wh| if (db.get(.world, wh)) |w| .{ .color = w.color, .strength = w.strength } else default_world else default_world;
    const pct = scene.resolution_percentage;
    return .{
        .name = try arena.dupe(u8, scene.name.slice()),
        .nodes = nodes,
        .meshes = meshes.items,
        .materials = materials.items,
        .cameras = cameras.items,
        .lights = lights.items,
        .world = world_data,
        .active_camera = if (scene.camera) |c| node_of.get(c.index) else null,
        .resolution = .{ @max(1, scene.resolution_x * pct / 100), @max(1, scene.resolution_y * pct / 100) },
        .fps = scene.fps,
        .frame_start = scene.frame_start,
        .frame_end = scene.frame_end,
    };
}

const default_world: ir.World = .{ .color = .{ 0.050876088, 0.050876088, 0.050876088 }, .strength = 1 };

fn visit(
    arena: Allocator,
    db: *core.Database,
    objects: []const IdHandle,
    h: IdHandle,
    order: *std.ArrayList(IdHandle),
    node_of: *std.AutoHashMapUnmanaged(u32, u32),
    depth: u32,
) Allocator.Error!void {
    if (depth > 1024 or node_of.contains(h.index)) return;
    try node_of.put(arena, h.index, @intCast(order.items.len));
    try order.append(arena, h);
    for (objects) |c| {
        const ob = db.get(.object, c).?;
        if (ob.parent) |p| if (p.eql(h)) try visit(arena, db, objects, c, order, node_of, depth + 1);
    }
}

fn meshIndex(arena: Allocator, ctx: Context, maps: *Maps, list: *std.ArrayList(ir.Mesh), h: IdHandle, m: *const types.Mesh) Error!u32 {
    const gop = try maps.mesh.getOrPut(arena, h.index);
    if (gop.found_existing) return gop.value_ptr.*;
    gop.value_ptr.* = @intCast(list.items.len);
    try list.append(arena, try evaluateMesh(arena, ctx, m));
    return gop.value_ptr.*;
}

/// The evaluated mesh: base mesh plus normals (modifier stack in P1).
pub fn evaluateMesh(arena: Allocator, ctx: Context, m: *const types.Mesh) Error!ir.Mesh {
    const uvs: []const [2]f32 = if (m.attribute(types.Mesh.uv_name)) |a| switch (a.data) {
        .float2 => |s| if (a.domain == .corner) s.slice() else &.{},
        else => &.{},
    } else &.{};
    var face_mat: []u16 = &.{};
    if (m.attribute("material_index")) |a| if (a.domain == .face) switch (a.data) {
        .int => |s| {
            face_mat = try arena.alloc(u16, s.len());
            for (s.slice(), face_mat) |x, *o| o.* = @intCast(std.math.clamp(x, 0, 32767));
        },
        else => {},
    };
    return .{
        .name = try arena.dupe(u8, m.name.slice()),
        .positions = m.positions.slice(),
        .face_offsets = m.face_offsets.slice(),
        .corner_verts = m.corner_verts.slice(),
        .corner_normals = if (ctx.cache) |c| try c.cornerNormals(m, ctx.pool) else try geom.normals.cornerNormals(arena, m, ctx.pool),
        .corner_uvs = uvs,
        .face_material = face_mat,
        .edges = m.edges.slice(),
    };
}

fn materialIndex(arena: Allocator, maps: *Maps, list: *std.ArrayList(ir.Material), h: IdHandle, m: *const types.Material) Allocator.Error!u32 {
    const gop = try maps.material.getOrPut(arena, h.index);
    if (gop.found_existing) return gop.value_ptr.*;
    gop.value_ptr.* = @intCast(list.items.len);
    try list.append(arena, .{
        .name = try arena.dupe(u8, m.name.slice()),
        .base_color = m.base_color,
        .metallic = m.metallic,
        .roughness = m.roughness,
        .ior = m.ior,
        .transmission = m.transmission,
        .emission_color = m.emission_color,
        .emission_strength = m.emission_strength,
        .alpha = m.alpha,
        .double_sided = !m.use_backface_culling,
    });
    return gop.value_ptr.*;
}

fn cameraIndex(arena: Allocator, maps: *Maps, list: *std.ArrayList(ir.Camera), h: IdHandle, c: *const types.Camera) Allocator.Error!u32 {
    const gop = try maps.camera.getOrPut(arena, h.index);
    if (gop.found_existing) return gop.value_ptr.*;
    gop.value_ptr.* = @intCast(list.items.len);
    try list.append(arena, toIrCamera(try arena.dupe(u8, c.name.slice()), c));
    return gop.value_ptr.*;
}

pub fn toIrCamera(name: []const u8, c: *const types.Camera) ir.Camera {
    return .{
        .name = name,
        .projection = switch (c.type) {
            .perspective => .perspective,
            .orthographic => .orthographic,
        },
        .lens_mm = c.lens,
        .sensor_width_mm = c.sensor_width,
        .sensor_height_mm = c.sensor_height,
        .sensor_fit = switch (c.sensor_fit) {
            .auto => .auto,
            .horizontal => .horizontal,
            .vertical => .vertical,
        },
        .ortho_scale = c.ortho_scale,
        .clip_start = c.clip_start,
        .clip_end = c.clip_end,
        .shift = c.shift,
    };
}

pub const CameraFov = ir.Camera.Fov;

/// Field of view of a camera for an image of the given width / height.
pub fn cameraFov(c: types.Camera, aspect: f32) CameraFov {
    return toIrCamera("", &c).fov(aspect);
}

fn lightIndex(arena: Allocator, maps: *Maps, list: *std.ArrayList(ir.Light), h: IdHandle, l: *const types.Light) Allocator.Error!u32 {
    const gop = try maps.light.getOrPut(arena, h.index);
    if (gop.found_existing) return gop.value_ptr.*;
    gop.value_ptr.* = @intCast(list.items.len);
    try list.append(arena, .{
        .name = try arena.dupe(u8, l.name.slice()),
        .kind = switch (l.type) {
            .point => .point,
            .sun => .sun,
            .spot => .spot,
            .area => .area,
        },
        .color = l.color,
        .power = l.energy,
        .radius = l.radius,
        .spot_size = l.spot_size,
        .spot_blend = l.spot_blend,
        .area_size = .{ l.size, l.size_y },
    });
    return gop.value_ptr.*;
}

/// World-space bounds of one object's evaluated geometry; an object without
/// geometry contributes its origin.
pub fn objectBounds(doc: *Document, h: IdHandle) Allocator.Error!?[2]math.Vec3 {
    const ob = doc.db.get(.object, h) orelse return null;
    const world = try core.edit.worldMatrix(&doc.db, h);
    if (ob.kind == .mesh) if (ob.data) |d| if (doc.db.get(.mesh, d)) |m| {
        const pos = m.positions.slice();
        if (pos.len == 0) return null;
        var lo = v.transformPoint(world, pos[0]);
        var hi = lo;
        for (pos[1..]) |p| {
            const w = v.transformPoint(world, p);
            lo = v.min3(lo, w);
            hi = v.max3(hi, w);
        }
        return .{ lo, hi };
    };
    const o = v.translation(world);
    return .{ o, o };
}

test "flatten orders parents first and shares mesh data" {
    const gpa = std.testing.allocator;
    var doc = try Document.initEmpty(gpa, "Scene");
    defer doc.deinit();
    const mesh = try doc.db.create(.mesh, "Cube", try geom.primitives.generate(gpa, .cube, .{}));
    const child = try core.edit.addObject(&doc, "Child", .mesh, mesh);
    const parent = try core.edit.addObject(&doc, "Parent", .mesh, mesh);
    doc.db.get(.object, parent).?.location = .{ 0, 0, 2 };
    try core.edit.setParent(&doc, child, parent, false);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const s = try flatten(arena_state.allocator(), &doc, .{ .pool = math.Pool.single(std.testing.io) });
    try std.testing.expectEqual(@as(usize, 2), s.nodes.len);
    try std.testing.expectEqualStrings("Parent", s.nodes[0].name);
    try std.testing.expectEqual(@as(?u32, 0), s.nodes[1].parent);
    try std.testing.expectEqual(@as(usize, 1), s.meshes.len);
    try std.testing.expectEqual(@as(f32, 2), s.nodes[1].world[14]);
    try std.testing.expectEqual(@as(usize, 24), s.meshes[0].corner_normals.len);
}
