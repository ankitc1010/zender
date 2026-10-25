//! `parallelFor`: the one parallel primitive the engine uses (FR-ARCH-4).
//!
//! Work runs on the shared `std.Io` thread pool (Io.Threaded sizes it to the
//! CPU count). Chunks are claimed from one atomic counter, so idle threads
//! take work from busy ones. Callers must make each chunk's output depend
//! only on its chunk index, never on which thread ran it; that is what keeps
//! results identical for any thread count (G5, FR-REN-5).

const std = @import("std");
const Io = std.Io;

pub const DeadlineError = error{DeadlineExceeded};

/// A wall-clock limit for one tool call (SEC-3). Once it passes, parallel
/// loops stop claiming chunks and return error.DeadlineExceeded; their
/// output is then incomplete and must not be used.
pub const Deadline = struct {
    /// On the awake clock.
    at: Io.Timestamp,
    tripped: std.atomic.Value(bool) = .init(false),

    pub fn after(io: Io, ms: u64) Deadline {
        const start = Io.Clock.awake.now(io);
        return .{ .at = start.addDuration(.fromMilliseconds(@intCast(@min(ms, std.math.maxInt(i64))))) };
    }

    /// Checks the clock; true once the deadline has passed.
    pub fn passed(d: *Deadline, io: Io) bool {
        if (d.tripped.load(.monotonic)) return true;
        if (Io.Clock.awake.now(io).nanoseconds < d.at.nanoseconds) return false;
        d.tripped.store(true, .monotonic);
        return true;
    }

    /// True if some loop stopped early because of this deadline.
    pub fn expired(d: *const Deadline) bool {
        return d.tripped.load(.monotonic);
    }
};

pub const Pool = struct {
    io: Io,
    /// Upper bound on threads used by one call, main thread included.
    /// 1 runs everything inline; tests set 1, 4 and 16 to check determinism.
    threads: usize,
    /// Set by the command core for the duration of a call.
    deadline: ?*Deadline = null,

    pub fn init(io: Io) Pool {
        const n = std.Thread.getCpuCount() catch 1;
        return .{ .io = io, .threads = @max(1, n) };
    }

    pub fn single(io: Io) Pool {
        return .{ .io = io, .threads = 1 };
    }

    /// Calls `func(ctx, i)` once for every `i` in `0..n_chunks`, spread over
    /// up to `threads` threads, and returns when all calls have finished.
    /// Once `deadline` passes, chunks not yet started are skipped and the
    /// call returns error.DeadlineExceeded.
    pub fn parallelFor(
        pool: Pool,
        n_chunks: usize,
        ctx: anytype,
        comptime func: fn (@TypeOf(ctx), usize) void,
    ) DeadlineError!void {
        if (n_chunks == 0) return;
        const helpers = @min(pool.threads, n_chunks) - 1;
        if (helpers == 0) {
            for (0..n_chunks) |i| {
                if (pool.deadline) |d| if (d.passed(pool.io)) return error.DeadlineExceeded;
                func(ctx, i);
            }
            return;
        }
        const Ctx = @TypeOf(ctx);
        const Shared = struct {
            next: std.atomic.Value(usize) = .init(0),
            n: usize,
            ctx: Ctx,
            io: Io,
            deadline: ?*Deadline,

            fn run(s: *@This()) void {
                while (true) {
                    if (s.deadline) |d| if (d.passed(s.io)) return;
                    const i = s.next.fetchAdd(1, .monotonic);
                    if (i >= s.n) return;
                    func(s.ctx, i);
                }
            }
        };
        var shared: Shared = .{ .n = n_chunks, .ctx = ctx, .io = pool.io, .deadline = pool.deadline };
        var group: Io.Group = .init;
        for (0..helpers) |_| group.async(pool.io, Shared.run, .{&shared});
        shared.run();
        // A cancel request cannot reach this group: it is local and awaited
        // here, so waiting can only end once every helper has returned.
        group.await(pool.io) catch {};
        // Every chunk was claimed unless the deadline stopped the claiming.
        if (shared.next.load(.monotonic) < n_chunks) return error.DeadlineExceeded;
    }
};

test "parallelFor visits every chunk once for any thread count" {
    const io = std.testing.io;
    for ([_]usize{ 1, 2, 4, 16 }) |threads| {
        var hits = [_]std.atomic.Value(u32){.init(0)} ** 257;
        const pool: Pool = .{ .io = io, .threads = threads };
        try pool.parallelFor(hits.len, &hits, struct {
            fn f(h: *[257]std.atomic.Value(u32), i: usize) void {
                _ = h[i].fetchAdd(1, .monotonic);
            }
        }.f);
        for (&hits) |*h| try std.testing.expectEqual(@as(u32, 1), h.load(.monotonic));
    }
}

test "a passed deadline stops parallel loops" {
    const io = std.testing.io;
    for ([_]usize{ 1, 4 }) |threads| {
        var deadline = Deadline.after(io, 0);
        var hits = [_]std.atomic.Value(u32){.init(0)} ** 64;
        const pool: Pool = .{ .io = io, .threads = threads, .deadline = &deadline };
        try std.testing.expectError(error.DeadlineExceeded, pool.parallelFor(hits.len, &hits, struct {
            fn f(h: *[64]std.atomic.Value(u32), i: usize) void {
                _ = h[i].fetchAdd(1, .monotonic);
            }
        }.f));
        var total: u32 = 0;
        for (&hits) |*h| total += h.load(.monotonic);
        try std.testing.expect(deadline.expired());
        try std.testing.expect(total < hits.len);
    }
}
