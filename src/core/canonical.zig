//! Canonical scene description, scene.json (FR-DM-8): the database as JSON
//! that is byte-identical for equal content, whatever order datablocks were
//! created or deleted in, for diffing, golden tests and inspection.
//!
//! Datablocks are grouped by type and sorted by name (names are unique per
//! type), and refer to each other by name, never by handle. Lists whose
//! order means something (a collection's children and objects, material
//! slots) keep it. Values are in stored units, metres and radians, with
//! shortest round-trip floats. Mesh arrays appear as counts and XxHash64
//! digests of their little-endian bytes, or in full with `geometry = .full`.

const std = @import("std");
const math = @import("math");
const ids = @import("ids.zig");
const types = @import("types.zig");
const registry = @import("registry.zig");
const Document = @import("document.zig").Document;
const Database = @import("database.zig").Database;

const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const IdHandle = ids.IdHandle;

pub const format_version = 1;

pub const Options = struct {
    geometry: enum { hash, full } = .hash,
};

pub const Error = Allocator.Error || Stringify.Error;

comptime {
    // Digests hash the in-memory bytes, which must be the same everywhere.
    std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
}

/// XxHash64 (seed 0) of a slice's bytes.
pub fn digest(slice: anytype) u64 {
    return std.hash.XxHash64.hash(0, std.mem.sliceAsBytes(slice));
}

/// One digest over a mesh's connectivity: edges, face offsets, corner
/// vertices and corner edges. Integers only, so it is the same on every
/// platform, unlike float attributes, whose last bits can depend on libm.
pub fn topologyDigest(m: *const types.Mesh) u64 {
    var h = std.hash.XxHash64.init(0);
    h.update(std.mem.sliceAsBytes(m.edges.slice()));
    h.update(std.mem.sliceAsBytes(m.face_offsets.slice()));
    h.update(std.mem.sliceAsBytes(m.corner_verts.slice()));
    h.update(std.mem.sliceAsBytes(m.corner_edges.slice()));
    return h.final();
}

pub fn write(arena: Allocator, doc: *Document, w: *Stringify, opts: Options) Error!void {
    const db = &doc.db;
    const scene = doc.sceneData();
    try w.beginObject();
    try w.objectField("format");
    try w.write("zender.scene");
    try w.objectField("version");
    try w.write(format_version);
    try w.objectField("units");
    try w.beginObject();
    try w.objectField("length");
    try w.write("m");
    try w.objectField("angle");
    try w.write("rad");
    try w.objectField("up");
    try w.write("+Z");
    try w.objectField("color");
    try w.write("scene-linear Rec.709");
    try w.endObject();

    try w.objectField("scene");
    try w.beginObject();
    try w.objectField("name");
    try w.write(scene.name.slice());
    try w.objectField("camera");
    try writeRef(w, db, .object, scene.camera);
    try w.objectField("world");
    try writeRef(w, db, .world, scene.world);
    try w.objectField("collection");
    try writeRef(w, db, .collection, scene.collection);
    try w.objectField("properties");
    try registry.writeStoredValues(types.Scene, scene, w);
    try w.endObject();

    try w.objectField("collections");
    try w.beginArray();
    for (try sorted(arena, db, .collection)) |h| {
        const c = db.get(.collection, h).?;
        try w.beginObject();
        try w.objectField("name");
        try w.write(c.name.slice());
        try w.objectField("children");
        try writeRefList(w, db, .collection, c.children.slice());
        try w.objectField("objects");
        try writeRefList(w, db, .object, c.objects.slice());
        try w.objectField("properties");
        try registry.writeStoredValues(types.Collection, c, w);
        try w.endObject();
    }
    try w.endArray();

    try w.objectField("objects");
    try w.beginArray();
    for (try sorted(arena, db, .object)) |h| {
        const ob = db.get(.object, h).?;
        try w.beginObject();
        try w.objectField("name");
        try w.write(ob.name.slice());
        try w.objectField("data");
        switch (ob.kind) {
            .mesh => try writeRef(w, db, .mesh, ob.data),
            .camera => try writeRef(w, db, .camera, ob.data),
            .light => try writeRef(w, db, .light, ob.data),
            .empty => try w.write(null),
        }
        try w.objectField("parent");
        try writeRef(w, db, .object, ob.parent);
        if (!std.meta.eql(ob.parent_inverse, math.vec.identity)) {
            try w.objectField("parent_inverse");
            try w.beginArray();
            for (ob.parent_inverse) |x| try registry.writeF32(w, x);
            try w.endArray();
        }
        try w.objectField("properties");
        try registry.writeStoredValues(types.Object, ob, w);
        const mods = ob.modifiers.slice();
        if (mods.len > 0) {
            // Stack order is evaluation order, so it is kept as is.
            try w.objectField("modifiers");
            try w.beginArray();
            for (mods) |*m| {
                try w.beginObject();
                try w.objectField("name");
                try w.write(m.name.slice());
                try w.objectField("type");
                try w.write(@tagName(m.kind));
                try w.objectField("target");
                try writeRef(w, db, .object, m.target);
                try w.objectField("properties");
                try registry.writeStoredValues(types.Modifier, m, w);
                try w.endObject();
            }
            try w.endArray();
        }
        try w.endObject();
    }
    try w.endArray();

    try w.objectField("meshes");
    try w.beginArray();
    for (try sorted(arena, db, .mesh)) |h| try writeMesh(arena, w, db, db.get(.mesh, h).?, opts);
    try w.endArray();

    try writeSimple(arena, w, db, .camera, "cameras");
    try writeSimple(arena, w, db, .light, "lights");
    try writeSimple(arena, w, db, .material, "materials");
    try writeSimple(arena, w, db, .world, "worlds");
    try w.endObject();
}

/// Handles of every live datablock of type `t`, sorted by name.
fn sorted(arena: Allocator, db: *Database, comptime t: ids.IdType) Allocator.Error![]IdHandle {
    var list: std.ArrayList(IdHandle) = .empty;
    var it = db.pool(t).iterator();
    while (it.next()) |e| try list.append(arena, e.handle);
    const Ctx = struct {
        db: *Database,
        fn less(c: @This(), a: IdHandle, b: IdHandle) bool {
            return std.mem.lessThan(u8, c.db.get(t, a).?.name.slice(), c.db.get(t, b).?.name.slice());
        }
    };
    std.mem.sort(IdHandle, list.items, Ctx{ .db = db }, Ctx.less);
    return list.items;
}

fn writeRef(w: *Stringify, db: *Database, comptime t: ids.IdType, h: ?IdHandle) Stringify.Error!void {
    if (h) |x| if (db.get(t, x)) |d| return w.write(d.name.slice());
    try w.write(null);
}

fn writeRefList(w: *Stringify, db: *Database, comptime t: ids.IdType, list: []const IdHandle) Stringify.Error!void {
    try w.beginArray();
    for (list) |h| if (db.get(t, h)) |d| try w.write(d.name.slice());
    try w.endArray();
}

fn writeSimple(arena: Allocator, w: *Stringify, db: *Database, comptime t: ids.IdType, field: []const u8) Error!void {
    try w.objectField(field);
    try w.beginArray();
    for (try sorted(arena, db, t)) |h| {
        const d = db.get(t, h).?;
        try w.beginObject();
        try w.objectField("name");
        try w.write(d.name.slice());
        try w.objectField("properties");
        try registry.writeStoredValues(types.TypeOf(t), d, w);
        try w.endObject();
    }
    try w.endArray();
}

fn writeHex(w: *Stringify, x: u64) Stringify.Error!void {
    try w.print("\"{x:0>16}\"", .{x});
}

fn writeFloats(w: *Stringify, items: anytype) Stringify.Error!void {
    try w.beginArray();
    for (items) |x| {
        if (@TypeOf(x) == f32) {
            try registry.writeF32(w, x);
        } else {
            try w.beginArray();
            for (x) |c| try registry.writeF32(w, c);
            try w.endArray();
        }
    }
    try w.endArray();
}

fn writeMesh(arena: Allocator, w: *Stringify, db: *Database, m: *const types.Mesh, opts: Options) Error!void {
    try w.beginObject();
    try w.objectField("name");
    try w.write(m.name.slice());
    try w.objectField("materials");
    try w.beginArray();
    for (m.materials.slice()) |slot| try writeRef(w, db, .material, slot);
    try w.endArray();
    try w.objectField("points");
    try w.write(m.vertCount());
    try w.objectField("edges");
    try w.write(m.edgeCount());
    try w.objectField("faces");
    try w.write(m.faceCount());
    try w.objectField("corners");
    try w.write(m.cornerCount());
    try w.objectField("topology");
    try writeHex(w, topologyDigest(m));
    if (opts.geometry == .full) {
        try w.objectField("edge_verts");
        try w.write(m.edges.slice());
        try w.objectField("face_offsets");
        try w.write(m.face_offsets.slice());
        try w.objectField("corner_verts");
        try w.write(m.corner_verts.slice());
        try w.objectField("corner_edges");
        try w.write(m.corner_edges.slice());
    }

    // "position" sorts with the generic attributes, as in Blender's API.
    const Attr = struct { name: []const u8, domain: types.Domain, data: types.AttrData };
    var attrs: std.ArrayList(Attr) = .empty;
    try attrs.append(arena, .{ .name = "position", .domain = .point, .data = .{ .float3 = m.positions } });
    for (m.attrs[0..m.attr_count]) |*a| try attrs.append(arena, .{ .name = a.name.slice(), .domain = a.domain, .data = a.data });
    std.mem.sort(Attr, attrs.items, {}, struct {
        fn less(_: void, a: Attr, b: Attr) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    try w.objectField("attributes");
    try w.beginArray();
    for (attrs.items) |a| {
        try w.beginObject();
        try w.objectField("name");
        try w.write(a.name);
        try w.objectField("domain");
        try w.write(@tagName(a.domain));
        try w.objectField("type");
        try w.write(@tagName(a.data));
        try w.objectField(if (opts.geometry == .full) "data" else "digest");
        switch (a.data) {
            inline .float, .float2, .float3, .color => |s| if (opts.geometry == .full) try writeFloats(w, s.slice()) else try writeHex(w, digest(s.slice())),
            inline .int, .boolean => |s| if (opts.geometry == .full) try w.write(s.slice()) else try writeHex(w, digest(s.slice())),
        }
        try w.endObject();
    }
    try w.endArray();
    try w.endObject();
}

const testing = std.testing;
const edit = @import("edit.zig");

fn dump(arena: Allocator, doc: *Document, opts: Options) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var w: Stringify = .{ .writer = &out.writer };
    try write(arena, doc, &w, opts);
    return out.written();
}

test "scene.json does not depend on creation order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var a = try Document.initEmpty(testing.allocator, "Scene");
    defer a.deinit();
    var b = try Document.initEmpty(testing.allocator, "Scene");
    defer b.deinit();
    // Same content, created in opposite orders, with a deleted object in b.
    _ = try edit.addObject(&a, "Alpha", .empty, null);
    _ = try edit.addObject(&a, "Beta", .empty, null);
    const junk = try edit.addObject(&b, "Junk", .empty, null);
    try edit.deleteObject(&b, junk);
    _ = try edit.addObject(&b, "Beta", .empty, null);
    _ = try edit.addObject(&b, "Alpha", .empty, null);
    // Collection membership order is meaningful, so match it.
    const coll_a = a.db.get(.collection, a.sceneData().collection.?).?;
    const coll_b = b.db.get(.collection, b.sceneData().collection.?).?;
    try coll_b.objects.set(testing.allocator, &.{ coll_b.objects.slice()[1], coll_b.objects.slice()[0] });
    try testing.expectEqualStrings(a.db.get(.object, coll_a.objects.slice()[0]).?.name.slice(), b.db.get(.object, coll_b.objects.slice()[0]).?.name.slice());
    try testing.expectEqualStrings(try dump(arena, &a, .{}), try dump(arena, &b, .{}));
}

test "mesh digests and full geometry" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var doc = try Document.initEmpty(testing.allocator, "Scene");
    defer doc.deinit();
    const geom = @import("../geom/root.zig");
    const mesh = try doc.db.create(.mesh, "Cube", try geom.primitives.generate(testing.allocator, .cube, .{}));
    _ = try edit.addObject(&doc, "Cube", .mesh, mesh);
    const hashed = try std.json.parseFromSliceLeaky(std.json.Value, arena, try dump(arena, &doc, .{}), .{});
    const m = hashed.object.get("meshes").?.array.items[0].object;
    try testing.expectEqual(@as(i64, 8), m.get("points").?.integer);
    try testing.expectEqual(@as(i64, 24), m.get("corners").?.integer);
    try testing.expectEqual(@as(usize, 16), m.get("topology").?.string.len);
    const full = try std.json.parseFromSliceLeaky(std.json.Value, arena, try dump(arena, &doc, .{ .geometry = .full }), .{});
    const fm = full.object.get("meshes").?.array.items[0].object;
    try testing.expectEqual(@as(usize, 24), fm.get("corner_verts").?.array.items.len);
    for (fm.get("attributes").?.array.items) |a| if (std.mem.eql(u8, a.object.get("name").?.string, "position")) {
        try testing.expectEqual(@as(usize, 8), a.object.get("data").?.array.items.len);
    };
}
