//! File-system confinement (SEC-2, FR-IO-4): every path a tool touches must
//! resolve, after symlinks, inside one of the roots given at launch with
//! --allow-root. Relative paths are taken relative to the first root.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Roots = struct {
    /// Canonical absolute directories, without trailing slash.
    list: []const []const u8,

    /// Canonicalises each given directory; fails if one does not exist.
    pub fn init(io: Io, arena: Allocator, dirs: []const []const u8) !Roots {
        const out = try arena.alloc([]const u8, dirs.len);
        for (dirs, out) |d, *o| o.* = try std.Io.Dir.cwd().realPathFileAlloc(io, d, arena);
        return .{ .list = out };
    }

    pub fn contains(r: Roots, abs: []const u8) bool {
        for (r.list) |root| {
            if (std.mem.eql(u8, abs, root)) return true;
            if (std.mem.eql(u8, root, "/")) return true;
            if (abs.len > root.len and std.mem.startsWith(u8, abs, root) and abs[root.len] == '/') return true;
        }
        return false;
    }
};

pub const PathError = error{
    OutsideRoots,
    NoRoots,
    NotFound,
    InvalidPath,
    OutOfMemory,
};

fn joinWithRoot(arena: Allocator, roots: Roots, path: []const u8) PathError![]const u8 {
    if (path.len == 0 or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (std.fs.path.isAbsolute(path)) return path;
    if (roots.list.len == 0) return error.NoRoots;
    return std.fs.path.join(arena, &.{ roots.list[0], path }) catch error.OutOfMemory;
}

/// Resolves a path to an existing file for reading.
pub fn resolveInput(io: Io, arena: Allocator, roots: Roots, path: []const u8) PathError![]const u8 {
    const joined = try joinWithRoot(arena, roots, path);
    const real = std.Io.Dir.realPathFileAbsoluteAlloc(io, joined, arena) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => error.NotFound,
        else => error.InvalidPath,
    };
    if (!roots.contains(real)) return error.OutsideRoots;
    return real;
}

/// Resolves a path for writing. The parent directory must exist and lie
/// inside a root; an existing target (or symlink) is resolved too, so a
/// link cannot point the write outside.
pub fn resolveOutput(io: Io, arena: Allocator, roots: Roots, path: []const u8) PathError![]const u8 {
    const joined = try joinWithRoot(arena, roots, path);
    const base = std.fs.path.basename(joined);
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return error.InvalidPath;
    if (std.Io.Dir.realPathFileAbsoluteAlloc(io, joined, arena)) |real| {
        if (!roots.contains(real)) return error.OutsideRoots;
        return real;
    } else |e| switch (e) {
        error.FileNotFound => {},
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPath,
    }
    const parent = std.fs.path.dirname(joined) orelse return error.InvalidPath;
    const real_parent = std.Io.Dir.realPathFileAbsoluteAlloc(io, parent, arena) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => error.NotFound,
        else => error.InvalidPath,
    };
    if (!roots.contains(real_parent)) return error.OutsideRoots;
    return std.fs.path.join(arena, &.{ real_parent, base }) catch error.OutOfMemory;
}

pub const WriteError = error{ AlreadyExists, WriteFailed, OutOfMemory };

/// Writes `bytes` to `abs` atomically (temporary file, then rename).
pub fn writeFileAtomic(io: Io, abs: []const u8, bytes: []const u8, overwrite: bool) WriteError!void {
    const dir_path = std.fs.path.dirname(abs) orelse return error.WriteFailed;
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{}) catch return error.WriteFailed;
    defer dir.close(io);
    const base = std.fs.path.basename(abs);
    // Some kernels and sandboxes (proot) emulate a no-replace rename with a
    // plain rename, so check first; link() still refuses on a race.
    if (!overwrite) {
        if (dir.statFile(io, base, .{})) |_| return error.AlreadyExists else |e| switch (e) {
            error.FileNotFound => {},
            else => return error.WriteFailed,
        }
    }
    var af = dir.createFileAtomic(io, base, .{ .replace = overwrite }) catch return error.WriteFailed;
    defer af.deinit(io);
    af.file.writeStreamingAll(io, bytes) catch return error.WriteFailed;
    if (overwrite) {
        af.replace(io) catch return error.WriteFailed;
    } else {
        af.link(io) catch |e| return switch (e) {
            error.PathAlreadyExists => error.AlreadyExists,
            else => error.WriteFailed,
        };
    }
    // An O_TMPFILE file can come out 0600 (seen under proot), and fchmod on
    // it before linking does not stick there; outputs are ordinary files, so
    // give them the usual rw-r--r-- once they have a name.
    dir.setFilePermissions(io, base, .fromMode(0o644), .{}) catch {};
}

test "roots contain only paths under them" {
    const r: Roots = .{ .list = &.{"/srv/data"} };
    try std.testing.expect(r.contains("/srv/data"));
    try std.testing.expect(r.contains("/srv/data/a/b.glb"));
    try std.testing.expect(!r.contains("/srv/database"));
    try std.testing.expect(!r.contains("/srv"));
}

test "resolveOutput refuses traversal outside the root" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.createDirPath(io, "root/sub");
    const root_abs = try tmp.dir.realPathFileAlloc(io, "root", arena);
    const roots: Roots = .{ .list = &.{root_abs} };
    const ok = try resolveOutput(io, arena, roots, "sub/out.glb");
    try std.testing.expect(std.mem.endsWith(u8, ok, "/root/sub/out.glb"));
    try std.testing.expectError(error.OutsideRoots, resolveOutput(io, arena, roots, "../escape.glb"));
    try std.testing.expectError(error.OutsideRoots, resolveOutput(io, arena, roots, "/etc/passwd"));
    try std.testing.expectError(error.NotFound, resolveOutput(io, arena, roots, "missing/dir/x.glb"));
    try writeFileAtomic(io, ok, "abc", false);
    try std.testing.expectError(error.AlreadyExists, writeFileAtomic(io, ok, "abc", false));
    try writeFileAtomic(io, ok, "abcd", true);
}

test "written files are readable by others" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena_state.allocator());
    const path = try std.fs.path.join(arena_state.allocator(), &.{ root, "f.bin" });
    try writeFileAtomic(io, path, "x", false);
    const st = try tmp.dir.statFile(io, "f.bin", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o644), st.permissions.toMode() & 0o777);
}
