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
    epoch: u64 = 0,
    hits: u64 = 0,
    misses: u64 = 0,

    const Entry = struct { normals: []Vec3, used: u64 };

    pub fn init(gpa: Allocator) Cache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(c: *Cache) void {
        var it = c.normals_by_key.valueIterator();
        while (it.next()) |e| c.gpa.free(e.normals);
        c.normals_by_key.deinit(c.gpa);
    }

    /// Drops every entry, e.g. after a call was stopped part-way, when some
    /// results may be incomplete.
    pub fn clear(c: *Cache) void {
        c.deinit();
        c.normals_by_key = .empty;
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
