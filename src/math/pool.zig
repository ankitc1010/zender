//! `parallelFor`: the one parallel primitive the engine uses (FR-ARCH-4).
//!
//! Work runs on the shared `std.Io` thread pool (Io.Threaded sizes it to the
//! CPU count). Chunks are claimed from one atomic counter, so idle threads
//! take work from busy ones. Callers must make each chunk's output depend
//! only on its chunk index, never on which thread ran it; that is what keeps
//! results identical for any thread count (G5, FR-REN-5).

const std = @import("std");
const Io = std.Io;

pub const Pool = struct {
    io: Io,
    /// Upper bound on threads used by one call, main thread included.
    /// 1 runs everything inline; tests set 1, 4 and 16 to check determinism.
    threads: usize,

    pub fn init(io: Io) Pool {
        const n = std.Thread.getCpuCount() catch 1;
        return .{ .io = io, .threads = @max(1, n) };
    }

    pub fn single(io: Io) Pool {
        return .{ .io = io, .threads = 1 };
    }

    /// Calls `func(ctx, i)` once for every `i` in `0..n_chunks`, spread over
    /// up to `threads` threads, and returns when all calls have finished.
    pub fn parallelFor(
        pool: Pool,
        n_chunks: usize,
        ctx: anytype,
        comptime func: fn (@TypeOf(ctx), usize) void,
    ) void {
        if (n_chunks == 0) return;
        const helpers = @min(pool.threads, n_chunks) - 1;
        if (helpers == 0) {
            for (0..n_chunks) |i| func(ctx, i);
            return;
        }
        const Ctx = @TypeOf(ctx);
        const Shared = struct {
            next: std.atomic.Value(usize) = .init(0),
            n: usize,
            ctx: Ctx,

            fn run(s: *@This()) void {
                while (true) {
                    const i = s.next.fetchAdd(1, .monotonic);
                    if (i >= s.n) return;
                    func(s.ctx, i);
                }
            }
        };
        var shared: Shared = .{ .n = n_chunks, .ctx = ctx };
        var group: Io.Group = .init;
        for (0..helpers) |_| group.async(pool.io, Shared.run, .{&shared});
        shared.run();
        // A cancel request cannot reach this group: it is local and awaited
        // here, so waiting can only end once every helper has returned.
        group.await(pool.io) catch {};
    }
};

test "parallelFor visits every chunk once for any thread count" {
    const io = std.testing.io;
    for ([_]usize{ 1, 2, 4, 16 }) |threads| {
        var hits = [_]std.atomic.Value(u32){.init(0)} ** 257;
        const pool: Pool = .{ .io = io, .threads = threads };
        pool.parallelFor(hits.len, &hits, struct {
            fn f(h: *[257]std.atomic.Value(u32), i: usize) void {
                _ = h[i].fetchAdd(1, .monotonic);
            }
        }.f);
        for (&hits) |*h| try std.testing.expectEqual(@as(u32, 1), h.load(.monotonic));
    }
}
