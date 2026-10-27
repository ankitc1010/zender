//! Evaluated-mesh cache (TRD §7): derived data keyed by the identity of the
//! inputs it came from. Buffer serials are never reused and change on every
//! write, so a matching key always means matching inputs.

const std = @import("std");
const math = @import("math");
const core = @import("../core/root.zig");
const geom = @import("../geom/root.zig");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const Mesh = core.types.Mesh;

pub const Key = struct {
    positions: u64,
    face_offsets: u64,
    corner_verts: u64,
    sharp_face: u64,

    pub fn of(m: *const Mesh) Key {
        return .{
            .positions = m.positions.serial(),
            .face_offsets = m.face_offsets.serial(),
            .corner_verts = m.corner_verts.serial(),
            .sharp_face = if (m.attribute("sharp_face")) |a| a.data.serial() else 0,
        };
    }
};

pub const Cache = struct {
    gpa: Allocator,
    normals_by_key: std.AutoHashMapUnmanaged(Key, Entry) = .empty,
    /// Evaluated modifier stacks, by the depsgraph's hash of their inputs.
    stacks: std.AutoHashMapUnmanaged(u64, Stack) = .empty,
    epoch: u64 = 0,
    hits: u64 = 0,
    misses: u64 = 0,

    const Entry = struct { normals: []Vec3, used: u64 };

    pub const Stack = struct {
        mesh: Mesh,
        /// One per modifier: what it reported when evaluated.
        notes: []geom.modifiers.Note,
        used: u64,
    };

    pub fn getStack(c: *Cache, key: u64) ?*Stack {
        const e = c.stacks.getPtr(key) orelse return null;
        e.used = c.epoch;
        c.hits += 1;
        return e;
    }

    /// Takes ownership of `mesh` and `notes` (allocated with `c.gpa`).
    pub fn putStack(c: *Cache, key: u64, mesh: Mesh, notes: []geom.modifiers.Note) Allocator.Error!*Stack {
        c.misses += 1;
        const gop = try c.stacks.getOrPut(c.gpa, key);
        if (gop.found_existing) {
            gop.value_ptr.mesh.releaseRefs(c.gpa);
            c.gpa.free(gop.value_ptr.notes);
        }
        gop.value_ptr.* = .{ .mesh = mesh, .notes = notes, .used = c.epoch };
        return gop.value_ptr;
    }

    pub fn init(gpa: Allocator) Cache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(c: *Cache) void {
        var it = c.normals_by_key.valueIterator();
        while (it.next()) |e| c.gpa.free(e.normals);
        c.normals_by_key.deinit(c.gpa);
        var sit = c.stacks.valueIterator();
        while (sit.next()) |e| {
            e.mesh.releaseRefs(c.gpa);
            c.gpa.free(e.notes);
        }
        c.stacks.deinit(c.gpa);
    }

    /// Drops every entry, e.g. after a call was stopped part-way, when some
    /// results may be incomplete.
    pub fn clear(c: *Cache) void {
        c.deinit();
        c.normals_by_key = .empty;
        c.stacks = .empty;
    }

    /// Starts an evaluation; entries not touched before `sweep` are freed.
    pub fn begin(c: *Cache) void {
        c.epoch += 1;
    }

    pub fn cornerNormals(c: *Cache, m: *const Mesh, pool: math.Pool) (Allocator.Error || math.DeadlineError)![]const Vec3 {
        const key = Key.of(m);
        if (c.normals_by_key.getPtr(key)) |e| {
            e.used = c.epoch;
            c.hits += 1;
            return e.normals;
        }
        c.misses += 1;
        const n = try geom.normals.cornerNormals(c.gpa, m, pool);
        errdefer c.gpa.free(n);
        try c.normals_by_key.put(c.gpa, key, .{ .normals = n, .used = c.epoch });
        return n;
    }

    /// Frees entries the current evaluation did not use.
    pub fn sweep(c: *Cache) void {
        c.sweepStacks();
        c.sweepNormals();
    }

    fn sweepStacks(c: *Cache) void {
        while (true) {
            var stale: [64]u64 = undefined;
            var n: usize = 0;
            var it = c.stacks.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.used != c.epoch) {
                    stale[n] = e.key_ptr.*;
                    n += 1;
                    if (n == stale.len) break;
                }
            }
            if (n == 0) return;
            for (stale[0..n]) |k| {
                var kv = c.stacks.fetchRemove(k).?;
                kv.value.mesh.releaseRefs(c.gpa);
                c.gpa.free(kv.value.notes);
            }
        }
    }

    fn sweepNormals(c: *Cache) void {
        var it = c.normals_by_key.iterator();
        var stale: [64]Key = undefined;
        while (true) {
            var n: usize = 0;
            it = c.normals_by_key.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.used != c.epoch) {
                    stale[n] = e.key_ptr.*;
                    n += 1;
                    if (n == stale.len) break;
                }
            }
            if (n == 0) return;
            for (stale[0..n]) |k| {
                const kv = c.normals_by_key.fetchRemove(k).?;
                c.gpa.free(kv.value.normals);
            }
        }
    }
};
