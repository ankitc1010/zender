//! scene.* tools: create, inspect, validate, undo, redo, apply, close.

const std = @import("std");
const math = @import("math");
const engine = @import("engine");
const server = @import("../server.zig");
const schema = @import("../schema.zig");
const common = @import("common.zig");

const core = engine.core;
const Call = server.Call;
const Tool = server.Tool;
const HandlerError = server.HandlerError;
const Param = schema.Param;
const v = math.vec;

pub const tools = [_]Tool{
    .{
        .name = "scene.create",
        .title = "Create scene",
        .description = "Open a new empty scene and return its scene_id, which every other scene tool takes. Units are metres, Z is up, angles are degrees. template 'default' adds Blender's startup cube, camera and light. Example: {\"name\":\"Kitchen\"} -> {\"scene_id\":\"scn_1a2b3c4d\",\"scene_rev\":0}.",
        .params = &.{
            .{ .name = "name", .type = .{ .string = .{ .max_len = 255 } }, .doc = "Scene name", .default = .{ .string = "Scene" } },
            .{ .name = "template", .type = .{ .enumeration = &.{ "empty", "default" } }, .doc = "empty, or default = cube + camera + light like Blender's startup file", .default = .{ .string = "empty" } },
            .{ .name = "seed", .type = .{ .integer = .{ .min = 0, .max = 4294967295 } }, .doc = "Seed for every random choice in this scene (deterministic replay)", .default = .{ .integer = 0 } },
        },
        .kind = .lifecycle,
        .handler = create,
    },
    .{
        .name = "scene.inspect",
        .title = "Inspect scene",
        .description = "Read the scene: settings, active camera, an outline of every object with type, location (m), rotation (deg), scale and world bounds, and the collection tree once there is more than the master; with 'object', that object's full properties and data. Read-only. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"object\":\"Cube\"}.",
        .params = common.reading(&.{
            .{ .name = "object", .type = .{ .name_ref = .{} }, .doc = "Object to describe in full; omit for the scene outline" },
        }),
        .kind = .read_only,
        .idempotent = true,
        .handler = inspect,
    },
    .{
        .name = "scene.validate",
        .title = "Validate scene",
        .description = "Check the scene for problems: broken mesh topology, missing or unused materials, no active camera, objects outside the camera view. Returns a list of issues; read-only. Example: {\"scene_id\":\"scn_1a2b3c4d\"}.",
        .params = common.reading(&.{}),
        .kind = .read_only,
        .idempotent = true,
        .handler = validate,
    },
    .{
        .name = "scene.undo",
        .title = "Undo",
        .description = "Undo the last change(s); each committed tool call (or scene.apply batch) is one step. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"steps\":1}.",
        .params = common.mutating(&.{
            .{ .name = "steps", .type = .{ .integer = .{ .min = 1, .max = 256 } }, .doc = "How many steps to undo", .default = .{ .integer = 1 } },
        }),
        .kind = .lifecycle,
        .handler = undo,
    },
    .{
        .name = "scene.redo",
        .title = "Redo",
        .description = "Redo steps undone by scene.undo, until a new change clears them. Example: {\"scene_id\":\"scn_1a2b3c4d\"}.",
        .params = common.mutating(&.{
            .{ .name = "steps", .type = .{ .integer = .{ .min = 1, .max = 256 } }, .doc = "How many steps to redo", .default = .{ .integer = 1 } },
        }),
        .kind = .lifecycle,
        .handler = redo,
    },
    .{
        .name = "scene.apply",
        .title = "Apply ops atomically",
        .description = "Run up to 256 mutating tool calls as one all-or-nothing transaction and one undo step; if any op fails nothing changes and the error names the op. Each op is {tool, arguments} without scene_id. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"ops\":[{\"tool\":\"object.add_primitive\",\"arguments\":{\"kind\":\"cube\",\"name\":\"Leg\",\"size\":0.1}},{\"tool\":\"object.transform\",\"arguments\":{\"object\":\"Leg\",\"location\":[0.5,0.5,0.4]}}]}.",
        .params = common.mutating(&.{
            .{ .name = "ops", .type = .ops, .doc = "Ops to run in order: [{\"tool\": name, \"arguments\": {...}}]", .required = true },
        }),
        .kind = .mutating,
        .handler = apply,
    },
    .{
        .name = "scene.close",
        .title = "Close scene",
        .description = "Close a scene and free its memory; unsaved changes are lost, so a scene with changes needs confirm: true. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"confirm\":true}.",
        .params = common.reading(&.{
            .{ .name = "confirm", .type = .boolean, .doc = "Required when the scene has unsaved changes", .default = .{ .boolean = false } },
        }),
        .kind = .lifecycle,
        .destructive = true,
        .handler = close,
    },
};

fn create(c: *Call) HandlerError!void {
    const s = c.server;
    const gpa = s.gpa;
    const name = c.args.str("name").?;
    var doc = try core.Document.initEmpty(gpa, name);
    var doc_owned = true;
    defer if (doc_owned) doc.deinit();
    const seed: u64 = @intCast(c.args.int("seed").?);
    if (std.mem.eql(u8, c.args.str("template").?, "default")) {
        try addDefaultObjects(&doc);
    }
    const e = try s.addScene(doc, seed);
    doc_owned = false;
    c.entry = e;
    var it = e.doc.db.object.iterator();
    while (it.next()) |o| try c.markCreated(o.handle, o.value.name.slice());
    try c.say("Created scene '{s}' ({s}).", .{ name, e.id });
}

/// Blender's startup objects: a 2 m cube at the origin, a camera and a
/// 1000 W point light, in their default positions.
fn addDefaultObjects(doc: *core.Document) HandlerError!void {
    const gpa = doc.gpa;
    var cube_mesh = engine.geom.primitives.generate(gpa, .cube, .{}) catch return error.OutOfMemory;
    const mesh = doc.db.create(.mesh, "Cube", cube_mesh) catch |e| {
        cube_mesh.releaseRefs(gpa);
        return e;
    };
    const mat = try doc.db.create(.material, "Material", .{});
    _ = core.edit.addObject(doc, "Cube", .mesh, mesh) catch return error.OutOfMemory;
    core.edit.assignMaterial(doc, doc.db.findByName(.object, "Cube").?, mat, 0) catch return error.OutOfMemory;

    const cam = try doc.db.create(.camera, "Camera", .{ .clip_end = 100 });
    const cam_ob = core.edit.addObject(doc, "Camera", .camera, cam) catch return error.OutOfMemory;
    const co = doc.db.get(.object, cam_ob).?;
    co.location = .{ 7.358891, -6.925791, 4.958309 };
    co.rotation_euler = common.degVec(.{ 63.559, 0, 46.692 });
    doc.sceneData().camera = cam_ob;

    const light = try doc.db.create(.light, "Light", .{ .energy = 1000, .radius = 0.1 });
    const lo = core.edit.addObject(doc, "Light", .light, light) catch return error.OutOfMemory;
    const l = doc.db.get(.object, lo).?;
    l.location = .{ 4.076245, 1.005454, 5.903862 };
    l.rotation_euler = common.degVec(.{ 37.261, 3.164, 106.936 });
}

fn inspect(c: *Call) HandlerError!void {
    const doc = c.doc();
    const scene = doc.sceneData();
    const w = &c.out;
    if (c.args.str("object")) |_| {
        const h = try c.object("object");
        const ob = doc.db.get(.object, h).?;
        try c.field("object");
        try core.registry.writeValues(core.types.Object, ob, w);
        try c.field("summary");
        try common.writeObjectSummary(c, w, h);
        if (ob.data) |d| {
            try c.field("data_properties");
            switch (ob.kind) {
                .camera => try core.registry.writeValues(core.types.Camera, doc.db.get(.camera, d).?, w),
                .light => try core.registry.writeValues(core.types.Light, doc.db.get(.light, d).?, w),
                .curve => try core.registry.writeValues(core.types.Curve, doc.db.get(.curve, d).?, w),
                .mesh => {
                    const m = doc.db.get(.mesh, d).?;
                    try w.beginObject();
                    try w.objectField("verts");
                    try w.write(m.vertCount());
                    try w.objectField("edges");
                    try w.write(m.edgeCount());
                    try w.objectField("faces");
                    try w.write(m.faceCount());
                    try w.objectField("users");
                    try w.write(core.edit.userCount(&doc.db, d));
                    try w.objectField("attributes");
                    try w.beginArray();
                    for (m.attrs[0..m.attr_count]) |a| {
                        try w.beginObject();
                        try w.objectField("name");
                        try w.write(a.name.slice());
                        try w.objectField("domain");
                        try w.write(@tagName(a.domain));
                        try w.objectField("type");
                        try w.write(@tagName(a.data));
                        try w.endObject();
                    }
                    try w.endArray();
                    try w.endObject();
                },
                .empty => try w.write(null),
            }
        }
        try c.say("Object '{s}' ({s}).", .{ ob.name.slice(), @tagName(ob.kind) });
        return;
    }

    try c.field("scene");
    try w.beginObject();
    try w.objectField("name");
    try w.write(scene.name.slice());
    try w.objectField("settings");
    try core.registry.writeValues(core.types.Scene, scene, w);
    try w.objectField("active_camera");
    if (scene.camera) |cam| {
        try w.write(if (doc.db.get(.object, cam)) |o| o.name.slice() else null);
    } else try w.write(null);
    try w.objectField("units");
    try w.write("metres, Z up, degrees");
    try w.objectField("can_undo");
    try w.write(doc.canUndo());
    try w.objectField("can_redo");
    try w.write(doc.canRedo());
    try w.endObject();

    const objects = try core.edit.sceneObjects(doc, c.arena);
    var lo: [3]f32 = .{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
    var hi: [3]f32 = .{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
    var tris: usize = 0;
    try c.field("objects");
    try w.beginArray();
    for (objects) |h| {
        try common.writeObjectSummary(c, w, h);
        const ob = doc.db.get(.object, h).?;
        if (ob.kind == .mesh) {
            if (ob.data) |d| tris += doc.db.get(.mesh, d).?.triangleCount();
            if (try engine.eval.flatten.objectBounds(doc, h)) |b| {
                lo = v.min3(lo, b[0]);
                hi = v.max3(hi, b[1]);
            }
        }
    }
    try w.endArray();
    if (lo[0] <= hi[0]) {
        try c.field("bounds");
        try common.writeBounds(w, .{ lo, hi });
    }
    if (doc.db.collection.live > 1) {
        try c.field("collections");
        try common.writeCollectionTree(c, w);
    }
    try c.field("materials");
    try w.beginArray();
    var mit = doc.db.material.iterator();
    while (mit.next()) |m| try w.write(m.value.name.slice());
    try w.endArray();
    try c.field("triangles");
    try w.write(tris);
    try c.say("Scene '{s}': {d} objects, {d} triangles, rev {d}.", .{ scene.name.slice(), objects.len, tris, doc.rev });
}

fn validate(c: *Call) HandlerError!void {
    const doc = c.doc();
    const w = &c.out;
    var issues: usize = 0;
    try c.field("issues");
    try w.beginArray();
    const objects = try core.edit.sceneObjects(doc, c.arena);
    var used_materials: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (objects) |h| {
        const ob = doc.db.get(.object, h).?;
        if (ob.kind != .mesh) continue;
        const m = doc.db.get(.mesh, ob.data orelse continue) orelse continue;
        if (engine.geom.build.validate(m)) |problem| {
            try issue(w, "error", ob.name.slice(), problem);
            issues += 1;
        }
        if (m.faceCount() == 0) {
            try issue(w, "warning", ob.name.slice(), "mesh has no faces");
            issues += 1;
        }
        for (ob.scale) |s| if (s == 0) {
            try issue(w, "warning", ob.name.slice(), "zero scale on an axis makes the object flat and its normals undefined");
            issues += 1;
            break;
        };
        for (m.materials.slice()) |mh| if (mh) |x| try used_materials.put(c.arena, x.index, {});
    }
    var mit = doc.db.material.iterator();
    while (mit.next()) |m| if (!used_materials.contains(m.handle.index)) {
        try issue(w, "info", m.value.name.slice(), "material is not assigned to any mesh");
        issues += 1;
    };
    const scene = doc.sceneData();
    if (scene.camera == null) {
        try issue(w, "warning", scene.name.slice(), "no active camera; renders use an automatic view and exports have no camera");
        issues += 1;
    } else if (objects.len > 0) {
        // Objects whose bounds are entirely behind the camera.
        const cam = scene.camera.?;
        const cw = try core.edit.worldMatrix(&doc.db, cam);
        const fwd = v.normalize(v.transformDir(cw, .{ 0, 0, -1 }));
        const eye = v.translation(cw);
        for (try core.edit.sceneVisibility(doc, c.arena)) |x| {
            const h = x.handle;
            const ob = doc.db.get(.object, h).?;
            if (ob.kind != .mesh or ob.hide_render or !x.render) continue;
            const b = (try engine.eval.flatten.objectBounds(doc, h)) orelse continue;
            var any_front = false;
            for (0..8) |k| {
                const p: [3]f32 = .{ b[k & 1][0], b[(k >> 1) & 1][1], b[(k >> 2) & 1][2] };
                if (v.dot(v.sub(p, eye), fwd) > 0) any_front = true;
            }
            if (!any_front) {
                try issue(w, "warning", ob.name.slice(), "object is behind the active camera");
                issues += 1;
            }
        }
    }
    try w.endArray();
    try c.say("{d} issue(s) found.", .{issues});
}

fn issue(w: *std.json.Stringify, severity: []const u8, subject: []const u8, message: []const u8) !void {
    try w.beginObject();
    try w.objectField("severity");
    try w.write(severity);
    try w.objectField("subject");
    try w.write(subject);
    try w.objectField("message");
    try w.write(message);
    try w.endObject();
}

fn undo(c: *Call) HandlerError!void {
    try history(c, true);
}

fn redo(c: *Call) HandlerError!void {
    try history(c, false);
}

fn history(c: *Call, back: bool) HandlerError!void {
    const doc = c.doc();
    const steps: usize = @intCast(c.args.int("steps").?);
    var done: usize = 0;
    var labels: std.ArrayList([]const u8) = .empty;
    while (done < steps) : (done += 1) {
        var buf: [64]u8 = undefined;
        const label = (if (back) try doc.undo(&buf) else try doc.redo(&buf)) orelse break;
        try labels.append(c.arena, try c.arena.dupe(u8, label));
    }
    if (done == 0) {
        return c.failAt(.invalid_operation, "", "", &.{}, "nothing to {s}", .{if (back) "undo" else "redo"});
    }
    try c.field(if (back) "undone" else "redone");
    try c.out.write(labels.items);
    try c.say("{s} {d} step(s): {s}.", .{ if (back) "Undid" else "Redid", done, labels.items[0] });
}

fn apply(c: *Call) HandlerError!void {
    const ops = c.args.value("ops").?.array.items;
    try c.server.runBatch(c, ops);
    try c.say("Applied {d} op(s) in one transaction.", .{ops.len});
}

fn close(c: *Call) HandlerError!void {
    const e = c.entry.?;
    if (e.doc.dirty > 0 and !c.args.boolean("confirm").?) {
        return c.failAt(.confirmation_required, "/confirm", "pass confirm: true to discard the changes", &.{}, "scene '{s}' has {d} unsaved change(s)", .{ e.id, e.doc.dirty });
    }
    const id = try c.arena.dupe(u8, e.id);
    _ = c.server.closeScene(e.id);
    c.entry = null;
    try c.field("closed");
    try c.out.write(id);
    try c.say("Closed scene {s}.", .{id});
}
