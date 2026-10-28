//! material.* and world.set.

const std = @import("std");
const engine = @import("engine");
const server = @import("../server.zig");
const common = @import("common.zig");
const mesh_tools = @import("mesh.zig");

const core = engine.core;
const Call = server.Call;
const Tool = server.Tool;
const HandlerError = server.HandlerError;

fn writeMaterialSchema(w: *std.json.Stringify) std.json.Stringify.Error!void {
    try core.registry.writeSchema(core.types.Material, w);
}

pub const tools = [_]Tool{
    .{
        .name = "material.create",
        .title = "Create material",
        .description = "Create a Principled BSDF material. Colours are scene-linear RGB(A) in 0..1 (sRGB 0.5 grey is about 0.214 linear). Example: {\"scene_id\":\"scn_1a2b3c4d\",\"name\":\"Oak\",\"properties\":{\"base_color\":[0.3,0.15,0.06],\"roughness\":0.6}}.",
        .params = common.mutating(&.{
            common.name,
            .{ .name = "properties", .type = .{ .properties = writeMaterialSchema }, .doc = "Material properties" },
        }),
        .kind = .mutating,
        .handler = create,
    },
    .{
        .name = "material.update",
        .title = "Update material",
        .description = "Change properties of an existing material; every object using it updates. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"material\":\"Oak\",\"properties\":{\"metallic\":0,\"roughness\":0.4}}.",
        .params = common.mutating(&.{
            .{ .name = "material", .type = .{ .name_ref = .{} }, .doc = "Material to change", .required = true },
            .{ .name = "rename", .type = .{ .string = .{ .max_len = 255 } }, .doc = "New material name" },
            .{ .name = "properties", .type = .{ .properties = writeMaterialSchema }, .doc = "Material properties", .required = true },
        }),
        .kind = .mutating,
        .handler = update,
    },
    .{
        .name = "material.assign",
        .title = "Assign material",
        .description = "Put a material in a slot of each listed mesh object (slot 0 covers faces with material index 0, which is all faces of a primitive). Shared mesh data shares slots. With selector (one object only) the selected faces also move to that slot, so one mesh can carry several materials. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"objects\":[\"Crown\"],\"material\":\"Tan\",\"slot\":1,\"selector\":{\"where\":\"z > 0.14\"}}.",
        .params = common.mutating(&.{
            .{ .name = "objects", .type = .{ .string_list = .{} }, .doc = "Mesh objects", .required = true },
            .{ .name = "material", .type = .{ .name_ref = .{ .nullable = true } }, .doc = "Material, or null to empty the slot", .required = true },
            .{ .name = "slot", .type = .{ .integer = .{ .min = 0, .max = 255 } }, .doc = "Material slot index", .default = .{ .integer = 0 } },
            mesh_tools.selectorParam("face", false),
        }),
        .kind = .mutating,
        .handler = assign,
    },
    .{
        .name = "world.set",
        .title = "Set world",
        .description = "Set the background: a scene-linear RGB colour and a strength (1 = as is). Example: {\"scene_id\":\"scn_1a2b3c4d\",\"color\":[0.8,0.85,1],\"strength\":0.5}.",
        .params = common.mutating(&.{
            .{ .name = "color", .type = .color, .doc = "Background colour [r, g, b], scene-linear" },
            .{ .name = "strength", .type = .{ .number = .{ .min = 0, .max = 1e6 } }, .doc = "Background strength" },
        }),
        .kind = .mutating,
        .handler = worldSet,
    },
};

fn create(c: *Call) HandlerError!void {
    const doc = c.doc();
    var mat: core.types.Material = .{};
    if (c.args.value("properties")) |p| _ = try common.setProperties(c, core.types.Material, &mat, p, "properties");
    const h = try doc.db.create(.material, c.args.str("name") orelse "Material", mat);
    const m = doc.db.get(.material, h).?;
    try c.markCreated(h, m.name.slice());
    try c.field("material");
    try core.registry.writeValues(core.types.Material, m, &c.out);
    try c.say("Created material '{s}'.", .{m.name.slice()});
}

fn update(c: *Call) HandlerError!void {
    const doc = c.doc();
    const h = try c.lookup(.material, c.args.str("material").?, "/material");
    const m = doc.db.get(.material, h).?;
    const n = try common.setProperties(c, core.types.Material, m, c.args.value("properties").?, "properties");
    if (c.args.str("rename")) |new_name| _ = doc.db.rename(.material, h, new_name);
    try c.markChanged(h, m.name.slice());
    try c.field("material");
    try core.registry.writeValues(core.types.Material, m, &c.out);
    try c.say("Updated {d} value(s) on material '{s}'.", .{ n, m.name.slice() });
}

fn assign(c: *Call) HandlerError!void {
    const doc = c.doc();
    const mat: ?core.IdHandle = if (c.args.str("material")) |m| try c.lookup(.material, m, "/material") else null;
    const slot: usize = @intCast(c.args.int("slot").?);
    const names = c.args.strings("objects");
    if (c.args.value("selector") != null and names.len != 1)
        return c.failAt(.invalid_argument, "/objects", "call once per object when assigning faces", &.{}, "a selector applies to one object, got {d}", .{names.len});
    for (names, 0..) |n, i| {
        const path = try std.fmt.allocPrint(c.arena, "/objects/{d}", .{i});
        const h = try c.lookup(.object, n.string, path);
        const ob = doc.db.get(.object, h).?;
        if (ob.kind != .mesh and ob.kind != .curve) return c.failAt(.invalid_argument, path, "materials go on mesh and curve objects", &.{}, "'{s}' is a {s}", .{ ob.name.slice(), @tagName(ob.kind) });
        if (ob.kind == .curve and c.args.value("selector") != null) return c.failAt(.invalid_argument, "/selector", "convert it with curve.to_mesh first", &.{}, "face selectors apply to meshes; '{s}' is a curve", .{ob.name.slice()});
        core.edit.assignMaterial(doc, h, mat, slot) catch return error.OutOfMemory;
        if (c.args.value("selector") != null) {
            const faces = try mesh_tools.selectedFaces(c, h);
            core.edit.setFaceMaterial(doc, h, faces, @intCast(slot)) catch |err| switch (err) {
                error.TooManyAttributes => return c.failAt(.invalid_operation, "/objects/0", "remove an attribute first", &.{}, "'{s}' already has the maximum number of attributes", .{ob.name.slice()}),
                else => return error.OutOfMemory,
            };
            try c.say("Moved {d} face(s) of '{s}' to slot {d}.", .{ faces.len, ob.name.slice(), slot });
        }
        try c.markChanged(h, ob.name.slice());
        if (ob.data) |d| if (core.edit.userCount(&doc.db, d) > 1) {
            try c.warn("'{s}' shares its mesh with other objects; they changed too", .{ob.name.slice()});
        };
    }
    const mat_name = if (mat) |m| doc.db.get(.material, m).?.name.slice() else "(none)";
    try c.say("Assigned '{s}' to slot {d} of {d} object(s).", .{ mat_name, slot, names.len });
}

fn worldSet(c: *Call) HandlerError!void {
    const doc = c.doc();
    const scene = doc.sceneData();
    const wh = scene.world orelse blk: {
        const h = try doc.db.create(.world, "World", .{});
        doc.sceneData().world = h;
        break :blk h;
    };
    const w = doc.db.get(.world, wh).?;
    if (c.args.color("color")) |col| w.color = .{ col[0], col[1], col[2] };
    if (c.args.float("strength")) |s| w.strength = s;
    try c.markChanged(wh, w.name.slice());
    try c.field("world");
    try core.registry.writeValues(core.types.World, w, &c.out);
    try c.say("World set to [{d:.3}, {d:.3}, {d:.3}] x {d:.3}.", .{ w.color[0], w.color[1], w.color[2], w.strength });
}
