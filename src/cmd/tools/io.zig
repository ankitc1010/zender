//! io.export.

const std = @import("std");
const engine = @import("engine");
const io = @import("io");
const server = @import("../server.zig");
const common = @import("common.zig");
const paths = @import("../paths.zig");
const render_tools = @import("render.zig");

const Call = server.Call;
const Tool = server.Tool;
const HandlerError = server.HandlerError;

pub const tools = [_]Tool{
    .{
        .name = "io.export",
        .title = "Export file",
        .description = "Write the scene to a file inside an allowed root: .glb (binary glTF 2.0) or .gltf (JSON, embedded buffer). Converts Z-up to glTF's Y-up as Blender does; render-hidden objects are skipped unless include_hidden. Reports anything the format could not carry. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"path\":\"out/table.glb\"}.",
        .params = common.reading(&.{
            .{ .name = "path", .type = .{ .string = .{ .max_len = 4096 } }, .doc = "Output path; relative paths start at the first allowed root", .required = true },
            .{ .name = "format", .type = .{ .enumeration = &.{ "auto", "glb", "gltf" } }, .doc = "File format; auto picks from the extension", .default = .{ .string = "auto" } },
            .{ .name = "overwrite", .type = .boolean, .doc = "Replace an existing file", .default = .{ .boolean = false } },
            .{ .name = "include_hidden", .type = .boolean, .doc = "Also export objects hidden from render", .default = .{ .boolean = false } },
        }),
        .kind = .read_only,
        .destructive = true,
        .open_world = true,
        .handler = exportFile,
    },
};

fn exportFile(c: *Call) HandlerError!void {
    const s = c.server;
    const p = c.args.str("path").?;
    var format = c.args.str("format").?;
    if (std.mem.eql(u8, format, "auto")) {
        const ext = std.fs.path.extension(p);
        if (std.ascii.eqlIgnoreCase(ext, ".glb")) {
            format = "glb";
        } else if (std.ascii.eqlIgnoreCase(ext, ".gltf")) {
            format = "gltf";
        } else {
            return c.failAt(.invalid_argument, "/path", "use a .glb or .gltf extension, or set format", &.{ "glb", "gltf" }, "cannot tell the format of '{s}'", .{p});
        }
    }
    const abs = paths.resolveOutput(s.io, c.arena, s.config.roots, p) catch |err| return render_tools.pathFailure(c, err, p);

    const scene = try c.evaluate();
    var out: std.Io.Writer.Allocating = .init(c.arena);
    const report = io.gltf.write(c.arena, scene, .{
        .format = if (std.mem.eql(u8, format, "glb")) .glb else .gltf,
        .generator = "Zender " ++ server.version,
        .skip_hidden = !c.args.boolean("include_hidden").?,
    }, &out.writer) catch return error.OutOfMemory;

    paths.writeFileAtomic(s.io, abs, out.written(), c.args.boolean("overwrite").?) catch |err| switch (err) {
        error.AlreadyExists => return c.failAt(.io_error, "/path", "pass overwrite: true to replace it", &.{}, "'{s}' already exists", .{p}),
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return c.failAt(.io_error, "/path", "", &.{}, "could not write '{s}'", .{p}),
    };
    for (report.dropped) |d| try c.warn("not exported: {s}", .{d});
    try c.field("path");
    try c.out.write(abs);
    try c.field("format");
    try c.out.write(format);
    try c.field("bytes");
    try c.out.write(report.bytes);
    try c.field("nodes");
    try c.out.write(report.nodes);
    try c.field("meshes");
    try c.out.write(report.meshes);
    try c.field("triangles");
    try c.out.write(report.triangles);
    try c.field("dropped");
    try c.out.write(report.dropped);
    try c.say("Exported {d} node(s), {d} triangles to {s} ({d} bytes).", .{ report.nodes, report.triangles, abs, report.bytes });
}
