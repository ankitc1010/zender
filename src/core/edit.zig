//! Object-level scene edits that keep references consistent: linking into
//! collections, deleting with reference cleanup, parenting without cycles,
//! duplication. Callers run these inside a Transaction.

const std = @import("std");
const math = @import("math");
const ids = @import("ids.zig");
const types = @import("types.zig");
const Database = @import("database.zig").Database;
const Document = @import("document.zig").Document;

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

pub fn link(doc: *Document, ob: IdHandle) EditError!void {
    const coll_h = doc.sceneData().collection orelse return error.StaleHandle;
    const coll = doc.db.get(.collection, coll_h) orelse return error.StaleHandle;
    for (coll.objects.slice()) |h| if (h.eql(ob)) return;
    const old = coll.objects.slice();
    const items = try doc.gpa.alloc(IdHandle, old.len + 1);
    @memcpy(items[0..old.len], old);
    items[old.len] = ob;
    coll.objects.release(doc.gpa);
    coll.objects = try .fromOwned(doc.gpa, items);
}

fn removeFromList(gpa: Allocator, list: anytype, h: IdHandle) Allocator.Error!void {
    const old = list.slice();
    var n: usize = 0;
    for (old) |x| if (!x.eql(h)) {
        n += 1;
    };
    if (n == old.len) return;
    const items = try gpa.alloc(IdHandle, n);
    var i: usize = 0;
    for (old) |x| if (!x.eql(h)) {
        items[i] = x;
        i += 1;
    };
    list.release(gpa);
    list.* = try .fromOwned(gpa, items);
}

/// Every object in the scene, from the master collection down, without
/// duplicates, in collection order.
pub fn sceneObjects(doc: *Document, gpa: Allocator) Allocator.Error![]IdHandle {
    var out: std.ArrayList(IdHandle) = .empty;
    errdefer out.deinit(gpa);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(gpa);
    const root = doc.sceneData().collection orelse return out.toOwnedSlice(gpa);
    try collectObjects(&doc.db, gpa, root, &out, &seen, 0);
    return out.toOwnedSlice(gpa);
}

fn collectObjects(db: *Database, gpa: Allocator, coll_h: IdHandle, out: *std.ArrayList(IdHandle), seen: *std.AutoHashMapUnmanaged(u32, void), depth: u32) Allocator.Error!void {
    if (depth > 64) return;
    const coll = db.get(.collection, coll_h) orelse return;
    for (coll.objects.slice()) |h| {
        if (db.get(.object, h) == null) continue;
        const gop = try seen.getOrPut(gpa, h.index);
        if (!gop.found_existing) try out.append(gpa, h);
    }
    for (coll.children.slice()) |c| try collectObjects(db, gpa, c, out, seen, depth + 1);
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
            .empty => null,
        };
    };
    var copy = src;
    copy.data = data;
    const h = try doc.db.create(.object, name, copy);
    try link(doc, h);
    return h;
}

/// Assigns `material` to slot `slot` of the object's mesh, growing the slot
/// list as needed.
pub fn assignMaterial(doc: *Document, ob_h: IdHandle, material: ?IdHandle, slot: usize) EditError!void {
    const ob = doc.db.get(.object, ob_h) orelse return error.StaleHandle;
    if (ob.kind != .mesh) return error.WrongType;
    const mesh = doc.db.get(.mesh, ob.data orelse return error.StaleHandle) orelse return error.StaleHandle;
    const old = mesh.materials.slice();
    const n = @max(old.len, slot + 1);
    const items = try doc.gpa.alloc(?IdHandle, n);
    @memcpy(items[0..old.len], old);
    @memset(items[old.len..], null);
    items[slot] = material;
    mesh.materials.release(doc.gpa);
    mesh.materials = try .fromOwned(doc.gpa, items);
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
