//! collection.* tools: grouping objects in a tree of collections under the
//! scene's master collection.

const std = @import("std");
const engine = @import("engine");
const server = @import("../server.zig");
const schema = @import("../schema.zig");
const common = @import("common.zig");

const core = engine.core;
const Call = server.Call;
const Tool = server.Tool;
const HandlerError = server.HandlerError;
const IdHandle = core.IdHandle;

fn writeCollectionPropsSchema(w: *std.json.Stringify) std.json.Stringify.Error!void {
    try core.registry.writeSchema(core.types.Collection, w);
}

const properties: schema.Param = .{ .name = "properties", .type = .{ .properties = writeCollectionPropsSchema }, .doc = "Collection properties (hide_render, hide_viewport)" };

pub const tools = [_]Tool{
    .{
        .name = "collection.create",
        .title = "Create collection",
        .description = "Create a collection to group objects, nested under parent (default: the master 'Scene Collection'). Listed objects move into it out of their other collections, like Blender's M > New Collection. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"name\":\"Table\",\"objects\":[\"Top\",\"Leg\"]}.",
        .params = common.mutating(&.{
            .{ .name = "name", .type = .{ .string = .{ .max_len = 255 } }, .doc = "Name; made unique with .001 suffixes if taken", .default = .{ .string = "Collection" } },
            .{ .name = "parent", .type = .{ .name_ref = .{} }, .doc = "Collection to nest it in" },
            .{ .name = "objects", .type = .{ .string_list = .{} }, .doc = "Objects to move into it" },
            properties,
        }),
        .kind = .mutating,
        .handler = create,
    },
    .{
        .name = "collection.update",
        .title = "Update collection",
        .description = "Change a collection: rename it, nest it under another parent, set properties, and move, link or unlink objects. move takes objects out of every other collection; link keeps them there too; an object must stay in at least one collection. The master 'Scene Collection' cannot be renamed, moved or hidden. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"collection\":\"Lamps\",\"properties\":{\"hide_render\":true},\"move\":[\"Lamp\"]}.",
        .params = common.mutating(&.{
            .{ .name = "collection", .type = .{ .name_ref = .{} }, .doc = "Collection to change", .required = true },
            .{ .name = "rename", .type = .{ .string = .{ .max_len = 255 } }, .doc = "New name" },
            .{ .name = "parent", .type = .{ .name_ref = .{} }, .doc = "New parent collection" },
            properties,
            .{ .name = "move", .type = .{ .string_list = .{} }, .doc = "Objects to move here from every other collection" },
            .{ .name = "link", .type = .{ .string_list = .{} }, .doc = "Objects to add, keeping their other collections" },
            .{ .name = "unlink", .type = .{ .string_list = .{} }, .doc = "Objects to remove from this collection" },
        }),
        .kind = .mutating,
        .handler = update,
    },
    .{
        .name = "collection.delete",
        .title = "Delete collections",
        .description = "Delete collections. Their objects and child collections pass to the parent collection; no object is deleted (object.delete does that). Example: {\"scene_id\":\"scn_1a2b3c4d\",\"collections\":[\"Table\"]}.",
        .params = common.mutating(&.{
            .{ .name = "collections", .type = .{ .string_list = .{} }, .doc = "Names of collections to delete", .required = true },
        }),
        .kind = .mutating,
        .destructive = true,
        .handler = delete,
    },
};

fn collectionError(c: *Call, e: core.edit.CollectionError, path: []const u8) HandlerError {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.ParentCycle => c.failAt(.invalid_operation, path, "pick a parent outside this collection's own subtree", &.{}, "a collection cannot be nested inside itself or its own child", .{}),
        error.MasterCollection => c.failAt(.invalid_operation, path, "the master 'Scene Collection' is the root of the tree; change a child collection instead", &.{}, "the master collection cannot be renamed, moved, hidden or deleted", .{}),
        error.LastCollection => c.failAt(.invalid_operation, path, "link the object into another collection first, or delete it with object.delete", &.{}, "unlinking would leave the object in no collection", .{}),
        error.StaleHandle => c.fail(.stale_handle, "a collection or object vanished", .{}),
    };
}

/// Resolves a list of object names, so a bad name fails before any change.
fn objectList(c: *Call, arg: []const u8) HandlerError![]IdHandle {
    const names = c.args.strings(arg);
    const out = try c.arena.alloc(IdHandle, names.len);
    for (names, out, 0..) |n, *h, i| h.* = try c.lookup(.object, n.string, try std.fmt.allocPrint(c.arena, "/{s}/{d}", .{ arg, i }));
    return out;
}

fn markObjects(c: *Call, objects: []const IdHandle) HandlerError!void {
    for (objects) |ob| try c.markChanged(ob, c.doc().db.get(.object, ob).?.name.slice());
}

fn markParent(c: *Call, h: IdHandle) HandlerError!void {
    const db = &c.doc().db;
    if (core.edit.collectionParent(db, h)) |p| try c.markChanged(p, db.get(.collection, p).?.name.slice());
}

fn create(c: *Call) HandlerError!void {
    const doc = c.doc();
    const parent: ?IdHandle = if (c.args.str("parent")) |p| try c.lookup(.collection, p, "/parent") else null;
    const objects = try objectList(c, "objects");
    const h = core.edit.createCollection(doc, c.args.str("name").?, parent) catch |e| return collectionError(c, e, "/parent");
    if (c.args.value("properties")) |p| _ = try common.setProperties(c, core.types.Collection, doc.db.get(.collection, h).?, p, "properties");
    for (objects, 0..) |ob, i| {
        core.edit.moveObject(doc, h, ob) catch |e| return collectionError(c, e, try std.fmt.allocPrint(c.arena, "/objects/{d}", .{i}));
    }
    const name = doc.db.get(.collection, h).?.name.slice();
    try c.markCreated(h, name);
    try markParent(c, h);
    try markObjects(c, objects);
    try c.field("collection");
    try common.writeCollectionSummary(c, &c.out, h);
    try c.say("Created collection '{s}' with {d} object(s).", .{ name, objects.len });
}

fn update(c: *Call) HandlerError!void {
    const doc = c.doc();
    const h = try c.lookup(.collection, c.args.str("collection").?, "/collection");
    const master = core.edit.isMasterCollection(doc, h);
    const new_parent: ?IdHandle = if (c.args.str("parent")) |p| try c.lookup(.collection, p, "/parent") else null;
    const move = try objectList(c, "move");
    const link = try objectList(c, "link");
    const unlink = try objectList(c, "unlink");
    var n: usize = 0;

    if (c.args.str("rename")) |want| {
        if (master) return collectionError(c, error.MasterCollection, "/rename");
        const got = doc.db.rename(.collection, h, want).?;
        if (!got.eql(want)) try c.warn("name '{s}' was taken; renamed to '{s}'", .{ want, got.slice() });
        n += 1;
    }
    if (new_parent) |p| {
        try markParent(c, h);
        core.edit.setCollectionParent(doc, h, p) catch |e| return collectionError(c, e, "/parent");
        try markParent(c, h);
        n += 1;
    }
    if (c.args.value("properties")) |p| {
        if (master) return collectionError(c, error.MasterCollection, "/properties");
        n += try common.setProperties(c, core.types.Collection, doc.db.get(.collection, h).?, p, "properties");
    }
    for (move, 0..) |ob, i| {
        core.edit.moveObject(doc, h, ob) catch |e| return collectionError(c, e, try std.fmt.allocPrint(c.arena, "/move/{d}", .{i}));
    }
    for (link) |ob| core.edit.linkTo(doc, h, ob) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return c.fail(.stale_handle, "a collection or object vanished", .{}),
    };
    for (unlink, 0..) |ob, i| {
        core.edit.unlinkObject(doc, h, ob) catch |e| return collectionError(c, e, try std.fmt.allocPrint(c.arena, "/unlink/{d}", .{i}));
    }
    n += move.len + link.len + unlink.len;
    if (n == 0) try c.warn("nothing to change; pass rename, parent, properties, move, link or unlink", .{});

    const name = doc.db.get(.collection, h).?.name.slice();
    try c.markChanged(h, name);
    try markObjects(c, move);
    try markObjects(c, link);
    try markObjects(c, unlink);
    try c.field("collection");
    try common.writeCollectionSummary(c, &c.out, h);
    try c.say("Updated collection '{s}': {d} change(s).", .{ name, n });
}

fn delete(c: *Call) HandlerError!void {
    const doc = c.doc();
    const names = c.args.strings("collections");
    const handles = try c.arena.alloc(IdHandle, names.len);
    for (names, handles, 0..) |n, *h, i| h.* = try c.lookup(.collection, n.string, try std.fmt.allocPrint(c.arena, "/collections/{d}", .{i}));
    var deleted: usize = 0;
    for (handles, 0..) |h, i| {
        const coll = doc.db.get(.collection, h) orelse continue; // listed twice
        const name = try c.arena.dupe(u8, coll.name.slice());
        try markParent(c, h);
        core.edit.deleteCollection(doc, h) catch |e| return collectionError(c, e, try std.fmt.allocPrint(c.arena, "/collections/{d}", .{i}));
        try c.markChanged(h, name);
        deleted += 1;
    }
    try c.field("deleted");
    try c.out.write(deleted);
    try c.say("Deleted {d} collection(s); their contents moved to the parent.", .{deleted});
}
