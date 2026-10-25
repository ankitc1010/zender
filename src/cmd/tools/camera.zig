//! camera.* and light.add.

const std = @import("std");
const math = @import("math");
const engine = @import("engine");
const server = @import("../server.zig");
const common = @import("common.zig");

const core = engine.core;
const Call = server.Call;
const Tool = server.Tool;
const HandlerError = server.HandlerError;
const v = math.vec;

fn writeCameraSchema(w: *std.json.Stringify) std.json.Stringify.Error!void {
    try core.registry.writeSchema(core.types.Camera, w);
}
fn writeLightSchema(w: *std.json.Stringify) std.json.Stringify.Error!void {
    try core.registry.writeSchema(core.types.Light, w);
}

pub const tools = [_]Tool{
    .{
        .name = "camera.add",
        .title = "Add camera",
        .description = "Add a camera (50 mm lens, 36 mm sensor by default) and, by default, make it the active camera. Cameras look along their local -Z; pass look_at to aim. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"location\":[6,-6,4],\"look_at\":[0,0,0.5],\"lens\":35}.",
        .params = common.mutating(&.{
            common.name,
            common.location,
            common.rotation,
            common.look_at,
            .{ .name = "lens", .type = .{ .number = .{ .min = 1, .max = 5000, .unit = .millimetres } }, .doc = "Focal length", .default = .{ .number = 50 } },
            .{ .name = "set_active", .type = .boolean, .doc = "Make it the scene camera", .default = .{ .boolean = true } },
            .{ .name = "properties", .type = .{ .properties = writeCameraSchema }, .doc = "Other camera properties" },
        }),
        .kind = .mutating,
        .handler = cameraAdd,
    },
    .{
        .name = "camera.look_at",
        .title = "Aim camera",
        .description = "Rotate a camera (default: the active one), or any object, so its -Z axis points at a point or at an object's bounds centre, keeping Z up. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"target_object\":\"Table Top\"}.",
        .params = common.mutating(&.{
            .{ .name = "camera", .type = .{ .name_ref = .{} }, .doc = "Object to rotate; default the active camera" },
            .{ .name = "target", .type = .{ .vec3 = .{ .min = -1e9, .max = 1e9, .unit = .metres } }, .doc = "World point to aim at" },
            .{ .name = "target_object", .type = .{ .name_ref = .{} }, .doc = "Object whose bounds centre to aim at" },
        }),
        .kind = .mutating,
        .handler = lookAt,
    },
    .{
        .name = "camera.frame_objects",
        .title = "Frame objects",
        .description = "Move a camera (default: the active one; one is created if none) back along its view direction until the objects fit the frame. Without objects, frames every visible mesh. Optionally set the view direction first. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"objects\":[\"Table Top\"],\"margin\":1.2}.",
        .params = common.mutating(&.{
            .{ .name = "camera", .type = .{ .name_ref = .{} }, .doc = "Camera object; default the active camera" },
            .{ .name = "objects", .type = .{ .string_list = .{} }, .doc = "Objects to fit; default all visible meshes" },
            .{ .name = "direction", .type = .{ .vec3 = .{ .min = -1e6, .max = 1e6 } }, .doc = "View direction to use, e.g. [-1, 1, -0.6] looks from front-right above; default keep the camera's" },
            .{ .name = "margin", .type = .{ .number = .{ .min = 1, .max = 10 } }, .doc = "Padding factor; 1 = tight", .default = .{ .number = 1.1 } },
        }),
        .kind = .mutating,
        .handler = frameObjects,
    },
    .{
        .name = "light.add",
        .title = "Add light",
        .description = "Add a light: point, sun, spot or area. energy is watts (point, spot, area; Blender's default lamp is 1000 W) or W/m^2 for sun (3-10 is daylight). Lights shine along local -Z; pass look_at to aim. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"type\":\"area\",\"location\":[2,-2,3],\"look_at\":[0,0,0],\"energy\":500,\"properties\":{\"size\":2}}.",
        .params = common.mutating(&.{
            .{ .name = "type", .type = .{ .enumeration = &.{ "point", "sun", "spot", "area" } }, .doc = "Light type", .default = .{ .string = "point" } },
            common.name,
            common.location,
            common.rotation,
            common.look_at,
            .{ .name = "energy", .type = .{ .number = .{ .min = 0, .max = 1e12, .unit = .watts } }, .doc = "Power; default 1000 W, or 3 W/m^2 for sun" },
            .{ .name = "color", .type = .color, .doc = "Colour [r, g, b], scene-linear" },
            .{ .name = "properties", .type = .{ .properties = writeLightSchema }, .doc = "Other light properties" },
        }),
        .kind = .mutating,
        .handler = lightAdd,
    },
};

fn cameraAdd(c: *Call) HandlerError!void {
    const doc = c.doc();
    var cam: core.types.Camera = .{ .lens = c.args.float("lens").? };
    if (c.args.value("properties")) |p| _ = try common.setProperties(c, core.types.Camera, &cam, p, "properties");
    if (cam.clip_end <= cam.clip_start) return c.failAt(.invalid_argument, "/properties/clip_end", "", &.{}, "clip_end must be greater than clip_start", .{});
    const name = c.args.str("name") orelse "Camera";
    const ch = try doc.db.create(.camera, name, cam);
    const oh = core.edit.addObject(doc, name, .camera, ch) catch return error.OutOfMemory;
    const ob = doc.db.get(.object, oh).?;
    common.applyPlacement(c, ob);
    if (c.args.boolean("set_active").?) doc.sceneData().camera = oh;
    try c.markCreated(oh, ob.name.slice());
    try c.markCreated(ch, doc.db.get(.camera, ch).?.name.slice());
    try c.field("object");
    try common.writeObjectSummary(c, &c.out, oh);
    try c.say("Added camera '{s}' ({d} mm){s}.", .{ ob.name.slice(), cam.lens, if (c.args.boolean("set_active").?) ", now active" else "" });
}

fn activeOr(c: *Call, arg: []const u8) HandlerError!core.IdHandle {
    if (c.args.str(arg)) |n| return c.lookup(.object, n, try std.fmt.allocPrint(c.arena, "/{s}", .{arg}));
    return c.doc().sceneData().camera orelse c.failAt(.not_found, try std.fmt.allocPrint(c.arena, "/{s}", .{arg}), "add one with camera.add or name an object", &.{}, "the scene has no active camera", .{});
}

fn lookAt(c: *Call) HandlerError!void {
    const doc = c.doc();
    const h = try activeOr(c, "camera");
    const target: [3]f32 = if (c.args.vec3("target")) |t| t else if (c.args.str("target_object")) |name| blk: {
        const th = try c.lookup(.object, name, "/target_object");
        const b = (try engine.eval.flatten.objectBounds(doc, th)).?;
        break :blk v.scale(v.add(b[0], b[1]), 0.5);
    } else return c.failAt(.invalid_argument, "/target", "pass target [x, y, z] or target_object", &.{}, "nothing to aim at", .{});
    const ob = doc.db.get(.object, h).?;
    if (ob.parent != null) try c.warn("'{s}' has a parent; the aim is computed in its parent's space", .{ob.name.slice()});
    common.aimAt(ob, target);
    try c.markChanged(h, ob.name.slice());
    try c.field("object");
    try common.writeObjectSummary(c, &c.out, h);
    try c.say("Aimed '{s}' at [{d:.3}, {d:.3}, {d:.3}].", .{ ob.name.slice(), target[0], target[1], target[2] });
}

fn frameObjects(c: *Call) HandlerError!void {
    const doc = c.doc();
    const scene = doc.sceneData();
    var created = false;
    const cam_h: core.IdHandle = if (c.args.str("camera")) |n| try c.lookup(.object, n, "/camera") else if (scene.camera) |h| h else blk: {
        const ch = try doc.db.create(.camera, "Camera", .{});
        const oh = core.edit.addObject(doc, "Camera", .camera, ch) catch return error.OutOfMemory;
        const ob = doc.db.get(.object, oh).?;
        ob.location = .{ 7.358891, -6.925791, 4.958309 };
        ob.rotation_euler = common.degVec(.{ 63.559, 0, 46.692 });
        doc.sceneData().camera = oh;
        try c.markCreated(oh, ob.name.slice());
        try c.markCreated(ch, doc.db.get(.camera, ch).?.name.slice());
        created = true;
        break :blk oh;
    };
    const ob = doc.db.get(.object, cam_h).?;
    if (ob.kind != .camera) return c.failAt(.invalid_argument, "/camera", "", &.{}, "'{s}' is not a camera", .{ob.name.slice()});
    const cam = doc.db.get(.camera, ob.data.?).?.*;

    // Bounds of the requested objects (or all visible meshes).
    var lo: [3]f32 = .{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
    var hi: [3]f32 = .{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
    const names = c.args.strings("objects");
    var targets: std.ArrayList(core.IdHandle) = .empty;
    if (names.len > 0) {
        for (names, 0..) |n, i| try targets.append(c.arena, try c.lookup(.object, n.string, try std.fmt.allocPrint(c.arena, "/objects/{d}", .{i})));
    } else {
        for (try core.edit.sceneVisibility(doc, c.arena)) |x| {
            const o = doc.db.get(.object, x.handle).?;
            if (o.kind == .mesh and !o.hide_render and x.render) try targets.append(c.arena, x.handle);
        }
    }
    for (targets.items) |h| if (try engine.eval.flatten.objectBounds(doc, h)) |b| {
        lo = v.min3(lo, b[0]);
        hi = v.max3(hi, b[1]);
    };
    if (!(lo[0] <= hi[0])) return c.failAt(.invalid_argument, "/objects", "add geometry first", &.{}, "nothing to frame", .{});

    if (c.args.vec3("direction")) |d| {
        if (v.length(d) < 1e-9) return c.failAt(.invalid_argument, "/direction", "", &.{}, "direction must not be zero", .{});
        ob.rotation_quaternion = v.lookRotation(d, .{ 0, 0, 1 });
        if (ob.rotation_mode != .quaternion) {
            ob.rotation_mode = .xyz;
            ob.rotation_euler = v.quatToEulerXyz(ob.rotation_quaternion);
        }
    }
    const world = try core.edit.worldMatrix(&doc.db, cam_h);
    const fwd = v.normalize(v.transformDir(world, .{ 0, 0, -1 }));
    const up = v.normalize(v.transformDir(world, .{ 0, 1, 0 }));
    const right = v.normalize(v.cross(fwd, up));
    const center = v.scale(v.add(lo, hi), 0.5);

    const scene_now = doc.sceneData();
    const aspect = @as(f32, @floatFromInt(scene_now.resolution_x)) / @as(f32, @floatFromInt(scene_now.resolution_y));
    const ir_cam: engine.eval.flatten.CameraFov = engine.eval.flatten.cameraFov(cam, aspect);
    const margin = c.args.float("margin").?;

    // Fit every bounds corner: distance so its offset fits the half-FOV in
    // both directions.
    var dist: f32 = 0;
    var ortho_half: f32 = 0;
    for (0..8) |k| {
        const p: [3]f32 = .{ if (k & 1 != 0) hi[0] else lo[0], if (k & 2 != 0) hi[1] else lo[1], if (k & 4 != 0) hi[2] else lo[2] };
        const d = v.sub(p, center);
        const x = @abs(v.dot(d, right)) * margin;
        const y = @abs(v.dot(d, up)) * margin;
        const z = v.dot(d, fwd);
        dist = @max(dist, x / @tan(ir_cam.x / 2) - z);
        dist = @max(dist, y / @tan(ir_cam.y / 2) - z);
        ortho_half = @max(ortho_half, @max(x, y * aspect));
    }
    const radius = v.length(v.sub(hi, lo)) / 2;
    dist = @max(dist, cam.clip_start + radius);
    const eye = v.sub(center, v.scale(fwd, dist));
    // Write back in parent space.
    var new_world = world;
    new_world[12] = eye[0];
    new_world[13] = eye[1];
    new_world[14] = eye[2];
    if (ob.parent) |p| {
        const pw = try core.edit.worldMatrix(&doc.db, p);
        const local = v.matMul(v.invert(v.matMul(pw, ob.parent_inverse)) orelse v.identity, new_world);
        ob.location = v.translation(local);
    } else ob.location = eye;
    if (cam.type == .orthographic) {
        doc.db.get(.camera, ob.data.?).?.ortho_scale = 2 * ortho_half;
    }
    if (dist + radius > cam.clip_end) {
        doc.db.get(.camera, ob.data.?).?.clip_end = (dist + radius) * 1.5;
        try c.warn("raised clip_end to {d:.1} m so the objects are not clipped", .{(dist + radius) * 1.5});
    }
    if (!created) try c.markChanged(cam_h, ob.name.slice());
    try c.field("object");
    try common.writeObjectSummary(c, &c.out, cam_h);
    try c.field("distance");
    try core.registry.writeF32(&c.out, dist);
    try c.say("Framed {d} object(s) with '{s}' from {d:.2} m.", .{ targets.items.len, ob.name.slice(), dist });
}

fn lightAdd(c: *Call) HandlerError!void {
    const doc = c.doc();
    const kind = std.meta.stringToEnum(core.types.LightType, c.args.str("type").?).?;
    var light: core.types.Light = .{ .type = kind, .energy = if (kind == .sun) 3 else 1000, .radius = 0.1 };
    if (c.args.float("energy")) |e| light.energy = e;
    if (c.args.color("color")) |col| light.color = .{ col[0], col[1], col[2] };
    if (c.args.value("properties")) |p| _ = try common.setProperties(c, core.types.Light, &light, p, "properties");
    const default_name: []const u8 = switch (kind) {
        .point => "Point",
        .sun => "Sun",
        .spot => "Spot",
        .area => "Area",
    };
    const name = c.args.str("name") orelse default_name;
    const lh = try doc.db.create(.light, name, light);
    const oh = core.edit.addObject(doc, name, .light, lh) catch return error.OutOfMemory;
    const ob = doc.db.get(.object, oh).?;
    common.applyPlacement(c, ob);
    try c.markCreated(oh, ob.name.slice());
    try c.markCreated(lh, doc.db.get(.light, lh).?.name.slice());
    try c.field("object");
    try common.writeObjectSummary(c, &c.out, oh);
    try c.say("Added {s} light '{s}' ({d} {s}).", .{ @tagName(kind), ob.name.slice(), light.energy, if (kind == .sun) "W/m^2" else "W" });
}
