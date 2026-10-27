//! render.preview: fast rasterised feedback for agents.

const std = @import("std");
const math = @import("math");
const engine = @import("engine");
const render = @import("render");
const io = @import("io");
const ir = @import("ir");
const server = @import("../server.zig");
const common = @import("common.zig");
const paths = @import("../paths.zig");

const Call = server.Call;
const Tool = server.Tool;
const HandlerError = server.HandlerError;

/// Long edge of the image returned inline, so a model can look at it
/// without filling its context (TRD §8).
pub const inline_max_edge = 1024;

pub const tools = [_]Tool{
    .{
        .name = "render.preview",
        .title = "Preview render",
        .description = "Render a quick shaded preview (Lambert, key light from the camera) through the active camera, or an automatic 3/4 view if there is none, and return it as a PNG. Lists which objects are visible and how many pixels each covers. Default size: long edge 512 px at the scene's aspect ratio. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"width\":640,\"height\":360,\"wireframe\":true}.",
        .params = common.reading(&.{
            .{ .name = "width", .type = .{ .integer = .{ .min = 16, .max = 8192 } }, .doc = "Image width in px" },
            .{ .name = "height", .type = .{ .integer = .{ .min = 16, .max = 8192 } }, .doc = "Image height in px" },
            .{ .name = "camera", .type = .{ .name_ref = .{} }, .doc = "Camera object; default the active camera" },
            .{ .name = "wireframe", .type = .boolean, .doc = "Overlay mesh edges", .default = .{ .boolean = false } },
            .{ .name = "transparent", .type = .boolean, .doc = "Transparent background", .default = .{ .boolean = false } },
            .{ .name = "path", .type = .{ .string = .{ .max_len = 4096 } }, .doc = "Also write the PNG here (inside an allowed root)" },
            .{ .name = "overwrite", .type = .boolean, .doc = "Replace an existing file at path", .default = .{ .boolean = false } },
        }),
        .kind = .read_only,
        .idempotent = true,
        .handler = preview,
    },
};

fn preview(c: *Call) HandlerError!void {
    const s = c.server;
    const e = c.entry.?;
    const doc = &e.doc;
    const scene_data = doc.sceneData();
    const scene = try c.evaluateFor(.viewport);

    // Size: explicit, or long edge 512 at the scene aspect.
    const rx: f32 = @floatFromInt(scene_data.resolution_x);
    const ry: f32 = @floatFromInt(scene_data.resolution_y);
    var width: u32 = if (rx >= ry) 512 else @intFromFloat(@max(16, @round(512 * rx / ry)));
    var height: u32 = if (rx >= ry) @intFromFloat(@max(16, @round(512 * ry / rx))) else 512;
    if (c.args.int("width")) |w| {
        width = @intCast(w);
        if (!c.args.has("height")) height = @intFromFloat(@max(16, @round(@as(f32, @floatFromInt(width)) * ry / rx)));
    }
    if (c.args.int("height")) |h| {
        height = @intCast(h);
        if (!c.args.has("width")) width = @intFromFloat(@max(16, @round(@as(f32, @floatFromInt(height)) * rx / ry)));
    }
    const max_edge = s.config.budgets.max_render_edge;
    if (width > max_edge or height > max_edge) {
        return c.failAt(.budget_exceeded, "/width", "", &.{}, "render edge {d} px is over the {d} px budget", .{ @max(width, height), max_edge });
    }

    var cam_node: ?u32 = null;
    if (c.args.str("camera")) |name| {
        const h = try c.lookup(.object, name, "/camera");
        const ob = doc.db.get(.object, h).?;
        if (ob.kind != .camera) return c.failAt(.invalid_argument, "/camera", "", &.{}, "'{s}' is not a camera", .{name});
        for (scene.nodes, 0..) |n, i| if (std.mem.eql(u8, n.name, ob.name.slice())) {
            cam_node = @intCast(i);
        };
    }

    const gpa = s.gpa;
    var result = render.preview.render(gpa, &scene, .{
        .width = width,
        .height = height,
        .camera = cam_node,
        .wireframe = c.args.boolean("wireframe").?,
        .transparent = c.args.boolean("transparent").?,
        .pool = s.pool,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidCamera => return c.fail(.invalid_argument, "the camera cannot be used for rendering (singular transform)", .{}),
        error.DeadlineExceeded => return error.ToolFailed, // reported by the command core
    };
    defer result.deinit(gpa);

    var png: std.Io.Writer.Allocating = .init(gpa);
    defer png.deinit();
    io.png.encode(gpa, .{ .width = width, .height = height, .channels = 4, .pixels = result.rgba }, .fast, &png.writer) catch return error.OutOfMemory;
    const full = try png.toOwnedSlice();
    var full_owned = true;
    defer if (full_owned) gpa.free(full);

    if (c.args.str("path")) |p| {
        const abs = paths.resolveOutput(s.io, c.arena, s.config.roots, p) catch |err| return pathFailure(c, err, p);
        paths.writeFileAtomic(s.io, abs, full, c.args.boolean("overwrite").?) catch |err| switch (err) {
            error.AlreadyExists => return c.failAt(.io_error, "/path", "pass overwrite: true to replace it", &.{}, "'{s}' already exists", .{p}),
            error.OutOfMemory => return error.OutOfMemory,
            error.WriteFailed => return c.failAt(.io_error, "/path", "", &.{}, "could not write '{s}'", .{p}),
        };
        try c.field("path");
        try c.out.write(abs);
    }

    // Inline copy, downscaled when large.
    const long = @max(width, height);
    var inline_png: []const u8 = full;
    if (long > inline_max_edge) {
        const f = @as(f32, @floatFromInt(inline_max_edge)) / @as(f32, @floatFromInt(long));
        const sw: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(width)) * f))));
        const sh: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(height)) * f))));
        const small = try downscale(c.arena, result.rgba, width, height, sw, sh);
        var out: std.Io.Writer.Allocating = .init(c.arena);
        io.png.encode(c.arena, .{ .width = sw, .height = sh, .channels = 4, .pixels = small }, .fast, &out.writer) catch return error.OutOfMemory;
        inline_png = out.written();
    } else {
        inline_png = try c.arena.dupe(u8, full);
    }

    full_owned = false;
    const job = s.storeRender(e, full, width, height) catch |err| {
        gpa.free(full);
        return err;
    };
    const uri = try std.fmt.allocPrint(c.arena, "zender://scene/{s}/render/{d}", .{ e.id, job });
    c.image = .{ .mime = "image/png", .bytes = inline_png };
    try c.link(uri, try std.fmt.allocPrint(c.arena, "render-{d}.png", .{job}), "image/png");

    // Which objects are visible, by covered pixels.
    const counts = try c.arena.alloc(u32, scene.nodes.len + 1);
    @memset(counts, 0);
    for (result.object_id) |id| counts[id] += 1;
    const total: f32 = @floatFromInt(result.object_id.len);
    try c.field("width");
    try c.out.write(width);
    try c.field("height");
    try c.out.write(height);
    try c.field("camera");
    try c.out.write(result.camera_name);
    // After near-plane clipping and culling of triangles that cover no pixel.
    try c.field("triangles_drawn");
    try c.out.write(result.triangles);
    try c.field("render");
    try c.out.write(uri);
    try c.field("coverage");
    try engine.core.registry.writeF32(&c.out, @round((1 - @as(f32, @floatFromInt(counts[0])) / total) * 1e4) / 1e4);
    try c.field("visible");
    try c.out.beginArray();
    var n_visible: usize = 0;
    for (scene.nodes, 0..) |n, i| {
        if (counts[i + 1] == 0) continue;
        n_visible += 1;
        try c.out.beginObject();
        try c.out.objectField("object");
        try c.out.write(n.name);
        try c.out.objectField("pixels");
        try c.out.write(counts[i + 1]);
        try c.out.endObject();
    }
    try c.out.endArray();
    // Meshes with no pixels are often a mistake worth surfacing.
    for (scene.nodes, 0..) |n, i| {
        if (n.kind == .mesh and !n.hide_render and !n.hide_viewport and counts[i + 1] == 0) try c.warn("'{s}' is not visible in this view", .{n.name});
    }
    try c.say("Rendered {d}x{d} preview through {s}: {d} object(s) visible.", .{ width, height, result.camera_name, n_visible });
}

/// Box-filter downscale of sRGB RGBA (filtering in sRGB is fine for a preview).
fn downscale(arena: std.mem.Allocator, src: []const u8, w: u32, h: u32, dw: u32, dh: u32) ![]u8 {
    const out = try arena.alloc(u8, @as(usize, dw) * dh * 4);
    for (0..dh) |y| {
        const y0 = y * h / dh;
        const y1 = @max(y0 + 1, (y + 1) * h / dh);
        for (0..dw) |x| {
            const x0 = x * w / dw;
            const x1 = @max(x0 + 1, (x + 1) * w / dw);
            var acc = [4]u32{ 0, 0, 0, 0 };
            for (y0..y1) |sy| for (x0..x1) |sx| {
                const p = src[(sy * w + sx) * 4 ..][0..4];
                for (0..4) |k| acc[k] += p[k];
            };
            const n: u32 = @intCast((y1 - y0) * (x1 - x0));
            const d = out[(y * dw + x) * 4 ..][0..4];
            for (0..4) |k| d[k] = @intCast((acc[k] + n / 2) / n);
        }
    }
    return out;
}

pub fn pathFailure(c: *Call, err: paths.PathError, p: []const u8) HandlerError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.OutsideRoots, error.NoRoots => c.failAt(.permission_denied, "/path", "paths must lie inside a directory the server was started with (--allow-root); relative paths start at the first one", c.server.config.roots.list, "'{s}' is outside the allowed roots", .{p}),
        error.NotFound => c.failAt(.not_found, "/path", "the parent directory must already exist", &.{}, "directory for '{s}' not found", .{p}),
        error.InvalidPath => c.failAt(.invalid_argument, "/path", "", &.{}, "invalid path '{s}'", .{p}),
    };
}
