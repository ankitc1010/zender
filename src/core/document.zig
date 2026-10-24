//! A Document is one open scene file: its database, the active Scene
//! datablock, a revision counter, and undo/redo history (FR-DM-5, FR-DM-6).
//!
//! Every mutation runs in a Transaction. `begin` takes a copy-on-write
//! snapshot; `rollback` restores it, so a failed step leaves the database
//! exactly as it was; `commit` keeps the snapshot as the undo step.

const std = @import("std");
const ids = @import("ids.zig");
const types = @import("types.zig");
const Database = @import("database.zig").Database;

const Allocator = std.mem.Allocator;
const IdHandle = ids.IdHandle;

pub const Limits = struct {
    max_steps: usize = 256,
    /// Memory cap for undo history (TRD default 512 MB).
    max_bytes: usize = 512 << 20,
};

const Step = struct {
    db: Database,
    scene: IdHandle,
    label: [64]u8,
    label_len: u8,

    fn labelSlice(s: *const Step) []const u8 {
        return s.label[0..s.label_len];
    }
};

pub const Document = struct {
    gpa: Allocator,
    db: Database,
    /// Active Scene datablock.
    scene: IdHandle,
    /// Increments on every committed change, undo and redo.
    rev: u64 = 0,
    /// Mutations since the last save.
    dirty: u32 = 0,
    limits: Limits = .{},
    undo_steps: std.ArrayList(Step) = .empty,
    redo_steps: std.ArrayList(Step) = .empty,

    /// A new document holding one Scene with a master collection and World,
    /// as Blender's empty startup state minus the default objects.
    pub fn initEmpty(gpa: Allocator, scene_name: []const u8) Allocator.Error!Document {
        var db = Database.init(gpa);
        errdefer db.deinit();
        const world = try db.create(.world, "World", .{});
        const coll = try db.create(.collection, "Scene Collection", .{});
        const scene = try db.create(.scene, scene_name, .{ .collection = coll, .world = world });
        return .{ .gpa = gpa, .db = db, .scene = scene };
    }

    pub fn deinit(doc: *Document) void {
        for (doc.undo_steps.items) |*s| s.db.deinit();
        for (doc.redo_steps.items) |*s| s.db.deinit();
        doc.undo_steps.deinit(doc.gpa);
        doc.redo_steps.deinit(doc.gpa);
        doc.db.deinit();
        doc.* = undefined;
    }

    pub fn sceneData(doc: *Document) *types.Scene {
        return doc.db.get(.scene, doc.scene).?;
    }

    pub fn canUndo(doc: *const Document) bool {
        return doc.undo_steps.items.len > 0;
    }

    pub fn canRedo(doc: *const Document) bool {
        return doc.redo_steps.items.len > 0;
    }

    /// Steps back one committed transaction; returns its label.
    pub fn undo(doc: *Document, label_buf: []u8) Allocator.Error!?[]const u8 {
        if (doc.undo_steps.items.len == 0) return null;
        try doc.redo_steps.ensureUnusedCapacity(doc.gpa, 1);
        const step = doc.undo_steps.pop().?;
        const label = copyLabel(label_buf, step.labelSlice());
        doc.redo_steps.appendAssumeCapacity(.{ .db = doc.db, .scene = doc.scene, .label = step.label, .label_len = step.label_len });
        doc.db = step.db;
        doc.scene = step.scene;
        doc.rev += 1;
        doc.dirty += 1;
        return label;
    }

    pub fn redo(doc: *Document, label_buf: []u8) Allocator.Error!?[]const u8 {
        if (doc.redo_steps.items.len == 0) return null;
        try doc.undo_steps.ensureUnusedCapacity(doc.gpa, 1);
        const step = doc.redo_steps.pop().?;
        const label = copyLabel(label_buf, step.labelSlice());
        doc.undo_steps.appendAssumeCapacity(.{ .db = doc.db, .scene = doc.scene, .label = step.label, .label_len = step.label_len });
        doc.db = step.db;
        doc.scene = step.scene;
        doc.rev += 1;
        doc.dirty += 1;
        return label;
    }

    /// Approximate bytes held by undo history: slot arrays plus every mesh
    /// buffer no longer shared with the live database, each counted once.
    pub fn historyBytes(doc: *Document) usize {
        var seen: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer seen.deinit(doc.gpa);
        const Ctx = struct {
            seen: *std.AutoHashMapUnmanaged(usize, void),
            gpa: Allocator,
            bytes: usize = 0,
            count: bool,
            fn visit(c: *@This(), id: usize, size: usize) void {
                if (id == 0) return;
                const gop = c.seen.getOrPut(c.gpa, id) catch return;
                if (!gop.found_existing and c.count) c.bytes += size;
            }
        };
        var ctx: Ctx = .{ .seen = &seen, .gpa = doc.gpa, .count = false };
        doc.db.eachBuffer(&ctx, Ctx.visit);
        ctx.count = true;
        var i = doc.undo_steps.items.len;
        while (i > 0) {
            i -= 1;
            ctx.bytes += doc.undo_steps.items[i].db.slotBytes();
            doc.undo_steps.items[i].db.eachBuffer(&ctx, Ctx.visit);
        }
        for (doc.redo_steps.items) |*s| {
            ctx.bytes += s.db.slotBytes();
            s.db.eachBuffer(&ctx, Ctx.visit);
        }
        return ctx.bytes;
    }

    fn trimHistory(doc: *Document) void {
        while (doc.undo_steps.items.len > doc.limits.max_steps) doc.dropOldest();
        while (doc.undo_steps.items.len > 0 and doc.historyBytes() > doc.limits.max_bytes) doc.dropOldest();
    }

    fn dropOldest(doc: *Document) void {
        var s = doc.undo_steps.orderedRemove(0);
        s.db.deinit();
    }

    fn clearRedo(doc: *Document) void {
        for (doc.redo_steps.items) |*s| s.db.deinit();
        doc.redo_steps.clearRetainingCapacity();
    }
};

fn copyLabel(buf: []u8, label: []const u8) []const u8 {
    const n = @min(buf.len, label.len);
    @memcpy(buf[0..n], label[0..n]);
    return buf[0..n];
}

pub const Transaction = struct {
    doc: *Document,
    before: ?Database,
    scene_before: IdHandle,

    pub fn begin(doc: *Document) Allocator.Error!Transaction {
        return .{ .doc = doc, .before = try doc.db.snapshot(), .scene_before = doc.scene };
    }

    /// Restores the database to its state at `begin`.
    pub fn rollback(tx: *Transaction) void {
        var before = tx.before orelse return;
        tx.doc.db.deinit();
        tx.doc.db = before;
        tx.doc.scene = tx.scene_before;
        tx.before = null;
        before = undefined;
    }

    /// Keeps the change and records the pre-change state as an undo step.
    pub fn commit(tx: *Transaction, label: []const u8) Allocator.Error!void {
        const doc = tx.doc;
        var step: Step = .{ .db = tx.before.?, .scene = tx.scene_before, .label = undefined, .label_len = 0 };
        step.label_len = @intCast(copyLabel(&step.label, label[0..ids.utf8Prefix(label, step.label.len)]).len);
        doc.undo_steps.append(doc.gpa, step) catch |e| {
            tx.rollback();
            return e;
        };
        tx.before = null;
        doc.clearRedo();
        doc.trimHistory();
        doc.rev += 1;
        doc.dirty += 1;
    }

    /// Commits without an undo step, for changes with nothing to undo.
    pub fn commitNoUndo(tx: *Transaction) void {
        if (tx.before) |*b| b.deinit();
        tx.before = null;
        tx.doc.rev += 1;
    }

    /// For `defer`: rolls back if neither commit nor rollback ran.
    pub fn end(tx: *Transaction) void {
        if (tx.before != null) tx.rollback();
    }
};

const testing = std.testing;

test "rollback restores, undo and redo walk history" {
    var doc = try Document.initEmpty(testing.allocator, "Scene");
    defer doc.deinit();
    var buf: [64]u8 = undefined;

    {
        var tx = try Transaction.begin(&doc);
        defer tx.end();
        _ = try doc.db.create(.camera, "Cam", .{});
        try tx.commit("add camera");
    }
    try testing.expectEqual(@as(u64, 1), doc.rev);
    {
        var tx = try Transaction.begin(&doc);
        defer tx.end();
        _ = try doc.db.create(.camera, "Cam", .{});
        // No commit: end() rolls back.
    }
    try testing.expectEqual(@as(u32, 1), doc.db.camera.live);
    try testing.expectEqualStrings("add camera", (try doc.undo(&buf)).?);
    try testing.expectEqual(@as(u32, 0), doc.db.camera.live);
    try testing.expectEqualStrings("add camera", (try doc.redo(&buf)).?);
    try testing.expectEqual(@as(u32, 1), doc.db.camera.live);
    try testing.expectEqual(@as(u64, 3), doc.rev);
}

test "history is capped by step count" {
    var doc = try Document.initEmpty(testing.allocator, "Scene");
    defer doc.deinit();
    doc.limits.max_steps = 3;
    for (0..5) |_| {
        var tx = try Transaction.begin(&doc);
        defer tx.end();
        _ = try doc.db.create(.light, "L", .{});
        try tx.commit("add light");
    }
    try testing.expectEqual(@as(usize, 3), doc.undo_steps.items.len);
}
