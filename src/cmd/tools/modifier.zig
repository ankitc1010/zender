//! modifier.* tools: an object's modifier stack (TRD §7). Modifiers change
//! what previews, renders and exports see, not the object's mesh data,
//! until applied. Settings go in `properties` (schema.describe modifier
//! lists them); the object a modifier reads (boolean operand, mirror
//! centre, array offset) is `target`.

const std = @import("std");
const engine = @import("engine");
const server = @import("../server.zig");
const schema = @import("../schema.zig");
const common = @import("common.zig");
const shading = @import("shading.zig");

const core = engine.core;
const geom = engine.geom;
const depsgraph = engine.eval.depsgraph;
const Modifier = core.types.Modifier;
const ModifierKind = core.types.ModifierKind;
const IdHandle = core.IdHandle;
const Call = server.Call;
const Tool = server.Tool;
const HandlerError = server.HandlerError;
const Param = schema.Param;

fn writeSettingsSchema(w: *std.json.Stringify) std.json.Stringify.Error!void {
    try w.beginObject();
    try w.objectField("type");
    try w.write("object");
    try w.objectField("description");
    try w.write("Settings by name, e.g. {\"levels\":2}; schema.describe type modifier lists every one with its unit and range");
    try w.endObject();
}

const kinds = std.meta.fieldNames(ModifierKind);
const object_param: Param = .{ .name = "object", .type = .{ .name_ref = .{} }, .doc = "Mesh object", .required = true };
const modifier_param: Param = .{ .name = "modifier", .type = .{ .string = .{ .max_len = 255 } }, .doc = "Modifier name in the stack", .required = true };
const settings_param: Param = .{ .name = "properties", .type = .{ .properties = writeSettingsSchema }, .doc = "" };

pub const tools = [_]Tool{
    .{
        .name = "modifier.add",
        .title = "Add modifier",
        .description = "Add a modifier to a mesh object's stack; it changes what previews and exports see, not the mesh, until applied. Types and their settings: array (count, relative_offset, constant_offset, merge; target steps by its transform), mirror (axis_x/y/z, merge, merge_threshold; target is the centre), solidify (thickness, offset), subdivision (levels, render_levels, subdivision_type), bevel (width, segments, angle_limit), boolean (operation; target required), displace (strength, mid_level, texture none|noise, noise_scale, noise_seed, or texture_recipe: a material.create recipe), decimate (ratio), triangulate (quad_method, ngon_method); all have show_viewport, show_render. Returns the evaluated counts. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"object\":\"Head\",\"type\":\"subdivision\",\"properties\":{\"levels\":2}}.",
        .params = common.mutating(&.{
            object_param,
            .{ .name = "type", .type = .{ .enumeration = kinds }, .doc = "Modifier type", .required = true },
            .{ .name = "name", .type = .{ .string = .{ .max_len = 255 } }, .doc = "Name in the stack; default the type, made unique" },
            .{ .name = "target", .type = .{ .name_ref = .{} }, .doc = "Object the modifier reads (boolean, mirror, array)" },
            settings_param,
            .{ .name = "index", .type = .{ .integer = .{ .min = 0, .max = 255 } }, .doc = "Stack position; default last" },
        }),
        .kind = .mutating,
        .handler = add,
    },
    .{
        .name = "modifier.update",
        .title = "Update modifier",
        .description = "Change a modifier's settings, target (null clears), name or stack position. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"object\":\"Head\",\"modifier\":\"Subdivision\",\"properties\":{\"render_levels\":3}}.",
        .params = common.mutating(&.{
            object_param,
            modifier_param,
            .{ .name = "rename", .type = .{ .string = .{ .max_len = 255 } }, .doc = "New name" },
            .{ .name = "target", .type = .{ .name_ref = .{ .nullable = true } }, .doc = "New target, or null" },
            settings_param,
            .{ .name = "index", .type = .{ .integer = .{ .min = 0, .max = 255 } }, .doc = "Move to this position" },
        }),
        .kind = .mutating,
        .handler = update,
    },
    .{
        .name = "modifier.remove",
        .title = "Remove modifier",
        .description = "Remove a modifier from a mesh object's stack. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"object\":\"Head\",\"modifier\":\"Mirror\"}.",
        .params = common.mutating(&.{ object_param, modifier_param }),
        .kind = .mutating,
        .handler = remove,
    },
    .{
        .name = "modifier.apply",
        .title = "Apply modifier",
        .description = "Make a modifier's result (viewport settings) the object's mesh and remove it from the stack; without modifier, apply the whole stack in order. A modifier applied while others sit above it acts on the plain mesh, as in Blender. Mesh data shared with other objects cannot be applied. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"object\":\"Head\",\"modifier\":\"Mirror\"}.",
        .params = common.mutating(&.{
            object_param,
            .{ .name = "modifier", .type = .{ .string = .{ .max_len = 255 } }, .doc = "Modifier to apply; omitted applies all" },
        }),
        .kind = .mutating,
        .handler = applyMod,
    },
};

const Target = struct { ob: IdHandle, mh: IdHandle };

fn meshObject(c: *Call) HandlerError!Target {
    const oh = try c.object("object");
    const ob = c.doc().db.get(.object, oh).?;
    const mh = (if (ob.kind == .mesh) ob.data else null) orelse {
        return c.failAt(.invalid_argument, "/object", "modifiers work on mesh objects", &.{}, "'{s}' is a {s}, not a mesh", .{ ob.name.slice(), @tagName(ob.kind) });
    };
    return .{ .ob = oh, .mh = mh };
}

fn find(c: *Call, ob: *core.types.Object) HandlerError!usize {
    const name = c.args.str("modifier").?;
    for (ob.modifiers.slice(), 0..) |*m, i| if (m.name.eql(name)) return i;
    var names: std.ArrayList([]const u8) = .empty;
    for (ob.modifiers.slice()) |*m| try names.append(c.arena, try c.arena.dupe(u8, m.name.slice()));
    return c.failAt(.not_found, "/modifier", if (names.items.len == 0) "the object has no modifiers; add one with modifier.add" else "", names.items, "'{s}' has no modifier named '{s}'", .{ ob.name.slice(), name });
}

/// A name not yet used in the stack: `base`, then `base.001` and on.
fn uniqueName(c: *Call, mods: []const Modifier, base: []const u8, skip: ?usize) HandlerError![]const u8 {
    var n: usize = 0;
    while (n < 1000) : (n += 1) {
        const name = if (n == 0) base else try std.fmt.allocPrint(c.arena, "{s}.{d:0>3}", .{ base, n });
        var taken = false;
        for (mods, 0..) |*m, i| if (skip != i and m.name.eql(name)) {
            taken = true;
        };
        if (!taken) return name;
    }
    return c.fail(.invalid_argument, "too many modifiers named '{s}'", .{base});
}

fn defaultName(kind: ModifierKind) []const u8 {
    return switch (kind) {
        .array => "Array",
        .mirror => "Mirror",
        .solidify => "Solidify",
        .subdivision => "Subdivision",
        .bevel => "Bevel",
        .boolean => "Boolean",
        .displace => "Displace",
        .decimate => "Decimate",
        .triangulate => "Triangulate",
    };
}

/// Sets `target` from the argument, checking kind and cycles.
fn setTarget(c: *Call, ob_h: IdHandle, md: *Modifier) HandlerError!void {
    const doc = c.doc();
    const use = Modifier.targetUse(md.kind);
    if (c.args.value("target")) |tv| {
        if (tv == .null) {
            md.target = null;
        } else {
            if (use == .none) return c.failAt(.invalid_argument, "/target", "only boolean, mirror and array modifiers read another object", &.{}, "a {s} modifier has no target", .{@tagName(md.kind)});
            const th = try c.object("target");
            const t = doc.db.get(.object, th).?;
            if (th.eql(ob_h)) return c.failAt(.invalid_argument, "/target", "pick another object", &.{}, "an object cannot be its own modifier's target", .{});
            if (md.kind == .boolean and t.kind != .mesh) return c.failAt(.invalid_argument, "/target", "a boolean needs a mesh object to combine with", &.{}, "'{s}' is a {s}, not a mesh", .{ t.name.slice(), @tagName(t.kind) });
            if (try depsgraph.cyclePath(c.arena, &doc.db, ob_h, th)) |path| {
                var text: std.ArrayList(u8) = .empty;
                try text.appendSlice(c.arena, doc.db.get(.object, ob_h).?.name.slice());
                for (path) |h| {
                    try text.appendSlice(c.arena, " -> ");
                    try text.appendSlice(c.arena, doc.db.get(.object, h).?.name.slice());
                }
                return c.failAt(.invalid_argument, "/target", "remove or retarget one of those modifiers first", &.{}, "that would make a dependency cycle: {s}", .{text.items});
            }
            md.target = th;
        }
    }
    if (use == .required and md.target == null) return c.failAt(.invalid_argument, "/target", "name the mesh object to combine with", &.{}, "a boolean modifier needs a target", .{});
}

/// Applies `properties`, warning about settings this kind ignores.
fn setSettings(c: *Call, md: *Modifier) HandlerError!void {
    const p0 = c.args.value("properties") orelse return;
    // texture_recipe is a procedural texture, not a registry value.
    var p = p0;
    if (p0 == .object) if (p0.object.get("texture_recipe")) |rv| {
        if (rv != .object) return c.failAt(.invalid_argument, "/properties/texture_recipe", "see the recipe keys in material.create", &.{}, "texture_recipe must be an object", .{});
        md.recipe = try shading.parseRecipe(c, rv.object, "/properties/texture_recipe");
        md.texture = .recipe;
        var rest: std.json.ObjectMap = .empty;
        var it0 = p0.object.iterator();
        while (it0.next()) |e| if (!std.mem.eql(u8, e.key_ptr.*, "texture_recipe")) try rest.put(c.arena, e.key_ptr.*, e.value_ptr.*);
        p = .{ .object = rest };
    };
    _ = try common.setProperties(c, Modifier, md, p, "properties");
    var it = p.object.iterator();
    while (it.next()) |kv| {
        const prop = core.registry.find(Modifier, kv.key_ptr.*) orelse continue;
        const colon = std.mem.indexOfScalar(u8, prop.doc, ':') orelse continue;
        var applies = false;
        var kit = std.mem.tokenizeAny(u8, prop.doc[0..colon], ", ");
        while (kit.next()) |k| applies = applies or std.mem.eql(u8, k, @tagName(md.kind));
        if (!applies) try c.warn("{s} has no effect on a {s} modifier", .{ kv.key_ptr.*, @tagName(md.kind) });
    }
}

fn storeStack(c: *Call, ob: *core.types.Object, mods: []const Modifier) HandlerError!void {
    const gpa = c.doc().gpa;
    const fresh = try core.Shared(Modifier).fromSlice(gpa, mods);
    ob.modifiers.release(gpa);
    ob.modifiers = fresh;
}

/// Evaluates the object (render settings), checks the triangle budget,
/// reports what modifiers could not do, and writes the stack and counts.
fn report(c: *Call, ob_h: IdHandle) HandlerError!void {
    const e = c.entry.?;
    const doc = c.doc();
    var ev: depsgraph.Evaluator = .{
        .arena = c.arena,
        .doc = doc,
        .cache = &e.eval_cache,
        .purpose = .render,
        .stop = if (c.server.pool.deadline) |d| .{ .deadline = d, .io = c.server.io } else null,
    };
    const r = (ev.evaluate(ob_h) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DeadlineExceeded => return error.ToolFailed,
    }).?;
    const tris = r.mesh.triangleCount();
    const max = c.server.config.budgets.max_triangles;
    if (tris > max) return c.failAt(.budget_exceeded, "/properties", "lower levels, count or segments", &.{}, "the stack would evaluate to {d} triangles; the budget is {d}", .{ tris, max });
    const ob = doc.db.get(.object, ob_h).?;
    for (ob.modifiers.slice(), 0..) |*m, i| {
        const note = if (i < r.notes.len) r.notes[i] else .none;
        switch (note) {
            .none => {},
            .skipped => try c.warn("modifier '{s}' could not run and passed its input through (for a boolean or bevel: the mesh is not a closed surface)", .{m.name.slice()}),
            .no_target => try c.warn("modifier '{s}' has no usable target and does nothing", .{m.name.slice()}),
            .dropped_uvs => try c.warn("modifier '{s}' drops the UV map", .{m.name.slice()}),
            .width_reduced => try c.warn("modifier '{s}': width reduced so neighbouring cuts do not cross (angle_limit is in degrees; a small one bevels many edges)", .{m.name.slice()}),
        }
    }
    try c.field("stack");
    try writeStack(c, ob);
    try c.field("evaluated");
    try c.out.beginObject();
    try c.out.objectField("verts");
    try c.out.write(r.mesh.vertCount());
    try c.out.objectField("faces");
    try c.out.write(r.mesh.faceCount());
    try c.out.objectField("triangles");
    try c.out.write(tris);
    try c.out.endObject();
}

pub fn writeStack(c: *Call, ob: *const core.types.Object) HandlerError!void {
    const doc = c.doc();
    try c.out.beginArray();
    for (ob.modifiers.slice()) |*m| {
        try c.out.beginObject();
        try c.out.objectField("name");
        try c.out.write(m.name.slice());
        try c.out.objectField("type");
        try c.out.write(@tagName(m.kind));
        if (m.target) |t| if (doc.db.get(.object, t)) |to| {
            try c.out.objectField("target");
            try c.out.write(to.name.slice());
        };
        if (!m.show_viewport or !m.show_render) {
            try c.out.objectField("show_viewport");
            try c.out.write(m.show_viewport);
            try c.out.objectField("show_render");
            try c.out.write(m.show_render);
        }
        try c.out.endObject();
    }
    try c.out.endArray();
}

fn add(c: *Call) HandlerError!void {
    const t = try meshObject(c);
    const doc = c.doc();
    const ob = doc.db.get(.object, t.ob).?;
    const kind = std.meta.stringToEnum(ModifierKind, c.args.str("type").?).?;
    var md = Modifier.defaults(kind);
    try setSettings(c, &md);
    try setTarget(c, t.ob, &md);
    const old = ob.modifiers.slice();
    md.name = .init(try uniqueName(c, old, c.args.str("name") orelse defaultName(kind), null));
    const at: usize = if (c.args.int("index")) |i| @min(@as(usize, @intCast(i)), old.len) else old.len;
    var list: std.ArrayList(Modifier) = .empty;
    try list.appendSlice(c.arena, old[0..at]);
    try list.append(c.arena, md);
    try list.appendSlice(c.arena, old[at..]);
    try storeStack(c, ob, list.items);
    try c.markChanged(t.ob, ob.name.slice());
    try report(c, t.ob);
    try c.say("Added {s} modifier '{s}' to '{s}' at position {d}.", .{ @tagName(kind), md.name.slice(), ob.name.slice(), at });
}

fn update(c: *Call) HandlerError!void {
    const t = try meshObject(c);
    const doc = c.doc();
    const ob = doc.db.get(.object, t.ob).?;
    const i = try find(c, ob);
    var list: std.ArrayList(Modifier) = .empty;
    try list.appendSlice(c.arena, ob.modifiers.slice());
    var md = list.items[i];
    try setSettings(c, &md);
    try setTarget(c, t.ob, &md);
    if (c.args.str("rename")) |n| md.name = .init(try uniqueName(c, list.items, n, i));
    _ = list.orderedRemove(i);
    const at: usize = if (c.args.int("index")) |x| @min(@as(usize, @intCast(x)), list.items.len) else i;
    try list.insert(c.arena, at, md);
    try storeStack(c, ob, list.items);
    try c.markChanged(t.ob, ob.name.slice());
    try report(c, t.ob);
    try c.say("Updated modifier '{s}' of '{s}'.", .{ md.name.slice(), ob.name.slice() });
}

fn remove(c: *Call) HandlerError!void {
    const t = try meshObject(c);
    const ob = c.doc().db.get(.object, t.ob).?;
    const i = try find(c, ob);
    const name = try c.arena.dupe(u8, ob.modifiers.slice()[i].name.slice());
    var list: std.ArrayList(Modifier) = .empty;
    try list.appendSlice(c.arena, ob.modifiers.slice());
    _ = list.orderedRemove(i);
    try storeStack(c, ob, list.items);
    try c.markChanged(t.ob, ob.name.slice());
    try report(c, t.ob);
    try c.say("Removed modifier '{s}' from '{s}'.", .{ name, ob.name.slice() });
}

fn applyMod(c: *Call) HandlerError!void {
    const t = try meshObject(c);
    const doc = c.doc();
    const gpa = doc.gpa;
    const ob = doc.db.get(.object, t.ob).?;
    if (ob.modifiers.len() == 0) return c.failAt(.invalid_argument, "/object", "add one with modifier.add", &.{}, "'{s}' has no modifiers", .{ob.name.slice()});
    if (core.edit.userCount(&doc.db, t.mh) > 1) {
        return c.failAt(.invalid_operation, "/object", "give the object its own mesh first: object.duplicate with linked false, then delete the original", &.{}, "the mesh of '{s}' is shared with other objects, so a modifier cannot be applied to it", .{ob.name.slice()});
    }
    const all = c.args.str("modifier") == null;
    const which: ?usize = if (all) null else try find(c, ob);
    const m = doc.db.get(.mesh, t.mh).?;
    var result: core.types.Mesh = undefined;
    // Through the scene's cache, so the evaluated buffers outlive the call.
    var ev: depsgraph.Evaluator = .{ .arena = c.arena, .doc = doc, .cache = &c.entry.?.eval_cache, .purpose = .viewport };
    const mods = ob.modifiers.slice();
    if (which) |i| {
        if (i > 0) try c.warn("'{s}' was not first in the stack; it was applied to the plain mesh, as in Blender", .{mods[i].name.slice()});
        const md = mods[i];
        var target: ?geom.modifiers.Target = null;
        if (md.target) |th| if (doc.db.get(.object, th) != null) {
            const tr = ev.evaluate(th) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.DeadlineExceeded => return error.ToolFailed,
            };
            target = .{ .mesh = if (tr) |r| r.mesh else null, .world = try core.edit.worldMatrix(&doc.db, th) };
        };
        var note: geom.modifiers.Note = .none;
        result = geom.modifiers.apply(gpa, m, &md, .{ .world = try core.edit.worldMatrix(&doc.db, t.ob), .target = target, .purpose = .viewport }, &note) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DeadlineExceeded => return error.ToolFailed,
        };
        if (note != .none) try c.warn("modifier '{s}': {s}", .{ md.name.slice(), @tagName(note) });
    } else {
        const r = (ev.evaluate(t.ob) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DeadlineExceeded => return error.ToolFailed,
        }).?;
        // Shares the cache entry's buffers.
        result = r.mesh.*;
        result.retainRefs();
    }
    var stored = false;
    defer if (!stored) result.releaseRefs(gpa);
    const tris = result.triangleCount();
    if (tris > m.triangleCount()) try c.spendTriangles(tris - m.triangleCount());
    result.name = m.name;
    m.releaseRefs(gpa);
    m.* = result;
    stored = true;
    var list: std.ArrayList(Modifier) = .empty;
    if (which) |i| {
        try list.appendSlice(c.arena, mods);
        _ = list.orderedRemove(i);
    }
    try storeStack(c, ob, list.items);
    try c.markChanged(t.ob, ob.name.slice());
    try c.markChanged(t.mh, m.name.slice());
    try c.field("stack");
    try writeStack(c, ob);
    try c.field("counts");
    try c.out.beginObject();
    try c.out.objectField("verts");
    try c.out.write(m.vertCount());
    try c.out.objectField("faces");
    try c.out.write(m.faceCount());
    try c.out.objectField("triangles");
    try c.out.write(m.triangleCount());
    try c.out.endObject();
    try c.say("Applied {s} to the mesh of '{s}'; it now has {d} verts, {d} faces.", .{ if (all) "the whole stack" else "the modifier", ob.name.slice(), m.vertCount(), m.faceCount() });
}
