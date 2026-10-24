//! The Database: one generational pool per ID type (TRD §6, FR-DM-1/2).
//!
//! Slots are never compacted, so iteration order (by index) is stable and
//! canonical output is deterministic. `snapshot` makes a copy-on-write copy
//! used by transactions and undo.

const std = @import("std");
const ids = @import("ids.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const IdType = ids.IdType;
const IdHandle = ids.IdHandle;
const Name = ids.Name;

pub fn Pool(comptime T: type, comptime id_type: IdType) type {
    return struct {
        slots: std.ArrayList(Slot) = .empty,
        free: std.ArrayList(u32) = .empty,
        live: u32 = 0,

        const Self = @This();
        pub const Slot = struct {
            generation: u32 = 0,
            alive: bool = false,
            value: T = undefined,
        };

        pub fn add(p: *Self, gpa: Allocator, value: T) Allocator.Error!IdHandle {
            try p.slots.ensureUnusedCapacity(gpa, 1);
            // remove() appends to the free list and must not fail.
            try p.free.ensureTotalCapacity(gpa, p.slots.items.len + 1);
            // Reuse the lowest free index for deterministic handles.
            if (p.free.items.len > 0) {
                var best: usize = 0;
                for (p.free.items, 0..) |idx, k| {
                    if (idx < p.free.items[best]) best = k;
                }
                const index = p.free.swapRemove(best);
                const slot = &p.slots.items[index];
                slot.generation +%= 1;
                slot.alive = true;
                slot.value = value;
                p.live += 1;
                return .{ .type = id_type, .index = index, .generation = slot.generation };
            }
            const index: u32 = @intCast(p.slots.items.len);
            p.slots.appendAssumeCapacity(.{ .generation = 1, .alive = true, .value = value });
            p.live += 1;
            return .{ .type = id_type, .index = index, .generation = 1 };
        }

        pub fn get(p: *Self, h: IdHandle) ?*T {
            if (h.type != id_type or h.index >= p.slots.items.len) return null;
            const slot = &p.slots.items[h.index];
            if (!slot.alive or slot.generation != h.generation) return null;
            return &slot.value;
        }

        pub fn getConst(p: *const Self, h: IdHandle) ?*const T {
            if (h.type != id_type or h.index >= p.slots.items.len) return null;
            const slot = &p.slots.items[h.index];
            if (!slot.alive or slot.generation != h.generation) return null;
            return &slot.value;
        }

        pub fn remove(p: *Self, gpa: Allocator, h: IdHandle) bool {
            const v = p.get(h) orelse return false;
            v.releaseRefs(gpa);
            const slot = &p.slots.items[h.index];
            slot.alive = false;
            slot.value = undefined;
            p.live -= 1;
            p.free.appendAssumeCapacity(h.index);
            return true;
        }

        pub fn clone(p: *const Self, gpa: Allocator) Allocator.Error!Self {
            var out: Self = .{ .live = p.live };
            out.slots = try p.slots.clone(gpa);
            errdefer out.slots.deinit(gpa);
            out.free = try p.free.clone(gpa);
            errdefer out.free.deinit(gpa);
            try out.free.ensureTotalCapacity(gpa, out.slots.items.len);
            for (out.slots.items) |*s| if (s.alive) s.value.retainRefs();
            return out;
        }

        pub fn deinit(p: *Self, gpa: Allocator) void {
            for (p.slots.items) |*s| if (s.alive) s.value.releaseRefs(gpa);
            p.slots.deinit(gpa);
            p.free.deinit(gpa);
        }

        pub fn handleAt(p: *const Self, index: usize) ?IdHandle {
            const s = &p.slots.items[index];
            if (!s.alive) return null;
            return .{ .type = id_type, .index = @intCast(index), .generation = s.generation };
        }

        pub const Iterator = struct {
            pool: *Self,
            i: usize = 0,
            pub fn next(it: *Iterator) ?struct { handle: IdHandle, value: *T } {
                while (it.i < it.pool.slots.items.len) {
                    const idx = it.i;
                    it.i += 1;
                    const s = &it.pool.slots.items[idx];
                    if (s.alive) return .{
                        .handle = .{ .type = id_type, .index = @intCast(idx), .generation = s.generation },
                        .value = &s.value,
                    };
                }
                return null;
            }
        };

        pub fn iterator(p: *Self) Iterator {
            return .{ .pool = p };
        }

        pub fn slotBytes(p: *const Self) usize {
            return p.slots.capacity * @sizeOf(Slot);
        }
    };
}

fn PoolFor(comptime t: IdType) type {
    return Pool(types.TypeOf(t), t);
}

pub const Database = struct {
    gpa: Allocator,
    scene: PoolFor(.scene) = .{},
    collection: PoolFor(.collection) = .{},
    object: PoolFor(.object) = .{},
    mesh: PoolFor(.mesh) = .{},
    camera: PoolFor(.camera) = .{},
    light: PoolFor(.light) = .{},
    material: PoolFor(.material) = .{},
    world: PoolFor(.world) = .{},

    pub fn init(gpa: Allocator) Database {
        return .{ .gpa = gpa };
    }

    pub fn deinit(db: *Database) void {
        inline for (types.stored_types) |t| db.pool(t).deinit(db.gpa);
        db.* = undefined;
    }

    pub fn pool(db: *Database, comptime t: IdType) *PoolFor(t) {
        return &@field(db, @tagName(t));
    }

    pub fn poolConst(db: *const Database, comptime t: IdType) *const PoolFor(t) {
        return &@field(db, @tagName(t));
    }

    pub fn get(db: *Database, comptime t: IdType, h: IdHandle) ?*types.TypeOf(t) {
        return db.pool(t).get(h);
    }

    pub fn getConst(db: *const Database, comptime t: IdType, h: IdHandle) ?*const types.TypeOf(t) {
        return db.poolConst(t).getConst(h);
    }

    /// Adds a datablock, renaming it ".001", ".002", … if the name is taken.
    pub fn create(db: *Database, comptime t: IdType, name: []const u8, value: types.TypeOf(t)) Allocator.Error!IdHandle {
        var v = value;
        v.name = db.uniqueName(t, name, null);
        return db.pool(t).add(db.gpa, v);
    }

    pub fn remove(db: *Database, comptime t: IdType, h: IdHandle) bool {
        return db.pool(t).remove(db.gpa, h);
    }

    pub fn findByName(db: *Database, comptime t: IdType, name: []const u8) ?IdHandle {
        var it = db.pool(t).iterator();
        while (it.next()) |e| if (e.value.name.eql(name)) return e.handle;
        return null;
    }

    fn nameTaken(db: *Database, comptime t: IdType, name: []const u8, exclude: ?IdHandle) bool {
        var it = db.pool(t).iterator();
        while (it.next()) |e| {
            if (exclude) |x| if (e.handle.eql(x)) continue;
            if (e.value.name.eql(name)) return true;
        }
        return false;
    }

    /// Blender's rule: keep the name if free, else the lowest free ".NNN"
    /// suffix on the base name, cutting the base so the result fits 255 bytes.
    pub fn uniqueName(db: *Database, comptime t: IdType, want: []const u8, exclude: ?IdHandle) Name {
        const trimmed = want[0..ids.utf8Prefix(want, Name.max_len)];
        const requested = if (trimmed.len == 0) defaultName(t) else trimmed;
        if (!db.nameTaken(t, requested, exclude)) return .init(requested);
        const base = ids.splitNumericSuffix(requested).base;
        var buf: [Name.max_len + 16]u8 = undefined;
        var n: u32 = 1;
        while (true) : (n += 1) {
            var digits_buf: [12]u8 = undefined;
            const digits = std.fmt.bufPrint(&digits_buf, ".{d:0>3}", .{n}) catch unreachable;
            const keep = ids.utf8Prefix(base, Name.max_len - digits.len);
            const candidate = std.fmt.bufPrint(&buf, "{s}{s}", .{ base[0..keep], digits }) catch unreachable;
            if (!db.nameTaken(t, candidate, exclude)) return .init(candidate);
        }
    }

    pub fn rename(db: *Database, comptime t: IdType, h: IdHandle, want: []const u8) ?Name {
        const v = db.get(t, h) orelse return null;
        const n = db.uniqueName(t, want, h);
        v.name = n;
        return n;
    }

    /// Copy-on-write copy: slot arrays are duplicated, mesh arrays shared.
    pub fn snapshot(db: *const Database) Allocator.Error!Database {
        var out: Database = .{ .gpa = db.gpa };
        errdefer out.deinit();
        inline for (types.stored_types) |t| {
            @field(out, @tagName(t)) = try db.poolConst(t).clone(db.gpa);
        }
        return out;
    }

    /// Bytes held by slot arrays, excluding shared mesh buffers.
    pub fn slotBytes(db: *const Database) usize {
        var n: usize = 0;
        inline for (types.stored_types) |t| n += db.poolConst(t).slotBytes();
        return n;
    }

    pub fn eachBuffer(db: *Database, ctx: anytype, comptime f: fn (@TypeOf(ctx), usize, usize) void) void {
        var it = db.mesh.iterator();
        while (it.next()) |e| e.value.eachBuffer(ctx, f);
        var cit = db.collection.iterator();
        while (cit.next()) |e| {
            f(ctx, e.value.objects.id(), e.value.objects.byteSize());
            f(ctx, e.value.children.id(), e.value.children.byteSize());
        }
    }
};

fn defaultName(t: IdType) []const u8 {
    return switch (t) {
        .scene => "Scene",
        .collection => "Collection",
        .object => "Object",
        .mesh => "Mesh",
        .camera => "Camera",
        .light => "Light",
        .material => "Material",
        .image => "Image",
        .world => "World",
        .action => "Action",
    };
}

const testing = std.testing;

test "unique names and stale handles" {
    var db = Database.init(testing.allocator);
    defer db.deinit();
    const a = try db.create(.camera, "Cam", .{});
    const b = try db.create(.camera, "Cam", .{});
    const c = try db.create(.camera, "Cam.001", .{});
    try testing.expectEqualStrings("Cam.001", db.get(.camera, b).?.name.slice());
    try testing.expectEqualStrings("Cam.002", db.get(.camera, c).?.name.slice());
    try testing.expect(db.remove(.camera, a));
    try testing.expect(db.get(.camera, a) == null);
    const d = try db.create(.camera, "Cam", .{});
    // Slot 0 is reused with a new generation; the old handle stays dead.
    try testing.expectEqual(a.index, d.index);
    try testing.expect(db.get(.camera, a) == null);
    try testing.expect(db.get(.camera, d) != null);
}

test "snapshot shares mesh arrays until written" {
    const gpa = testing.allocator;
    var db = Database.init(gpa);
    defer db.deinit();
    var m: types.Mesh = .{};
    m.positions = try .fromSlice(gpa, &.{ .{ 0, 0, 0 }, .{ 1, 0, 0 } });
    const h = try db.create(.mesh, "M", m);
    var snap = try db.snapshot();
    defer snap.deinit();
    try testing.expect(db.get(.mesh, h).?.positions.isShared());
    const w = try db.get(.mesh, h).?.positions.mut(gpa);
    w[1][0] = 5;
    try testing.expectEqual(@as(f32, 1), snap.get(.mesh, h).?.positions.slice()[1][0]);
}
