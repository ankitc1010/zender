//! material.* and world.set.

const std = @import("std");
const engine = @import("engine");
const server = @import("../server.zig");
const common = @import("common.zig");
const schema = @import("../schema.zig");
const math = @import("math");
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
        .description = "Create a Principled BSDF material. Colours are scene-linear RGB(A) in 0..1 (sRGB 0.5 grey is about 0.214 linear). base_color, metallic, roughness and emission_color also take a procedural texture recipe instead of a value; base_color also takes {attribute: name}, a mesh colour attribute (mesh.from_sdf step colours write \"Color\"); normal takes {bump: recipe, strength, distance}: {texture: noise|wave|voronoi, coords object|generated|uv|normal, mapping {location, rotation, scale}, the node's inputs as Blender names them (scale, detail, roughness, lacunarity, distortion; wave_type, direction, profile, phase; randomness, output), ramp {mode linear|ease|constant, stops [[position, [r,g,b]], ...]}}; values match Blender's nodes. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"name\":\"Camo\",\"properties\":{\"roughness\":0.85,\"base_color\":{\"texture\":\"noise\",\"scale\":2.6,\"distortion\":0.6,\"ramp\":{\"mode\":\"constant\",\"stops\":[[0,[0.02,0.03,0.01]],[0.45,[0.1,0.06,0.02]],[0.64,[0.19,0.035,0.026]]]}}}}.",
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
        .name = "material.bake",
        .title = "Bake textures",
        .description = "Bake the procedural textures of a mesh object's materials to images through its UV map (run mesh.uv_unwrap first if it has none), so glTF export carries them as textures. Each textured input of each slot gets an image named <material>_<input>, size x size, linked as that input's image; normal bakes a tangent-space normal map. The bake uses the object's own mesh (before modifiers) and its UV layout, so a material shared with other objects fits this one. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"object\":\"Crown\",\"size\":1024}.",
        .params = common.mutating(&.{
            .{ .name = "object", .type = .{ .name_ref = .{} }, .doc = "Mesh object", .required = true },
            .{ .name = "inputs", .type = .{ .string_list = .{ .max_items = 5 } }, .doc = "base_color, metallic, roughness, emission_color, normal; default: every textured one" },
            .{ .name = "size", .type = .{ .integer = .{ .min = 8, .max = 8192 } }, .doc = "Image width and height (px)", .default = .{ .integer = 1024 } },
            .{ .name = "margin", .type = .{ .integer = .{ .min = 0, .max = 64 } }, .doc = "Texels to extend past UV islands", .default = .{ .integer = 4 } },
        }),
        .kind = .mutating,
        .handler = bake,
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

/// Sets `properties` on a material: plain values through the registry,
/// recipe objects (and normal's bump) as textures, base_color
/// {attribute} as a colour attribute. A plain value for an input that had
/// a texture or an attribute removes it.
fn applyProperties(c: *Call, m: *core.types.Material, p: std.json.Value) HandlerError!usize {
    if (p != .object) return common.setProperties(c, core.types.Material, m, p, "properties");
    const gpa = c.doc().gpa;
    var plain: std.json.ObjectMap = .empty;
    var n: usize = 0;
    var it = p.object.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        const val = e.value_ptr.*;
        const input = std.meta.stringToEnum(core.types.TextureInput, key) orelse {
            try plain.put(c.arena, key, val);
            continue;
        };
        if (input == .base_color) m.base_color_attribute = .{};
        if (val == .null) {
            try m.setTexture(gpa, input, null);
            n += 1;
            continue;
        }
        if (input == .base_color and val == .object and val.object.get("attribute") != null) {
            const av = val.object.get("attribute").?;
            if (val.object.count() != 1 or av != .string or av.string.len == 0 or av.string.len > 64)
                return c.failAt(.invalid_argument, "/properties/base_color/attribute", "give {\"attribute\": \"Color\"}: the name of a mesh colour attribute", &.{}, "invalid colour attribute", .{});
            try m.setTexture(gpa, .base_color, null);
            m.base_color_attribute = .init(av.string);
            n += 1;
            continue;
        }
        if (input == .normal) {
            const o = if (val == .object) val.object else return c.failAt(.invalid_argument, "/properties/normal", "give {\"bump\": recipe, \"strength\": 1, \"distance\": 1}, or null to remove it", &.{}, "normal takes a bump texture", .{});
            const bv = o.get("bump") orelse return c.failAt(.invalid_argument, "/properties/normal/bump", "", &.{}, "missing 'bump'", .{});
            if (bv != .object) return c.failAt(.invalid_argument, "/properties/normal/bump", "", &.{}, "'bump' must be a recipe object", .{});
            var r = try parseRecipe(c, bv.object, "/properties/normal/bump");
            var oit = o.iterator();
            while (oit.next()) |kv| {
                const k = kv.key_ptr.*;
                const x = schema.number(kv.value_ptr.*);
                if (std.mem.eql(u8, k, "bump")) continue;
                if (std.mem.eql(u8, k, "strength") and x != null and x.? >= 0 and x.? <= 1) {
                    r.bump_strength = @floatCast(x.?);
                } else if (std.mem.eql(u8, k, "distance") and x != null and x.? >= 0 and x.? <= 1000) {
                    r.bump_distance = @floatCast(x.?);
                } else if (std.mem.eql(u8, k, "invert") and kv.value_ptr.* == .bool) {
                    r.bump_invert = kv.value_ptr.*.bool;
                } else return c.failAt(.invalid_argument, try std.fmt.allocPrint(c.arena, "/properties/normal/{s}", .{k}), "normal takes bump, strength (0-1), distance and invert", &.{}, "invalid '{s}'", .{k});
            }
            try m.setTexture(gpa, .normal, r);
            n += 1;
            continue;
        }
        if (val == .object) {
            try m.setTexture(gpa, input, try parseRecipe(c, val.object, try std.fmt.allocPrint(c.arena, "/properties/{s}", .{key})));
            n += 1;
        } else {
            try m.setTexture(gpa, input, null);
            try plain.put(c.arena, key, val);
        }
    }
    return n + try common.setProperties(c, core.types.Material, m, .{ .object = plain }, "properties");
}

pub fn parseRecipe(c: *Call, o: std.json.ObjectMap, path: []const u8) HandlerError!math.texture.Recipe {
    var diag: math.texture.ParseDiag = .{};
    return math.texture.parse(o, &diag) catch c.failAt(.invalid_argument, try std.fmt.allocPrint(c.arena, "{s}/{s}", .{ path, diag.key }), "see the recipe keys in material.create", &math.texture.recipe_keys, "{s} {s}", .{ diag.key, diag.message });
}

fn writeMaterial(c: *Call, m: *const core.types.Material) HandlerError!void {
    try c.field("material");
    try core.registry.writeValues(core.types.Material, m, &c.out);
    if (m.textures.len() > 0) {
        try c.field("textures");
        try m.writeTextures(&c.out);
    }
    if (m.base_color_attribute.len > 0) {
        try c.field("base_color_attribute");
        try c.out.write(m.base_color_attribute.slice());
    }
    var any = false;
    inline for (std.meta.fields(core.types.TextureInput)) |f| {
        const t: core.types.TextureInput = @enumFromInt(f.value);
        if (t.imageOf(m)) |ih| if (c.doc().db.get(.image, ih)) |im| {
            if (!any) {
                try c.field("images");
                try c.out.beginObject();
                any = true;
            }
            try c.out.objectField(f.name);
            try c.out.write(im.name.slice());
        };
    }
    if (any) try c.out.endObject();
}

fn create(c: *Call) HandlerError!void {
    const doc = c.doc();
    var mat: core.types.Material = .{};
    errdefer mat.releaseRefs(doc.gpa);
    if (c.args.value("properties")) |p| _ = try applyProperties(c, &mat, p);
    const h = try doc.db.create(.material, c.args.str("name") orelse "Material", mat);
    const m = doc.db.get(.material, h).?;
    try c.markCreated(h, m.name.slice());
    try writeMaterial(c, m);
    try c.say("Created material '{s}'.", .{m.name.slice()});
}

fn update(c: *Call) HandlerError!void {
    const doc = c.doc();
    const h = try c.lookup(.material, c.args.str("material").?, "/material");
    const m = doc.db.get(.material, h).?;
    const n = try applyProperties(c, m, c.args.value("properties").?);
    if (c.args.str("rename")) |new_name| _ = doc.db.rename(.material, h, new_name);
    try c.markChanged(h, m.name.slice());
    try writeMaterial(c, m);
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

fn bake(c: *Call) HandlerError!void {
    const doc = c.doc();
    const oh = try c.object("object");
    const ob = doc.db.get(.object, oh).?;
    if (ob.kind != .mesh) return c.failAt(.invalid_argument, "/object", "bake mesh objects; convert curves with curve.to_mesh", &.{}, "'{s}' is a {s}", .{ ob.name.slice(), @tagName(ob.kind) });
    const mh = ob.data orelse return c.failAt(.stale_handle, "/object", "", &.{}, "'{s}' has no mesh", .{ob.name.slice()});
    const mesh = doc.db.get(.mesh, mh).?;
    var wanted = [_]bool{true} ** 5;
    if (c.args.value("inputs")) |_| {
        @memset(&wanted, false);
        for (c.args.strings("inputs"), 0..) |s, i| {
            const t = std.meta.stringToEnum(core.types.TextureInput, s.string) orelse
                return c.failAt(.invalid_argument, try std.fmt.allocPrint(c.arena, "/inputs/{d}", .{i}), "", std.meta.fieldNames(core.types.TextureInput), "unknown input '{s}'", .{s.string});
            wanted[@intFromEnum(t)] = true;
        }
    }
    const size: u32 = @intCast(c.args.int("size").?);
    const max_edge = c.server.config.budgets.max_render_edge;
    if (size > max_edge) return c.failAt(.budget_exceeded, "/size", "ask the operator to raise --max-render-edge", &.{}, "size {d} exceeds the {d} px budget", .{ size, max_edge });
    const margin: u32 = @intCast(c.args.int("margin").?);
    if (ob.modifiers.len() > 0) try c.warn("'{s}' has modifiers; the bake uses its mesh before them", .{ob.name.slice()});

    var baked: usize = 0;
    try c.field("images");
    try c.out.beginArray();
    for (mesh.materials.slice(), 0..) |slot_mat, slot| {
        const mat_h = slot_mat orelse continue;
        const mat = doc.db.get(.material, mat_h) orelse continue;
        // Snapshot the recipes: creating images may move the material pool.
        const textures = try c.arena.dupe(core.types.MaterialTexture, mat.textures.slice());
        const mat_name = try c.arena.dupe(u8, mat.name.slice());
        for (textures) |*t| {
            if (!wanted[@intFromEnum(t.input)]) continue;
            const res = engine.geom.bake.bake(doc.gpa, mesh, &t.recipe, t.input, .{
                .width = size,
                .height = size,
                .margin = margin,
                .slot = @intCast(slot),
                .background = if (t.input == .normal) .{ 0.5, 0.5, 1, 1 } else .{ 0, 0, 0, 1 },
            }) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NoUvMap => return c.failAt(.invalid_operation, "/object", "give it a UV map with mesh.uv_unwrap", &.{}, "'{s}' has no UV map to bake through", .{ob.name.slice()}),
                error.NoFaces => return c.failAt(.invalid_operation, "/object", "", &.{}, "'{s}' has no faces", .{ob.name.slice()}),
            };
            if (res.covered == 0) {
                doc.gpa.free(res.pixels);
                try c.warn("no faces of slot {d} ('{s}') reach the UV square; {s} not baked", .{ slot, mat_name, @tagName(t.input) });
                continue;
            }
            if (res.overlapped * 100 > res.covered)
                try c.warn("UV islands overlap on {d}% of the texels slot {d} ('{s}') reaches; each keeps one face's value, so unwrap with mesh.uv_unwrap first for a bake that fits every face", .{ res.overlapped * 100 / res.covered, slot, mat_name });
            const name = try std.fmt.allocPrint(c.arena, "{s}_{s}", .{ mat_name, @tagName(t.input) });
            var image: core.types.Image = .{
                .width = @intCast(size),
                .height = @intCast(size),
                .colorspace = if (t.input == .base_color or t.input == .emission_color) .srgb else .non_color,
            };
            image.pixels = core.Shared([4]f32).fromOwned(doc.gpa, res.pixels) catch |e| {
                doc.gpa.free(res.pixels);
                return e;
            };
            const ih = doc.db.create(.image, name, image) catch |e| {
                image.releaseRefs(doc.gpa);
                return e;
            };
            t.input.setImage(doc.db.get(.material, mat_h).?, ih);
            try c.markCreated(ih, doc.db.get(.image, ih).?.name.slice());
            try c.out.beginObject();
            try c.out.objectField("image");
            try c.out.write(doc.db.get(.image, ih).?.name.slice());
            try c.out.objectField("material");
            try c.out.write(mat_name);
            try c.out.objectField("input");
            try c.out.write(@tagName(t.input));
            try c.out.objectField("coverage");
            try c.out.write(@as(f64, @floatFromInt(res.covered)) / @as(f64, @floatFromInt(@as(u64, size) * size)));
            try c.out.endObject();
            baked += 1;
        }
        try c.markChanged(mat_h, mat_name);
    }
    try c.out.endArray();
    if (baked == 0) return c.failAt(.invalid_operation, "/object", "give a material on this object a texture recipe first (material.update)", &.{}, "nothing to bake on '{s}'", .{ob.name.slice()});
    try c.say("Baked {d} image(s) of {d} x {d} px for '{s}'.", .{ baked, size, size, ob.name.slice() });
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
