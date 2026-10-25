//! Copy-on-write, reference-counted arrays (FR-DM-4).
//!
//! Duplicating a datablock or snapshotting the database for undo retains
//! arrays instead of copying them; the first write through `mut` copies an
//! array only if someone else still holds it.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Source of buffer serials. wasm32 has no 64-bit atomics, and its builds
/// are single-threaded, so a plain counter serves there.
const SerialCounter = if (builtin.single_threaded) struct {
    n: u64 = 1,
    fn next(c: *@This()) u64 {
        defer c.n += 1;
        return c.n;
    }
} else struct {
    n: std.atomic.Value(u64) = .init(1),
    fn next(c: *@This()) u64 {
        return c.n.fetchAdd(1, .monotonic);
    }
};

var next_serial: SerialCounter = .{};

pub fn Shared(comptime T: type) type {
    return struct {
        box: ?*Box = null,

        const Self = @This();
        const Box = struct {
            refs: std.atomic.Value(u32),
            /// Unique for the life of the process, never reused; caches of
            /// derived data key on it (see eval/cache.zig).
            serial: u64,
            items: []T,
        };

        pub const empty: Self = .{};

        /// Takes ownership of `items`, which must come from `gpa`.
        pub fn fromOwned(gpa: Allocator, items: []T) Allocator.Error!Self {
            if (items.len == 0) {
                gpa.free(items);
                return .{};
            }
            const box = try gpa.create(Box);
            box.* = .{ .refs = .init(1), .serial = next_serial.next(), .items = items };
            return .{ .box = box };
        }

        pub fn fromSlice(gpa: Allocator, items: []const T) Allocator.Error!Self {
            if (items.len == 0) return .{};
            const copy = try gpa.dupe(T, items);
            errdefer gpa.free(copy);
            return fromOwned(gpa, copy);
        }

        pub fn initLen(gpa: Allocator, n: usize, value: T) Allocator.Error!Self {
            if (n == 0) return .{};
            const items = try gpa.alloc(T, n);
            @memset(items, value);
            errdefer gpa.free(items);
            return fromOwned(gpa, items);
        }

        pub fn slice(s: Self) []const T {
            return if (s.box) |b| b.items else &.{};
        }

        pub fn len(s: Self) usize {
            return s.slice().len;
        }

        pub fn retain(s: Self) Self {
            if (s.box) |b| _ = b.refs.fetchAdd(1, .monotonic);
            return s;
        }

        pub fn release(s: *Self, gpa: Allocator) void {
            const b = s.box orelse return;
            s.box = null;
            if (b.refs.fetchSub(1, .acq_rel) == 1) {
                gpa.free(b.items);
                gpa.destroy(b);
            }
        }

        /// Writable view; copies the array first if it is shared. Either way
        /// the buffer gets a new serial, since its contents are about to change.
        pub fn mut(s: *Self, gpa: Allocator) Allocator.Error![]T {
            const b = s.box orelse return &.{};
            if (b.refs.load(.acquire) == 1) {
                b.serial = next_serial.next();
                return b.items;
            }
            const fresh = try fromSlice(gpa, b.items);
            s.release(gpa);
            s.* = fresh;
            return fresh.box.?.items;
        }

        /// Replaces the contents with a copy of `items`.
        pub fn set(s: *Self, gpa: Allocator, items: []const T) Allocator.Error!void {
            const fresh = try fromSlice(gpa, items);
            s.release(gpa);
            s.* = fresh;
        }

        pub fn isShared(s: Self) bool {
            const b = s.box orelse return false;
            return b.refs.load(.acquire) > 1;
        }

        /// Identity of the underlying buffer, for memory accounting.
        pub fn id(s: Self) usize {
            return if (s.box) |b| @intFromPtr(b) else 0;
        }

        /// Content identity: equal serials mean equal contents. 0 = empty.
        pub fn serial(s: Self) u64 {
            return if (s.box) |b| b.serial else 0;
        }

        pub fn byteSize(s: Self) usize {
            return s.len() * @sizeOf(T);
        }
    };
}

test "copy on write" {
    const gpa = std.testing.allocator;
    var a = try Shared(u32).fromSlice(gpa, &.{ 1, 2, 3 });
    defer a.release(gpa);
    var b = a.retain();
    defer b.release(gpa);
    try std.testing.expect(a.isShared());
    const w = try b.mut(gpa);
    w[0] = 9;
    try std.testing.expectEqual(@as(u32, 1), a.slice()[0]);
    try std.testing.expectEqual(@as(u32, 9), b.slice()[0]);
    try std.testing.expect(!a.isShared());
    // Writing in place still changes the content identity.
    const before = a.serial();
    _ = try a.mut(gpa);
    try std.testing.expect(a.serial() != before);
}
