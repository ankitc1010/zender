//! Soft-selection weights (Blender's proportional editing): every vertex
//! within `radius` of the selection gets a weight from 1 at the selection
//! down to 0 at the radius, shaped by a curve. Distance is measured in a
//! straight line in world space, or along edges when `connected` (so the
//! upper lip does not pull the lower one). Selected vertices weigh 1.

const std = @import("std");
const math = @import("math");
const core = @import("../../core/root.zig");
const em_mod = @import("../editmesh.zig");
const ops = @import("../ops.zig");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const v = math.vec;
const Mesh = core.types.Mesh;
const Bits = std.DynamicBitSetUnmanaged;
const Xform = ops.Xform;

pub const Curve = enum {
    smooth,
    sphere,
    root,
    linear,
    sharp,
    constant,

    /// Weight for t = 1 - distance / radius, t in [0, 1].
    pub fn eval(c: Curve, t: f32) f32 {
        const x = std.math.clamp(t, 0, 1);
        return switch (c) {
            .smooth => x * x * (3 - 2 * x),
            .sphere => @sqrt(x * (2 - x)),
            .root => @sqrt(x),
            .linear => x,
            .sharp => x * x,
            .constant => if (x > 0) 1 else 0,
        };
    }
};

pub const Params = struct {
    /// World metres; 0 turns falloff off (only the selection moves).
    radius: f32 = 0,
    curve: Curve = .smooth,
    connected: bool = false,
};

/// Fills `out` (one per vertex) with weights. `selected` has one bit per
/// vertex.
pub fn weights(gpa: Allocator, m: *const Mesh, selected: *const Bits, xf: Xform, p: Params, stop: ?em_mod.Stop, out: []f32) (Allocator.Error || math.DeadlineError)!void {
    const pos = m.positions.slice();
    std.debug.assert(out.len == pos.len);
    for (out, 0..) |*w, i| w.* = if (selected.isSet(i)) 1 else 0;
    if (p.radius <= 0 or selected.count() == 0) return;
    const world = try gpa.alloc(Vec3, pos.len);
    defer gpa.free(world);
    for (pos, world) |q, *w| w.* = xf.toWorld(q);
    var ticker: Ticker = .{ .stop = stop };
    if (p.connected) {
        try alongEdges(gpa, m, world, selected, p, &ticker, out);
    } else {
        try straight(gpa, world, selected, p, &ticker, out);
    }
}

const Ticker = struct {
    stop: ?em_mod.Stop,
    n: u32 = 0,

    fn tick(t: *Ticker) math.DeadlineError!void {
        const s = t.stop orelse return;
        t.n +%= 1;
        if (t.n % 1024 == 0 and s.deadline.passed(s.io)) return error.DeadlineExceeded;
    }
};

const Cell = [3]i32;

fn cellOf(p: Vec3, size: f32) Cell {
    var c: Cell = undefined;
    for (0..3) |k| c[k] = @intFromFloat(std.math.clamp(@floor(p[k] / size), -1e9, 1e9));
    return c;
}

/// Straight-line distance to the nearest selected vertex, through a grid
/// of cells one radius wide.
fn straight(gpa: Allocator, world: []const Vec3, selected: *const Bits, p: Params, ticker: *Ticker, out: []f32) (Allocator.Error || math.DeadlineError)!void {
    var grid: std.AutoHashMapUnmanaged(Cell, std.ArrayList(u32)) = .empty;
    defer {
        var it = grid.valueIterator();
        while (it.next()) |l| l.deinit(gpa);
        grid.deinit(gpa);
    }
    var sit = selected.iterator(.{});
    while (sit.next()) |i| {
        const gop = try grid.getOrPut(gpa, cellOf(world[i], p.radius));
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, @intCast(i));
    }
    const r2 = p.radius * p.radius;
    for (world, 0..) |q, i| {
        if (selected.isSet(i)) continue;
        try ticker.tick();
        const c = cellOf(q, p.radius);
        var best = r2;
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                var dz: i32 = -1;
                while (dz <= 1) : (dz += 1) {
                    const list = grid.get(.{ c[0] + dx, c[1] + dy, c[2] + dz }) orelse continue;
                    for (list.items) |j| {
                        const d = v.sub(world[j], q);
                        best = @min(best, v.dot(d, d));
                    }
                }
            }
        }
        if (best < r2) out[i] = p.curve.eval(1 - @sqrt(best) / p.radius);
    }
}

/// Shortest distance along edges from the selection (Dijkstra, stopping
/// at the radius).
fn alongEdges(gpa: Allocator, m: *const Mesh, world: []const Vec3, selected: *const Bits, p: Params, ticker: *Ticker, out: []f32) (Allocator.Error || math.DeadlineError)!void {
    var adj = try Adjacency.init(gpa, m);
    defer adj.deinit(gpa);
    const dist = try gpa.alloc(f32, world.len);
    defer gpa.free(dist);
    @memset(dist, std.math.inf(f32));
    const Item = struct { d: f32, v: u32 };
    var queue = std.PriorityQueue(Item, void, struct {
        fn order(_: void, a: Item, b: Item) std.math.Order {
            return switch (std.math.order(a.d, b.d)) {
                .eq => std.math.order(a.v, b.v),
                else => |o| o,
            };
        }
    }.order).empty;
    defer queue.deinit(gpa);
    var sit = selected.iterator(.{});
    while (sit.next()) |i| {
        dist[i] = 0;
        try queue.push(gpa, .{ .d = 0, .v = @intCast(i) });
    }
    while (queue.pop()) |item| {
        try ticker.tick();
        if (item.d > dist[item.v]) continue;
        for (adj.of(item.v)) |n| {
            const d = item.d + v.length(v.sub(world[n], world[item.v]));
            if (d < dist[n] and d < p.radius) {
                dist[n] = d;
                try queue.push(gpa, .{ .d = d, .v = n });
            }
        }
    }
    for (dist, out, 0..) |d, *w, i| {
        if (!selected.isSet(i) and d < p.radius) w.* = p.curve.eval(1 - d / p.radius);
    }
}

/// Vertex neighbours through edges, as compressed rows.
pub const Adjacency = struct {
    start: []u32,
    list: []u32,

    pub fn init(gpa: Allocator, m: *const Mesh) Allocator.Error!Adjacency {
        const n = m.vertCount();
        const edges = m.edges.slice();
        const start = try gpa.alloc(u32, n + 1);
        errdefer gpa.free(start);
        @memset(start, 0);
        for (edges) |e| {
            start[e[0] + 1] += 1;
            start[e[1] + 1] += 1;
        }
        for (1..start.len) |i| start[i] += start[i - 1];
        const list = try gpa.alloc(u32, 2 * edges.len);
        errdefer gpa.free(list);
        const fill = try gpa.dupe(u32, start[0..n]);
        defer gpa.free(fill);
        for (edges) |e| {
            list[fill[e[0]]] = e[1];
            fill[e[0]] += 1;
            list[fill[e[1]]] = e[0];
            fill[e[1]] += 1;
        }
        return .{ .start = start, .list = list };
    }

    pub fn deinit(a: *Adjacency, gpa: Allocator) void {
        gpa.free(a.start);
        gpa.free(a.list);
    }

    pub fn of(a: *const Adjacency, i: u32) []const u32 {
        return a.list[a.start[i]..a.start[i + 1]];
    }
};

const testing = std.testing;
const prims = @import("../primitives.zig");

test "falloff curves and straight versus along-edge distance" {
    try testing.expectEqual(@as(f32, 0.5), Curve.smooth.eval(0.5));
    try testing.expectEqual(@as(f32, 1), Curve.constant.eval(0.01));
    try testing.expectEqual(@as(f32, 0), Curve.linear.eval(-1));

    const gpa = testing.allocator;
    // A 4 x 1 strip of quads along X, 1 m per quad (grid of 2 m, 4 x 4).
    var g = try prims.generate(gpa, .grid, .{ .x_subdivisions = 4, .y_subdivisions = 4 });
    defer g.releaseRefs(gpa);
    const pos = g.positions.slice();
    var sel = try Bits.initEmpty(gpa, pos.len);
    defer sel.deinit(gpa);
    for (pos, 0..) |q, i| if (q[0] == -1) sel.set(i);
    const w = try gpa.alloc(f32, pos.len);
    defer gpa.free(w);
    try weights(gpa, &g, &sel, .identity, .{ .radius = 1, .curve = .linear }, null, w);
    for (pos, w) |q, x| try testing.expectApproxEqAbs(@max(0, 1 - (q[0] + 1)), x, 1e-6);
    // Along edges the distance is the same here, since the grid is axis-aligned.
    const w2 = try gpa.alloc(f32, pos.len);
    defer gpa.free(w2);
    try weights(gpa, &g, &sel, .identity, .{ .radius = 1, .curve = .linear, .connected = true }, null, w2);
    try testing.expectEqualSlices(f32, w, w2);
}
