//! Object-level scene edits that keep references consistent: linking into
//! collections and managing their tree, deleting with reference cleanup,
//! parenting without cycles, duplication. Callers run these inside a
//! Transaction.

const std = @import("std");
const math = @import("math");
const ids = @import("ids.zig");
const types = @import("types.zig");
const Database = @import("database.zig").Database;
const Document = @import("document.zig").Document;
const Shared = @import("shared.zig").Shared;

const Allocator = std.mem.Allocator;
const IdHandle = ids.IdHandle;
const v = math.vec;

pub const EditError = Allocator.Error || error{ StaleHandle, ParentCycle, WrongType };

/// Creates an object (and links it into the scene's master collection).
pub fn addObject(doc: *Document, name: []const u8, kind: types.ObjectKind, data: ?IdHandle) EditError!IdHandle {
    const ob = try doc.db.create(.object, name, .{ .kind = kind, .data = data });
    try link(doc, ob);
    return ob;
}

/// Links `ob` into the scene's master collection.
pub fn link(doc: *Document, ob: IdHandle) EditError!void {
    const coll_h = doc.sceneData().collection orelse return error.StaleHandle;
    return linkTo(doc, coll_h, ob);
}

/// Links `ob` into a collection; linking it twice is a no-op.
pub fn linkTo(doc: *Document, coll_h: IdHandle, ob: IdHandle) (Allocator.Error || error{StaleHandle})!void {
    const coll = doc.db.get(.collection, coll_h) orelse return error.StaleHandle;
    try appendUnique(doc.gpa, &coll.objects, ob);
}

fn contains(list: Shared(IdHandle), h: IdHandle) bool {
    for (list.slice()) |x| if (x.eql(h)) return true;
    return false;
}

/// Swaps in `items`, which must come from `gpa`, freeing them on failure.
fn replaceList(gpa: Allocator, list: *Shared(IdHandle), items: []IdHandle) Allocator.Error!void {
    errdefer gpa.free(items);
    const fresh = try Shared(IdHandle).fromOwned(gpa, items);
    list.release(gpa);
    list.* = fresh;
}

fn appendUnique(gpa: Allocator, list: *Shared(IdHandle), h: IdHandle) Allocator.Error!void {
    if (contains(list.*, h)) return;
    const old = list.slice();
    const items = try gpa.alloc(IdHandle, old.len + 1);
    @memcpy(items[0..old.len], old);
    items[old.len] = h;
    try replaceList(gpa, list, items);
}

fn removeFromList(gpa: Allocator, list: *Shared(IdHandle), h: IdHandle) Allocator.Error!void {
    if (!contains(list.*, h)) return;
    const old = list.slice();
    const items = try gpa.alloc(IdHandle, old.len - 1);
    var i: usize = 0;
    for (old) |x| if (!x.eql(h)) {
        items[i] = x;
        i += 1;
    };
    try replaceList(gpa, list, items);
}

/// An object in the scene and whether some chain of collections from the
/// master down leaves it visible. The object's own hide flags are not
/// applied here.
pub const Visibility = struct {
    handle: IdHandle,
    render: bool,
    viewport: bool,
};

/// Every object in the scene, from the master collection down, without
/// duplicates, in collection order. An object linked into several
/// collections is visible if any of them is, as in Blender.
pub fn sceneVisibility(doc: *Document, gpa: Allocator) Allocator.Error![]Visibility {
    var out: std.ArrayList(Visibility) = .empty;
    errdefer out.deinit(gpa);
    var seen: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer seen.deinit(gpa);
    const root = doc.sceneData().collection orelse return out.toOwnedSlice(gpa);
    try collectObjects(&doc.db, gpa, root, &out, &seen, false, false, 0);
    return out.toOwnedSlice(gpa);
}

/// Every object in the scene, as `sceneVisibility` orders them.
pub fn sceneObjects(doc: *Document, gpa: Allocator) Allocator.Error![]IdHandle {
    const vis = try sceneVisibility(doc, gpa);
    defer gpa.free(vis);
    const out = try gpa.alloc(IdHandle, vis.len);
    for (vis, out) |x, *h| h.* = x.handle;
    return out;
}

fn collectObjects(
    db: *Database,
    gpa: Allocator,
    coll_h: IdHandle,
    out: *std.ArrayList(Visibility),
    seen: *std.AutoHashMapUnmanaged(u32, u32),
    parent_hide_render: bool,
    parent_hide_viewport: bool,
    depth: u32,
) Allocator.Error!void {
    if (depth > 64) return;
    const coll = db.get(.collection, coll_h) orelse return;
    const hide_render = parent_hide_render or coll.hide_render;
    const hide_viewport = parent_hide_viewport or coll.hide_viewport;
    for (coll.objects.slice()) |h| {
        if (db.get(.object, h) == null) continue;
        const gop = try seen.getOrPut(gpa, h.index);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(out.items.len);
            try out.append(gpa, .{ .handle = h, .render = false, .viewport = false });
        }
        const x = &out.items[gop.value_ptr.*];
        x.render = x.render or !hide_render;
        x.viewport = x.viewport or !hide_viewport;
    }
    for (coll.children.slice()) |c| try collectObjects(db, gpa, c, out, seen, hide_render, hide_viewport, depth + 1);
}

// Collections form a tree under the scene's master collection: each other
// collection has exactly one parent. Blender allows a collection under
// several parents; P2's .blend reader will have to flatten that case.

pub const CollectionError = Allocator.Error || error{ StaleHandle, ParentCycle, MasterCollection, LastCollection };

pub fn isMasterCollection(doc: *Document, coll_h: IdHandle) bool {
    const m = doc.sceneData().collection orelse return false;
    return m.eql(coll_h);
}

/// The collection that holds `coll_h` as a child; null for the master.
pub fn collectionParent(db: *Database, coll_h: IdHandle) ?IdHandle {
    var it = db.collection.iterator();
    while (it.next()) |e| if (contains(e.value.children, coll_h)) return e.handle;
    return null;
}

/// How many collections `ob` is linked into.
pub fn collectionCount(db: *Database, ob: IdHandle) usize {
    var n: usize = 0;
    var it = db.collection.iterator();
    while (it.next()) |e| {
        if (contains(e.value.objects, ob)) n += 1;
    }
    return n;
}

/// Creates a collection as the last child of `parent`, or of the master
/// collection when null.
pub fn createCollection(doc: *Document, name: []const u8, parent: ?IdHandle) CollectionError!IdHandle {
    const p = parent orelse doc.sceneData().collection orelse return error.StaleHandle;
    if (doc.db.get(.collection, p) == null) return error.StaleHandle;
    const h = try doc.db.create(.collection, name, .{});
    // create may grow the pool, so look the parent up again.
    try appendUnique(doc.gpa, &doc.db.get(.collection, p).?.children, h);
    return h;
}

/// Moves `ob` into a collection and out of every other one (Blender's M).
pub fn moveObject(doc: *Document, coll_h: IdHandle, ob: IdHandle) CollectionError!void {
    if (doc.db.get(.object, ob) == null) return error.StaleHandle;
    try linkTo(doc, coll_h, ob);
    var it = doc.db.collection.iterator();
    while (it.next()) |e| if (!e.handle.eql(coll_h)) try removeFromList(doc.gpa, &e.value.objects, ob);
}

/// Unlinks `ob` from a collection. The last link cannot go: an object in
/// no collection drops out of the scene, which is what deleteObject is for.
pub fn unlinkObject(doc: *Document, coll_h: IdHandle, ob: IdHandle) CollectionError!void {
    const coll = doc.db.get(.collection, coll_h) orelse return error.StaleHandle;
    if (!contains(coll.objects, ob)) return;
    if (collectionCount(&doc.db, ob) <= 1) return error.LastCollection;
    try removeFromList(doc.gpa, &coll.objects, ob);
}

/// True when `h` is `root` or lies anywhere below it.
fn isWithin(db: *Database, h: IdHandle, root: IdHandle, depth: u32) bool {
    if (h.eql(root)) return true;
    if (depth > 64) return false;
    const coll = db.get(.collection, root) orelse return false;
    for (coll.children.slice()) |c| if (isWithin(db, h, c, depth + 1)) return true;
    return false;
}

/// Moves a collection, with everything below it, under `parent_h`.
pub fn setCollectionParent(doc: *Document, coll_h: IdHandle, parent_h: IdHandle) CollectionError!void {
    if (isMasterCollection(doc, coll_h)) return error.MasterCollection;
    const db = &doc.db;
    if (db.get(.collection, coll_h) == null or db.get(.collection, parent_h) == null) return error.StaleHandle;
    if (isWithin(db, parent_h, coll_h, 0)) return error.ParentCycle;
    if (collectionParent(db, coll_h)) |old| {
        if (old.eql(parent_h)) return;
        try removeFromList(doc.gpa, &db.get(.collection, old).?.children, coll_h);
    }
    try appendUnique(doc.gpa, &db.get(.collection, parent_h).?.children, coll_h);
}

/// Deletes a collection, as Blender's "Delete" does: its objects are linked
/// into its parent and its child collections take its place there.
pub fn deleteCollection(doc: *Document, coll_h: IdHandle) CollectionError!void {
    if (isMasterCollection(doc, coll_h)) return error.MasterCollection;
    const db = &doc.db;
    const coll = db.get(.collection, coll_h) orelse return error.StaleHandle;
    const parent_h = collectionParent(db, coll_h) orelse doc.sceneData().collection orelse return error.StaleHandle;
    const parent = db.get(.collection, parent_h).?;
    for (coll.objects.slice()) |ob| try appendUnique(doc.gpa, &parent.objects, ob);

    const old = parent.children.slice();
    const moved = coll.children.slice();
    var items: std.ArrayList(IdHandle) = .empty;
    errdefer items.deinit(doc.gpa);
    try items.ensureTotalCapacity(doc.gpa, old.len + moved.len);
    for (old) |c| {
        if (c.eql(coll_h)) {
            for (moved) |m| if (!contains(parent.children, m)) items.appendAssumeCapacity(m);
        } else items.appendAssumeCapacity(c);
    }
    try replaceList(doc.gpa, &parent.children, try items.toOwnedSlice(doc.gpa));
    _ = db.remove(.collection, coll_h);
}

pub fn worldMatrix(db: *Database, ob_h: IdHandle) Allocator.Error!math.Mat4 {
    var m = v.identity;
    var h: ?IdHandle = ob_h;
    var depth: u32 = 0;
    while (h) |cur| : (depth += 1) {
        const ob = db.get(.object, cur) orelse break;
        if (depth > 1024) break; // cycles are rejected by setParent
        m = v.matMul(ob.localMatrix(), m);
        h = ob.parent;
    }
    return m;
}

/// Deletes an object: unlinks it from every collection, clears it as the
/// active camera, and unparents its children keeping their world transform.
/// Object data stays, as in Blender, until saved without users.
pub fn deleteObject(doc: *Document, ob_h: IdHandle) EditError!void {
    if (doc.db.get(.object, ob_h) == null) return error.StaleHandle;
    var cit = doc.db.collection.iterator();
    while (cit.next()) |e| try removeFromList(doc.gpa, &e.value.objects, ob_h);
    const scene = doc.sceneData();
    if (scene.camera) |c| if (c.eql(ob_h)) {
        scene.camera = null;
    };
    var oit = doc.db.object.iterator();
    while (oit.next()) |e| {
        if (e.value.parent) |p| if (p.eql(ob_h)) {
            const world = try worldMatrix(&doc.db, e.handle);
            e.value.parent = null;
            e.value.parent_inverse = v.identity;
            setFromMatrix(e.value, world);
        };
    }
    _ = doc.db.remove(.object, ob_h);
}

/// Writes a matrix into location / rotation / scale, keeping the rotation mode.
pub fn setFromMatrix(ob: *types.Object, m: math.Mat4) void {
    const d = v.decompose(m);
    ob.location = d.t;
    ob.scale = d.s;
    ob.rotation_quaternion = d.r;
    if (ob.rotation_mode != .quaternion) {
        // Only XYZ has an exact inverse here; other orders switch to XYZ.
        ob.rotation_mode = .xyz;
        ob.rotation_euler = v.quatToEulerXyz(d.r);
    }
}

/// Parents `child` to `parent` (null clears). With `keep_transform`, the
/// child's world transform is unchanged, using a parent inverse matrix the
/// way Blender's "Object (Keep Transform)" does.
pub fn setParent(doc: *Document, child_h: IdHandle, parent_h: ?IdHandle, keep_transform: bool) EditError!void {
    const db = &doc.db;
    if (db.get(.object, child_h) == null) return error.StaleHandle;
    if (parent_h) |p| {
        if (db.get(.object, p) == null) return error.StaleHandle;
        var cur: ?IdHandle = p;
        var depth: u32 = 0;
        while (cur) |c| : (depth += 1) {
            if (c.eql(child_h) or depth > 1024) return error.ParentCycle;
            cur = db.get(.object, c).?.parent;
        }
    }
    const world = try worldMatrix(db, child_h);
    const child = db.get(.object, child_h).?;
    child.parent = parent_h;
    child.parent_inverse = v.identity;
    if (!keep_transform) return;
    if (parent_h) |p| {
        const pw = try worldMatrix(db, p);
        child.parent_inverse = v.invert(pw) orelse v.identity;
        // world = parent_world · parent_inverse · local  ⇒  local = old world.
        setFromMatrix(child, world);
    } else {
        setFromMatrix(child, world);
    }
}

/// Duplicates an object. With `linked`, the copy shares the data block
/// (Blender's Alt+D); otherwise the data is copied (Shift+D), mesh buffers
/// staying shared until either side writes them.
pub fn duplicateObject(doc: *Document, ob_h: IdHandle, name: []const u8, linked: bool) EditError!IdHandle {
    const src = (doc.db.get(.object, ob_h) orelse return error.StaleHandle).*;
    var data = src.data;
    if (!linked) if (src.data) |d| {
        data = switch (src.kind) {
            .mesh => blk: {
                var m = doc.db.get(.mesh, d).?.*;
                m.retainRefs();
                break :blk try doc.db.create(.mesh, m.name.slice(), m);
            },
            .camera => try doc.db.create(.camera, doc.db.get(.camera, d).?.name.slice(), doc.db.get(.camera, d).?.*),
            .light => try doc.db.create(.light, doc.db.get(.light, d).?.name.slice(), doc.db.get(.light, d).?.*),
            .curve => blk: {
                var cu = doc.db.get(.curve, d).?.*;
                cu.retainRefs();
                break :blk try doc.db.create(.curve, cu.name.slice(), cu);
            },
            .empty => null,
        };
    };
    var copy = src;
    copy.data = data;
    copy.modifiers = src.modifiers.retain();
    errdefer copy.modifiers.release(doc.gpa);
    const h = try doc.db.create(.object, name, copy);
    // The copy joins the source's collections, as in Blender.
    var linked_any = false;
    var it = doc.db.collection.iterator();
    while (it.next()) |e| if (contains(e.value.objects, ob_h)) {
        try appendUnique(doc.gpa, &e.value.objects, h);
        linked_any = true;
    };
    if (!linked_any) try link(doc, h);
    return h;
}

/// Assigns `material` to slot `slot` of the object's mesh, growing the slot
/// list as needed.
pub fn assignMaterial(doc: *Document, ob_h: IdHandle, material: ?IdHandle, slot: usize) EditError!void {
    const ob = doc.db.get(.object, ob_h) orelse return error.StaleHandle;
    const d = ob.data orelse return error.StaleHandle;
    const list = switch (ob.kind) {
        .mesh => &(doc.db.get(.mesh, d) orelse return error.StaleHandle).materials,
        .curve => &(doc.db.get(.curve, d) orelse return error.StaleHandle).materials,
        else => return error.WrongType,
    };
    const old = list.slice();
    const n = @max(old.len, slot + 1);
    const items = try doc.gpa.alloc(?IdHandle, n);
    @memcpy(items[0..old.len], old);
    @memset(items[old.len..], null);
    items[slot] = material;
    list.release(doc.gpa);
    list.* = try .fromOwned(doc.gpa, items);
}

/// Moves faces (sorted indices) of a mesh object to material slot `slot`
/// through the face attribute `material_index`, created at 0 if missing.
pub fn setFaceMaterial(doc: *Document, ob_h: IdHandle, faces: []const u32, slot: i32) (EditError || error{TooManyAttributes})!void {
    const ob = doc.db.get(.object, ob_h) orelse return error.StaleHandle;
    if (ob.kind != .mesh) return error.WrongType;
    const mesh = doc.db.get(.mesh, ob.data orelse return error.StaleHandle) orelse return error.StaleHandle;
    const items = try doc.gpa.alloc(i32, mesh.faceCount());
    @memset(items, 0);
    if (mesh.attribute("material_index")) |a| {
        if (a.domain == .face and a.data == .int) @memcpy(items, a.data.int.slice());
    }
    for (faces) |f| items[f] = slot;
    // fromOwned takes items; setAttribute releases them if it fails.
    try mesh.setAttribute(doc.gpa, "material_index", .face, .{ .int = try .fromOwned(doc.gpa, items) });
}

/// Number of objects whose data is `h`.
pub fn userCount(db: *Database, h: IdHandle) u32 {
    var n: u32 = 0;
    var it = db.object.iterator();
    while (it.next()) |e| {
        if (e.value.data) |d| if (d.eql(h)) {
            n += 1;
        };
    }
    return n;
}

const testing = std.testing;
const Transaction = @import("document.zig").Transaction;

test "parenting keeps world transform and rejects cycles" {
    var doc = try Document.initEmpty(testing.allocator, "Scene");
    defer doc.deinit();
    const a = try addObject(&doc, "A", .empty, null);
    const b = try addObject(&doc, "B", .empty, null);
    doc.db.get(.object, a).?.location = .{ 1, 2, 3 };
    doc.db.get(.object, a).?.rotation_euler = .{ 0, 0, std.math.pi / 2.0 };
    doc.db.get(.object, b).?.location = .{ 5, 0, 0 };
    const before = try worldMatrix(&doc.db, b);
    try setParent(&doc, b, a, true);
    const after = try worldMatrix(&doc.db, b);
    for (before, after) |x, y| try testing.expectApproxEqAbs(x, y, 1e-5);
    try testing.expectError(error.ParentCycle, setParent(&doc, a, b, true));
    // Deleting the parent keeps the child where it was.
    try deleteObject(&doc, a);
    const orphan = try worldMatrix(&doc.db, b);
    for (before, orphan) |x, y| try testing.expectApproxEqAbs(x, y, 1e-5);
    try testing.expect(doc.db.get(.object, b).?.parent == null);
}

test "duplicate copies or links data" {
    const gpa = testing.allocator;
    var doc = try Document.initEmpty(gpa, "Scene");
    defer doc.deinit();
    const cam = try doc.db.create(.camera, "Camera", .{});
    const ob = try addObject(&doc, "Camera", .camera, cam);
    const linked = try duplicateObject(&doc, ob, "Camera", true);
    const copied = try duplicateObject(&doc, ob, "Camera", false);
    try testing.expectEqualStrings("Camera.001", doc.db.get(.object, linked).?.name.slice());
    try testing.expect(doc.db.get(.object, linked).?.data.?.eql(cam));
    try testing.expect(!doc.db.get(.object, copied).?.data.?.eql(cam));
    try testing.expectEqual(@as(u32, 2), userCount(&doc.db, cam));
    const objs = try sceneObjects(&doc, gpa);
    defer gpa.free(objs);
    try testing.expectEqual(@as(usize, 3), objs.len);
}

test "collections nest, move objects and hand contents up on delete" {
    const gpa = testing.allocator;
    var doc = try Document.initEmpty(gpa, "Scene");
    defer doc.deinit();
    const master = doc.sceneData().collection.?;
    const a = try addObject(&doc, "A", .empty, null);
    const b = try addObject(&doc, "B", .empty, null);
    const table = try createCollection(&doc, "Table", null);
    const legs = try createCollection(&doc, "Legs", table);
    try testing.expect(collectionParent(&doc.db, legs).?.eql(table));
    try testing.expect(collectionParent(&doc.db, table).?.eql(master));
    try testing.expect(collectionParent(&doc.db, master) == null);

    try moveObject(&doc, legs, a);
    try testing.expectEqual(@as(usize, 1), collectionCount(&doc.db, a));
    try testing.expectError(error.LastCollection, unlinkObject(&doc, legs, a));
    try linkTo(&doc, table, a);
    try unlinkObject(&doc, legs, a);
    try testing.expectEqual(@as(usize, 1), collectionCount(&doc.db, a));

    try testing.expectError(error.ParentCycle, setCollectionParent(&doc, table, legs));
    try testing.expectError(error.ParentCycle, setCollectionParent(&doc, table, table));
    try testing.expectError(error.MasterCollection, setCollectionParent(&doc, master, table));
    try testing.expectError(error.MasterCollection, deleteCollection(&doc, master));

    // Deleting Table hands A to the master and Legs takes Table's place.
    try moveObject(&doc, legs, b);
    {
        var tx = try Transaction.begin(&doc);
        defer tx.end();
        try deleteCollection(&doc, table);
        try tx.commit("delete collection");
    }
    try testing.expect(doc.db.get(.collection, table) == null);
    try testing.expect(collectionParent(&doc.db, legs).?.eql(master));
    try testing.expect(contains(doc.db.get(.collection, master).?.objects, a));
    const objs = try sceneObjects(&doc, gpa);
    defer gpa.free(objs);
    try testing.expectEqual(@as(usize, 2), objs.len);

    // Undo restores the collection, its place and its links.
    var buf: [64]u8 = undefined;
    _ = try doc.undo(&buf);
    try testing.expect(collectionParent(&doc.db, legs).?.eql(table));
    try testing.expect(contains(doc.db.get(.collection, table).?.objects, a));
    try testing.expect(!contains(doc.db.get(.collection, master).?.objects, a));
}

test "hidden collections hide objects unless another link shows them" {
    const gpa = testing.allocator;
    var doc = try Document.initEmpty(gpa, "Scene");
    defer doc.deinit();
    const a = try addObject(&doc, "A", .empty, null);
    const b = try addObject(&doc, "B", .empty, null);
    const props = try createCollection(&doc, "Props", null);
    const inner = try createCollection(&doc, "Inner", props);
    try moveObject(&doc, inner, a);
    try moveObject(&doc, props, b);
    doc.db.get(.collection, props).?.hide_render = true;
    doc.db.get(.collection, inner).?.hide_viewport = true;
    {
        const vis = try sceneVisibility(&doc, gpa);
        defer gpa.free(vis);
        try testing.expectEqual(@as(usize, 2), vis.len);
        for (vis) |x| {
            try testing.expect(!x.render); // Props hides both, Inner included
            try testing.expectEqual(!x.handle.eql(a), x.viewport);
        }
    }
    try linkTo(&doc, doc.sceneData().collection.?, a);
    const vis = try sceneVisibility(&doc, gpa);
    defer gpa.free(vis);
    for (vis) |x| if (x.handle.eql(a)) {
        try testing.expect(x.render and x.viewport);
    };

    // Duplicates join the source's collections.
    const c = try duplicateObject(&doc, b, "B", false);
    try testing.expect(contains(doc.db.get(.collection, props).?.objects, c));
    try testing.expectEqual(@as(usize, 1), collectionCount(&doc.db, c));
}
