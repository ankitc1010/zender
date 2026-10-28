//! Depsgraph (TRD §7): which objects' evaluated meshes depend on which,
//! evaluated in dependency order.
//!
//! An object's evaluated mesh is its mesh data run through its modifier
//! stack. A modifier with a target (boolean operand, mirror centre, array
//! offset) depends on the target's world matrix and evaluated mesh, so the
//! target is evaluated first. Each result is cached under a hash of every
//! input: the mesh's buffer serials, the modifier settings, the purpose
//! (viewport or render), and the matrices and hashes of targets. That hash
//! serves as the per-ID dirty flag: any edit changes a serial or a setting,
//! so exactly the results that depend on it miss the cache and are
//! recomputed, and nothing else is. Modifier tools refuse a target that
//! would close a cycle and name the path (`cyclePath`); evaluation also
//! guards against one by treating a revisited object as unmodified.

const std = @import("std");
const math = @import("math");
const core = @import("../core/root.zig");
const geom = @import("../geom/root.zig");
const Cache = @import("cache.zig").Cache;

const Allocator = std.mem.Allocator;
const IdHandle = core.IdHandle;
const Document = core.Document;
const Mesh = core.types.Mesh;
const Modifier = core.types.Modifier;
const Wyhash = std.hash.Wyhash;
pub const Purpose = geom.modifiers.Purpose;
pub const Note = geom.modifiers.Note;

pub const Error = Allocator.Error || math.DeadlineError;

pub fn active(md: *const Modifier, purpose: Purpose) bool {
    return switch (purpose) {
        .viewport => md.show_viewport,
        .render => md.show_render,
    };
}

pub fn hasActive(ob: *const core.types.Object, purpose: Purpose) bool {
    for (ob.modifiers.slice()) |*md| if (active(md, purpose)) return true;
    return false;
}

pub const Result = struct {
    mesh: *const Mesh,
    key: u64,
    /// Per modifier of the stack (inactive ones `.none`); empty when the
    /// object has no active modifiers.
    notes: []const Note = &.{},
};

pub const Evaluator = struct {
    /// Results and scratch that live as long as the caller's arena.
    arena: Allocator,
    doc: *Document,
    cache: ?*Cache,
    purpose: Purpose,
    stop: ?geom.editmesh.Stop = null,
    done: std.AutoHashMapUnmanaged(u32, ?Result) = .empty,
    visiting: std.AutoHashMapUnmanaged(u32, void) = .empty,

    /// Without a cache, evaluated meshes are copies in the arena that still
    /// hold references to the scene's mesh buffers (modifiers such as
    /// displace share them); this drops those references. Call it when the
    /// results are no longer read. With a cache, the cache owns them.
    pub fn releaseUncached(e: *Evaluator) void {
        if (e.cache != null) return;
        var it = e.done.valueIterator();
        while (it.next()) |r| if (r.*) |res| @constCast(res.mesh).releaseRefs(e.arena);
        e.done.clearRetainingCapacity();
    }

    /// The evaluated mesh of mesh object `h`, or null for other objects
    /// and missing data.
    pub fn evaluate(e: *Evaluator, h: IdHandle) Error!?Result {
        if (e.done.get(h.index)) |r| return r;
        const db = &e.doc.db;
        const ob = db.get(.object, h) orelse return null;
        if (ob.kind != .mesh) return null;
        const base = db.get(.mesh, ob.data orelse return null) orelse return null;
        const base_key = baseKey(base);
        if (!hasActive(ob, e.purpose) or e.visiting.contains(h.index)) {
            return .{ .mesh = base, .key = base_key };
        }
        try e.visiting.put(e.arena, h.index, {});
        defer _ = e.visiting.remove(h.index);

        const world = try core.edit.worldMatrix(db, h);
        const mods = ob.modifiers.slice();
        // Targets first, and the hash of everything the stack reads.
        const targets = try e.arena.alloc(?geom.modifiers.Target, mods.len);
        var hasher = Wyhash.init(0x5a3e);
        hasher.update(std.mem.asBytes(&base_key));
        hasher.update(&.{@intFromEnum(e.purpose)});
        var uses_world = false;
        for (mods, targets) |*md, *t| {
            t.* = null;
            if (!active(md, e.purpose)) continue;
            hashModifier(&hasher, md);
            uses_world = uses_world or md.kind == .bevel or md.kind == .boolean;
            if (md.target) |th| if (db.get(.object, th) != null) {
                const tr = try e.evaluate(th);
                const tw = try core.edit.worldMatrix(db, th);
                t.* = .{ .mesh = if (tr) |r| r.mesh else null, .world = tw };
                hasher.update(std.mem.asBytes(&tw));
                const tk: u64 = if (tr) |r| r.key else 0;
                hasher.update(std.mem.asBytes(&tk));
                uses_world = true;
            };
        }
        if (uses_world) hasher.update(std.mem.asBytes(&world));
        const key = hasher.final();

        const result: Result = blk: {
            if (e.cache) |c| if (c.getStack(key)) |st| break :blk .{ .mesh = &st.mesh, .key = key, .notes = st.notes };
            const gpa = if (e.cache) |c| c.gpa else e.arena;
            const notes = try gpa.alloc(Note, mods.len);
            errdefer gpa.free(notes);
            @memset(notes, .none);
            var cur = geom.modifiers.copy(base);
            errdefer cur.releaseRefs(gpa);
            for (mods, targets, notes) |*md, t, *note| {
                if (!active(md, e.purpose)) continue;
                const next = try geom.modifiers.apply(gpa, &cur, md, .{ .world = world, .target = t, .purpose = e.purpose, .stop = e.stop }, note);
                cur.releaseRefs(gpa);
                cur = next;
            }
            if (e.cache) |c| {
                const st = try c.putStack(key, cur, notes);
                break :blk .{ .mesh = &st.mesh, .key = key, .notes = st.notes };
            }
            const owned = try e.arena.create(Mesh);
            owned.* = cur;
            break :blk .{ .mesh = owned, .key = key, .notes = notes };
        };
        try e.done.put(e.arena, h.index, result);
        return result;
    }
};

fn baseKey(m: *const Mesh) u64 {
    var h = Wyhash.init(0xba5e);
    for ([_]u64{ m.positions.serial(), m.edges.serial(), m.face_offsets.serial(), m.corner_verts.serial(), m.corner_edges.serial() }) |s| h.update(std.mem.asBytes(&s));
    for (m.attrs[0..m.attr_count]) |*a| {
        h.update(a.name.slice());
        const s = a.data.serial();
        h.update(std.mem.asBytes(&s));
    }
    const slots = m.materials.serial();
    h.update(std.mem.asBytes(&slots));
    return h.final();
}

/// Hashes a modifier's settings field by field (no padding bytes).
fn hashModifier(h: *Wyhash, md: *const Modifier) void {
    inline for (std.meta.fields(Modifier)) |f| {
        const x = @field(md, f.name);
        switch (@typeInfo(f.type)) {
            .bool => h.update(&.{@intFromBool(x)}),
            .int => h.update(std.mem.asBytes(&x)),
            .float => h.update(std.mem.asBytes(&x)),
            .@"enum" => h.update(std.mem.asBytes(&@intFromEnum(x))),
            .array => h.update(std.mem.asBytes(&x)),
            .optional => {
                const id: [2]u32 = if (x) |t| .{ t.index, t.generation } else .{ std.math.maxInt(u32), 0 };
                h.update(std.mem.asBytes(&id));
            },
            .@"struct" => if (f.type == math.texture.Recipe) hashFields(h, x) else h.update(x.slice()),
            else => @compileError("hashModifier: unhandled field " ++ f.name),
        }
    }
}

/// Hashes plain data field by field, so padding bytes never count.
fn hashFields(h: *Wyhash, x: anytype) void {
    const T = @TypeOf(x);
    switch (@typeInfo(T)) {
        .bool => h.update(&.{@intFromBool(x)}),
        .int, .float => h.update(std.mem.asBytes(&x)),
        .@"enum" => h.update(std.mem.asBytes(&@intFromEnum(x))),
        .array => for (x) |e| hashFields(h, e),
        .@"struct" => inline for (std.meta.fields(T)) |f| hashFields(h, @field(x, f.name)),
        else => @compileError("hashFields: unhandled type " ++ @typeName(T)),
    }
}

/// When `from` would read `to` (a new modifier target), the chain of
/// objects by which `to` already reads `from`, ending in `from`; null if
/// there is none, so the reference is safe.
pub fn cyclePath(arena: Allocator, db: *core.Database, from: IdHandle, to: IdHandle) Allocator.Error!?[]const IdHandle {
    var path: std.ArrayList(IdHandle) = .empty;
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    if (try reaches(arena, db, to, from, &path, &seen)) return path.items;
    return null;
}

fn reaches(arena: Allocator, db: *core.Database, x: IdHandle, goal: IdHandle, path: *std.ArrayList(IdHandle), seen: *std.AutoHashMapUnmanaged(u32, void)) Allocator.Error!bool {
    try path.append(arena, x);
    if (x.eql(goal)) return true;
    if (seen.contains(x.index)) {
        _ = path.pop();
        return false;
    }
    try seen.put(arena, x.index, {});
    if (db.get(.object, x)) |ob| for (ob.modifiers.slice()) |md| if (md.target) |t| {
        if (try reaches(arena, db, t, goal, path, seen)) return true;
    };
    _ = path.pop();
    return false;
}

const testing = std.testing;

test "stack evaluation, caching by inputs, and cycle paths" {
    const gpa = testing.allocator;
    var doc = try Document.initEmpty(gpa, "Scene");
    defer doc.deinit();
    const mesh = try doc.db.create(.mesh, "Cube", try geom.primitives.generate(gpa, .cube, .{}));
    const a = try core.edit.addObject(&doc, "A", .mesh, mesh);
    const mesh2 = try doc.db.create(.mesh, "Cube.001", try geom.primitives.generate(gpa, .cube, .{}));
    const b = try core.edit.addObject(&doc, "B", .mesh, mesh2);
    const ob = doc.db.get(.object, a).?;
    var mods = [_]Modifier{ Modifier.defaults(.subdivision), Modifier.defaults(.array) };
    mods[1].target = b;
    ob.modifiers = try .fromSlice(gpa, &mods);

    var cache = Cache.init(gpa);
    defer cache.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var ev: Evaluator = .{ .arena = arena_state.allocator(), .doc = &doc, .cache = &cache, .purpose = .render };
    const r = (try ev.evaluate(a)).?;
    // Two subdivision levels (render) make 96 faces; the array doubles them.
    try testing.expectEqual(@as(usize, 192), r.mesh.faceCount());
    // Same inputs: a cache hit. Moving the target changes the key.
    var ev2: Evaluator = .{ .arena = arena_state.allocator(), .doc = &doc, .cache = &cache, .purpose = .render };
    try testing.expectEqual(r.key, (try ev2.evaluate(a)).?.key);
    doc.db.get(.object, b).?.location = .{ 0, 0, 3 };
    var ev3: Evaluator = .{ .arena = arena_state.allocator(), .doc = &doc, .cache = &cache, .purpose = .render };
    try testing.expect(r.key != (try ev3.evaluate(a)).?.key);
    var ev4: Evaluator = .{ .arena = arena_state.allocator(), .doc = &doc, .cache = &cache, .purpose = .viewport };
    try testing.expectEqual(@as(usize, 48), (try ev4.evaluate(a)).?.mesh.faceCount());

    // B reading A would close A → B → A.
    const path = (try cyclePath(arena_state.allocator(), &doc.db, b, a)).?;
    try testing.expectEqual(@as(usize, 2), path.len);
    try testing.expect(path[0].eql(a) and path[1].eql(b));
    try testing.expect(try cyclePath(arena_state.allocator(), &doc.db, a, b) == null);
}
