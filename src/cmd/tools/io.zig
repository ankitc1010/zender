//! io.export and io.import.

const std = @import("std");
const math = @import("math");
const engine = @import("engine");
const io = @import("io");
const ir = @import("ir");
const server = @import("../server.zig");
const common = @import("common.zig");
const paths = @import("../paths.zig");
const render_tools = @import("render.zig");

const core = engine.core;
const Call = server.Call;
const Tool = server.Tool;
const HandlerError = server.HandlerError;

pub const tools = [_]Tool{
    .{
        .name = "io.export",
        .title = "Export file",
        .description = "Write the scene to a file inside an allowed root: .glb (binary glTF 2.0), .gltf (JSON, embedded buffer), .obj (+ .mtl beside it), .stl (binary), .ply (binary), or .json (canonical scene.json for diffs: every datablock by name, mesh arrays as digests unless geometry is full). glTF and OBJ convert Z-up to Y-up as Blender does; OBJ, STL and PLY bake world transforms into one mesh list. Render-hidden objects are skipped unless include_hidden; anything a format cannot carry is reported. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"path\":\"out/table.glb\"}.",
        .params = common.reading(&.{
            .{ .name = "path", .type = .{ .string = .{ .max_len = 4096 } }, .doc = "Output path; relative paths start at the first allowed root", .required = true },
            .{ .name = "format", .type = .{ .enumeration = &.{ "auto", "glb", "gltf", "obj", "stl", "ply", "json" } }, .doc = "File format; auto picks from the extension", .default = .{ .string = "auto" } },
            .{ .name = "geometry", .type = .{ .enumeration = &.{ "digest", "full" } }, .doc = "scene.json mesh arrays: digests or full data", .default = .{ .string = "digest" } },
            .{ .name = "overwrite", .type = .boolean, .doc = "Replace an existing file", .default = .{ .boolean = false } },
            .{ .name = "include_hidden", .type = .boolean, .doc = "Also export objects hidden from render", .default = .{ .boolean = false } },
        }),
        .kind = .read_only,
        .destructive = true,
        .open_world = true,
        .handler = exportFile,
    },
    .{
        .name = "io.import",
        .title = "Import file",
        .description = "Add the meshes of an .obj (with its .mtl), .stl or .ply file inside an allowed root as new objects. OBJ is read Y-up and converted to Z-up as Blender does; STL and PLY stay Z-up. N-gons, UVs, material slots and smooth shading are kept; everything else is listed in dropped. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"path\":\"models/chair.obj\"}.",
        .params = common.mutating(&.{
            .{ .name = "path", .type = .{ .string = .{ .max_len = 4096 } }, .doc = "File to read; relative paths start at the first allowed root", .required = true },
            .{ .name = "format", .type = .{ .enumeration = &.{ "auto", "obj", "stl", "ply" } }, .doc = "File format; auto picks from the extension", .default = .{ .string = "auto" } },
            .{ .name = "scale", .type = .{ .number = .{ .min = 1e-6, .max = 1e6 } }, .doc = "Multiply coordinates, e.g. 0.001 for a file in millimetres", .default = .{ .number = 1 } },
            common.location,
        }),
        .kind = .mutating,
        .open_world = true,
        .handler = importFile,
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
        } else if (std.ascii.eqlIgnoreCase(ext, ".json")) {
            format = "json";
        } else if (meshFormat(ext)) |f| {
            format = @tagName(f);
        } else {
            return c.failAt(.invalid_argument, "/path", "use a .glb, .gltf, .obj, .stl, .ply or .json extension, or set format", &.{ "glb", "gltf", "obj", "stl", "ply", "json" }, "cannot tell the format of '{s}'", .{p});
        }
    }
    const abs = paths.resolveOutput(s.io, c.arena, s.config.roots, p) catch |err| return render_tools.pathFailure(c, err, p);
    if (std.mem.eql(u8, format, "json")) return exportCanonical(c, abs, p);
    if (std.meta.stringToEnum(MeshFormat, format)) |f| return exportMeshFile(c, f, abs, p);

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

const MeshFormat = enum { obj, stl, ply };

fn meshFormat(ext: []const u8) ?MeshFormat {
    inline for (std.meta.fields(MeshFormat)) |f| {
        if (std.ascii.eqlIgnoreCase(ext, "." ++ f.name)) return @enumFromInt(f.value);
    }
    return null;
}

fn writeOut(c: *Call, abs: []const u8, p: []const u8, bytes: []const u8, overwrite: bool) HandlerError!void {
    paths.writeFileAtomic(c.server.io, abs, bytes, overwrite) catch |err| switch (err) {
        error.AlreadyExists => return c.failAt(.io_error, "/path", "pass overwrite: true to replace it", &.{}, "'{s}' already exists", .{p}),
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return c.failAt(.io_error, "/path", "", &.{}, "could not write '{s}'", .{p}),
    };
}

fn exportMeshFile(c: *Call, format: MeshFormat, abs: []const u8, p: []const u8) HandlerError!void {
    const s = c.server;
    const overwrite = c.args.boolean("overwrite").?;
    const scene = try c.evaluate();
    const opts: io.meshfile.ExportOptions = .{ .skip_hidden = !c.args.boolean("include_hidden").? };
    const generator = "Zender " ++ server.version;
    var out: std.Io.Writer.Allocating = .init(c.arena);
    var mtl: std.Io.Writer.Allocating = .init(c.arena);
    // The .mtl goes beside the .obj, with its stem.
    var mtl_abs: ?[]const u8 = null;
    if (format == .obj) {
        const dir = std.fs.path.dirname(abs).?;
        const name = try std.fmt.allocPrint(c.arena, "{s}.mtl", .{std.fs.path.stem(abs)});
        mtl_abs = try std.fs.path.join(c.arena, &.{ dir, name });
        if (!overwrite) if (paths.resolveInput(s.io, c.arena, s.config.roots, mtl_abs.?)) |_| {
            return c.failAt(.io_error, "/path", "pass overwrite: true to replace it, or pick another name", &.{}, "'{s}' already exists", .{name});
        } else |_| {};
    }
    const report = switch (format) {
        .obj => io.obj.write(c.arena, scene, .{ .base = opts, .generator = generator, .mtl_name = std.fs.path.basename(mtl_abs.?) }, &out.writer, &mtl.writer),
        .stl => io.stl.write(c.arena, scene, opts, &out.writer),
        .ply => io.ply.write(c.arena, scene, opts, generator, &out.writer),
    } catch return error.OutOfMemory;
    if (report.objects == 0) return c.fail(.invalid_operation, "the scene has no {s}mesh objects to write", .{if (opts.skip_hidden) "visible " else ""});
    try writeOut(c, abs, p, out.written(), overwrite);
    if (mtl.written().len > 0) try writeOut(c, mtl_abs.?, mtl_abs.?, mtl.written(), overwrite);
    for (report.dropped) |d| try c.warn("not exported: {s}", .{d});
    try c.field("path");
    try c.out.write(abs);
    if (mtl.written().len > 0) {
        try c.field("mtl_path");
        try c.out.write(mtl_abs.?);
    }
    try c.field("format");
    try c.out.write(@tagName(format));
    try c.field("bytes");
    try c.out.write(out.written().len);
    try c.field("objects");
    try c.out.write(report.objects);
    try c.field("faces");
    try c.out.write(report.faces);
    try c.field("triangles");
    try c.out.write(report.triangles);
    try c.field("dropped");
    try c.out.write(report.dropped);
    try c.say("Exported {d} object(s), {d} faces to {s} ({d} bytes).", .{ report.objects, report.faces, abs, out.written().len });
}

fn importFile(c: *Call) HandlerError!void {
    const s = c.server;
    const p = c.args.str("path").?;
    const format = std.meta.stringToEnum(MeshFormat, c.args.str("format").?) orelse meshFormat(std.fs.path.extension(p)) orelse {
        return c.failAt(.invalid_argument, "/path", "use an .obj, .stl or .ply file, or set format", &.{ "obj", "stl", "ply" }, "cannot tell the format of '{s}'", .{p});
    };
    const abs = paths.resolveInput(s.io, c.arena, s.config.roots, p) catch |err| return inputFailure(c, err, p, "/path");
    const bytes = try readInput(c, abs, p, "/path");
    const stem = std.fs.path.stem(abs);
    var dropped: std.ArrayList([]const u8) = .empty;
    var imported: io.meshfile.Imported = switch (format) {
        .obj => blk: {
            const parsed = try io.obj.parse(c.arena, bytes, stem);
            try dropped.appendSlice(c.arena, parsed.dropped);
            const mats = try c.arena.alloc(ir.Material, parsed.material_names.len);
            for (mats, parsed.material_names) |*m, n| m.* = io.obj.defaultMaterial(n);
            const dir = std.fs.path.dirname(abs).?;
            for (parsed.libraries) |lib| {
                const lib_path = try std.fs.path.join(c.arena, &.{ dir, lib });
                const lib_abs = paths.resolveInput(s.io, c.arena, s.config.roots, lib_path) catch {
                    try dropped.append(c.arena, try std.fmt.allocPrint(c.arena, "material library '{s}' (not found inside the allowed roots; materials keep default values)", .{lib}));
                    continue;
                };
                try io.obj.parseMtl(c.arena, try readInput(c, lib_abs, lib, "/path"), mats, &dropped);
            }
            break :blk .{ .objects = parsed.objects, .materials = mats, .dropped = &.{} };
        },
        .stl => io.stl.parse(c.arena, bytes, stem) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidFile => return c.failAt(.invalid_argument, "/path", "", &.{}, "'{s}' is not a valid STL file", .{p}),
        },
        .ply => io.ply.parse(c.arena, bytes, stem) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidFile => return c.failAt(.invalid_argument, "/path", "", &.{}, "'{s}' is not a valid PLY file", .{p}),
        },
    };
    try dropped.appendSlice(c.arena, imported.dropped);
    imported.dropped = dropped.items;
    var tris: u64 = 0;
    for (imported.objects) |o| {
        for (0..o.face_offsets.len -| 1) |f| tris += o.face_offsets[f + 1] - o.face_offsets[f] - 2;
    }
    if (tris == 0) return c.failAt(.invalid_argument, "/path", "", &.{}, "'{s}' has no faces", .{p});
    try c.spendTriangles(tris);

    const doc = c.doc();
    const gpa = doc.gpa;
    const scale: f32 = @floatCast(c.args.float("scale").?);
    const location = c.args.vec3("location").?;
    // Materials the objects use, created once each.
    const mat_handles = try c.arena.alloc(?core.IdHandle, imported.materials.len);
    @memset(mat_handles, null);
    try c.field("objects");
    try c.out.beginArray();
    var verts: usize = 0;
    var faces: usize = 0;
    for (imported.objects) |o| {
        const pos = try c.arena.alloc(math.Vec3, o.positions.len);
        for (o.positions, pos) |q, *w| w.* = .{ q[0] * scale, q[1] * scale, q[2] * scale };
        var mesh = engine.geom.build.fromPolygons(gpa, .{
            .positions = pos,
            .face_offsets = o.face_offsets,
            .corner_verts = o.corner_verts,
            .corner_uvs = o.corner_uvs,
            .sharp_face = o.sharp_face,
            .material_index = o.material_index,
        }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return c.fail(.internal, "could not build a mesh from object '{s}' of '{s}'", .{ o.name, p }),
        };
        const mh = doc.db.create(.mesh, o.name, mesh) catch |e| {
            mesh.releaseRefs(gpa);
            return e;
        };
        const oh = core.edit.addObject(doc, o.name, .mesh, mh) catch return error.OutOfMemory;
        doc.db.get(.object, oh).?.location = location;
        for (o.slots, 0..) |mi, slot| {
            if (mat_handles[mi] == null) {
                const src = imported.materials[mi];
                const h = try doc.db.create(.material, src.name, .{
                    .base_color = src.base_color,
                    .metallic = src.metallic,
                    .roughness = src.roughness,
                    .ior = src.ior,
                    .alpha = src.alpha,
                    .emission_color = src.emission_color,
                    .emission_strength = src.emission_strength,
                });
                mat_handles[mi] = h;
                try c.markCreated(h, doc.db.get(.material, h).?.name.slice());
            }
            core.edit.assignMaterial(doc, oh, mat_handles[mi], slot) catch return error.OutOfMemory;
        }
        const m = doc.db.get(.mesh, mh).?;
        verts += m.vertCount();
        faces += m.faceCount();
        try c.markCreated(oh, doc.db.get(.object, oh).?.name.slice());
        try c.markCreated(mh, m.name.slice());
        try common.writeObjectSummary(c, &c.out, oh);
    }
    try c.out.endArray();
    for (imported.dropped) |d| try c.warn("not imported: {s}", .{d});
    try c.field("format");
    try c.out.write(@tagName(format));
    try c.field("dropped");
    try c.out.write(imported.dropped);
    try c.say("Imported {d} object(s) from {s}: {d} verts, {d} faces.", .{ imported.objects.len, std.fs.path.basename(abs), verts, faces });
}

fn inputFailure(c: *Call, err: paths.PathError, p: []const u8, at: []const u8) HandlerError {
    return switch (err) {
        error.NotFound => c.failAt(.not_found, at, "", &.{}, "'{s}' not found", .{p}),
        else => render_tools.pathFailure(c, err, p),
    };
}

/// Reads a whole input file, up to the scene memory budget.
fn readInput(c: *Call, abs: []const u8, p: []const u8, at: []const u8) HandlerError![]const u8 {
    const s = c.server;
    const limit: usize = @intCast(@min(s.config.budgets.max_scene_bytes, std.math.maxInt(usize)));
    return std.Io.Dir.cwd().readFileAlloc(s.io, abs, c.arena, .limited(limit)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => c.failAt(.budget_exceeded, at, "ask the operator to raise --max-scene-mb", &.{}, "'{s}' is larger than the scene memory budget", .{p}),
        else => c.failAt(.io_error, at, "", &.{}, "could not read '{s}'", .{p}),
    };
}

fn exportCanonical(c: *Call, abs: []const u8, p: []const u8) HandlerError!void {
    var out: std.Io.Writer.Allocating = .init(c.arena);
    var w: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_1 } };
    const full = std.mem.eql(u8, c.args.str("geometry").?, "full");
    engine.core.canonical.write(c.arena, c.doc(), &w, .{ .geometry = if (full) .full else .hash }) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    paths.writeFileAtomic(c.server.io, abs, out.written(), c.args.boolean("overwrite").?) catch |err| switch (err) {
        error.AlreadyExists => return c.failAt(.io_error, "/path", "pass overwrite: true to replace it", &.{}, "'{s}' already exists", .{p}),
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return c.failAt(.io_error, "/path", "", &.{}, "could not write '{s}'", .{p}),
    };
    try c.field("path");
    try c.out.write(abs);
    try c.field("format");
    try c.out.write("json");
    try c.field("bytes");
    try c.out.write(out.written().len);
    try c.say("Wrote scene.json to {s} ({d} bytes).", .{ abs, out.written().len });
}
