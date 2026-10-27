//! mesh.* tools: select and edit mesh elements (TRD §7). Every tool takes
//! a selector instead of a stored selection, works in world space, and
//! returns a `result` selector for the elements it leaves selected, so the
//! next call can target them.

const std = @import("std");
const math = @import("math");
const engine = @import("engine");
const server = @import("../server.zig");
const schema = @import("../schema.zig");
const selector = @import("../selector.zig");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const core = engine.core;
const geom = engine.geom;
const sel = geom.select;
const ops = geom.ops;
const EditMesh = geom.EditMesh;
const Mesh = core.types.Mesh;
const IdHandle = core.IdHandle;
const Call = server.Call;
const Tool = server.Tool;
const HandlerError = server.HandlerError;
const Param = schema.Param;
const v = math.vec;

const object_param: Param = .{ .name = "object", .type = .{ .name_ref = .{} }, .doc = "Mesh object", .required = true };

fn selectorParam(comptime domain: []const u8, comptime required: bool) Param {
    return .{
        .name = "selector",
        .type = .selector,
        .doc = "Elements, default domain " ++ domain ++ (if (required) "" else "; omitted = all") ++ ", e.g. {\"normal\":[0,0,1]}; grammar in mesh.select_preview",
        .required = required,
    };
}

const mode_param: Param = .{ .name = "mode", .type = .{ .enumeration = &.{ "region", "individual" } }, .doc = "region treats touching faces as one; individual does each face on its own", .default = .{ .string = "region" } };

pub const tools = [_]Tool{
    .{
        .name = "mesh.select_preview",
        .title = "Preview selection",
        .description = "Show what a selector picks on a mesh object, changing nothing: count, indices, world bounds, centre and (faces) mean normal. Every mesh.* tool takes the same selector and returns a 'result' selector for what it leaves selected. " ++ selector.summary ++ " Example: {\"scene_id\":\"scn_1a2b3c4d\",\"object\":\"Cube\",\"selector\":{\"normal\":[0,0,1],\"within\":10}}.",
        .params = common.reading(&.{ object_param, selectorParam("face", false) }),
        .kind = .read_only,
        .idempotent = true,
        .handler = selectPreview,
    },
    .{
        .name = "mesh.transform_elements",
        .title = "Transform elements",
        .description = "Move, rotate (Euler XYZ, deg) and scale selected vertices along world axes: scale, then rotate, about the pivot, then translate (m). Faces and edges move their vertices. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"object\":\"Cube\",\"selector\":{\"domain\":\"vert\",\"where\":\"z > 0\"},\"scale\":[0.5,0.5,1]}.",
        .params = common.mutating(&.{
            object_param,
            selectorParam("vert", true),
            .{ .name = "translate", .type = .{ .vec3 = .{ .min = -1e9, .max = 1e9, .unit = .metres } }, .doc = "Offset [x, y, z]", .default = .{ .vec3 = .{ 0, 0, 0 } } },
            .{ .name = "rotate", .type = .{ .vec3 = .{ .min = -1e6, .max = 1e6, .unit = .degrees } }, .doc = "Euler XYZ rotation about the pivot", .default = .{ .vec3 = .{ 0, 0, 0 } } },
            .{ .name = "scale", .type = .{ .vec3 = .{ .min = -1e6, .max = 1e6 } }, .doc = "Scale about the pivot", .default = .{ .vec3 = .{ 1, 1, 1 } } },
            .{ .name = "pivot", .type = .{ .enumeration = &.{ "median", "bounds", "origin", "point" } }, .doc = "median of the vertices, centre of their bounds, object origin, or 'point'", .default = .{ .string = "median" } },
            .{ .name = "point", .type = .{ .vec3 = .{ .min = -1e9, .max = 1e9, .unit = .metres } }, .doc = "Pivot when pivot is 'point'" },
        }),
        .kind = .mutating,
        .handler = transformElements,
    },
    .{
        .name = "mesh.extrude",
        .title = "Extrude",
        .description = "Extrude faces (region or individual), edges (into quads) or vertices (into edges) by a world offset (m) or a distance along the normal (m). The moved copies are the result. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"object\":\"Cube\",\"selector\":{\"normal\":[0,0,1]},\"distance\":0.5}.",
        .params = common.mutating(&.{
            object_param,
            selectorParam("face", true),
            .{ .name = "distance", .type = .{ .number = .{ .min = -1e6, .max = 1e6, .unit = .metres } }, .doc = "Move along the mean normal of the selection" },
            .{ .name = "offset", .type = .{ .vec3 = .{ .min = -1e6, .max = 1e6, .unit = .metres } }, .doc = "Move by [x, y, z] instead" },
            mode_param,
        }),
        .kind = .mutating,
        .handler = extrude,
    },
    .{
        .name = "mesh.inset",
        .title = "Inset faces",
        .description = "Inset faces: a smaller copy of each region (or face) with a rim of quads around it, its edges thickness (m) in from the old ones, then moved depth (m) along the normal (negative sinks it). The inner faces are the result. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"object\":\"Cube\",\"selector\":{\"normal\":[0,0,1]},\"thickness\":0.2,\"depth\":-0.1}.",
        .params = common.mutating(&.{
            object_param,
            selectorParam("face", true),
            .{ .name = "thickness", .type = .{ .number = .{ .min = 0, .max = 1e6, .unit = .metres } }, .doc = "Rim width", .default = .{ .number = 0.1 } },
            .{ .name = "depth", .type = .{ .number = .{ .min = -1e6, .max = 1e6, .unit = .metres } }, .doc = "Offset of the inner faces along their normals", .default = .{ .number = 0 } },
            mode_param,
        }),
        .kind = .mutating,
        .handler = inset,
    },
    .{
        .name = "mesh.triangulate",
        .title = "Triangulate",
        .description = "Split faces into triangles. Quads: beauty (best-shaped), fixed (corners 0-2), alternate (1-3), shortest_diagonal, longest_diagonal. N-gons: beauty or clip (ear clipping). The triangles are the result. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"object\":\"Cylinder\",\"selector\":{\"where\":\"abs(nz) > 0.9\"}}.",
        .params = common.mutating(&.{
            object_param,
            selectorParam("face", false),
            .{ .name = "quad_method", .type = .{ .enumeration = &.{ "beauty", "fixed", "alternate", "shortest_diagonal", "longest_diagonal" } }, .doc = "How quads split", .default = .{ .string = "beauty" } },
            .{ .name = "ngon_method", .type = .{ .enumeration = &.{ "beauty", "clip" } }, .doc = "How faces of 5+ corners split", .default = .{ .string = "beauty" } },
        }),
        .kind = .mutating,
        .handler = triangulate,
    },
    .{
        .name = "mesh.merge",
        .title = "Merge vertices",
        .description = "Merge selected vertices: center (all into one at their mean), collapse (each connected group into its mean) or distance (weld those within threshold m, Blender's Merge by Distance). Collapsed faces are removed; surviving vertices are the result. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"object\":\"Cube\",\"selector\":{},\"mode\":\"distance\",\"threshold\":0.001}.",
        .params = common.mutating(&.{
            object_param,
            selectorParam("vert", true),
            .{ .name = "mode", .type = .{ .enumeration = &.{ "center", "collapse", "distance" } }, .doc = "How to merge", .default = .{ .string = "center" } },
            .{ .name = "threshold", .type = .{ .number = .{ .min = 0, .max = 1e6, .unit = .metres } }, .doc = "Merge distance for mode distance", .default = .{ .number = 0.0001 } },
        }),
        .kind = .mutating,
        .handler = merge,
    },
};

const Target = struct {
    ob: IdHandle,
    mh: IdHandle,
    world: math.Mat4,
    /// Null when the world matrix is singular.
    xf: ?ops.Xform,

    fn mesh(t: Target, c: *Call) *Mesh {
        return c.doc().db.get(.mesh, t.mh).?;
    }

    fn name(t: Target, c: *Call) []const u8 {
        return c.doc().db.get(.object, t.ob).?.name.slice();
    }

    /// The transform editing tools need: world-space parameters must map
    /// back into the mesh.
    fn editXform(t: Target, c: *Call) HandlerError!ops.Xform {
        return t.xf orelse c.failAt(.invalid_operation, "/object", "give the object a non-zero scale on every axis with object.transform", &.{}, "'{s}' has zero scale on some axis, so world-space edits cannot map back into its mesh", .{t.name(c)});
    }
};

fn target(c: *Call) HandlerError!Target {
    const oh = try c.object("object");
    const doc = c.doc();
    const ob = doc.db.get(.object, oh).?;
    const mh = (if (ob.kind == .mesh) ob.data else null) orelse {
        return c.failAt(.invalid_argument, "/object", "mesh tools work on mesh objects, e.g. ones from object.add_primitive", &.{}, "'{s}' is a {s}, not a mesh", .{ ob.name.slice(), @tagName(ob.kind) });
    };
    if (doc.db.get(.mesh, mh) == null) return c.failAt(.stale_handle, "/object", "", &.{}, "the mesh of '{s}' is missing", .{ob.name.slice()});
    const world = core.edit.worldMatrix(&doc.db, oh) catch return error.OutOfMemory;
    return .{ .ob = oh, .mh = mh, .world = world, .xf = ops.Xform.init(world) };
}

const Selection = struct {
    s: sel.Selector,
    bits: sel.Bits,
};

fn evaluate(c: *Call, t: Target, default_domain: sel.Domain, allow_empty: bool) HandlerError!Selection {
    var failure: schema.Failure = undefined;
    const s = (try selector.parse(c.arena, c.args.value("selector"), default_domain, "/selector", &failure)) orelse {
        return c.failAt(.invalid_argument, failure.path, failure.hint, failure.valid_values, "{s}", .{failure.message});
    };
    const m = t.mesh(c);
    var diag: sel.Diag = .{};
    const bits = sel.evaluate(c.arena, m, s, t.world, &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IndexOutOfRange => return c.failAt(.invalid_argument, "/selector", "indices change after topology edits: use the 'result' of the last call, or select by rule", &.{}, "index {d} is out of range: '{s}' has {d} {s}", .{ diag.index, t.name(c), s.domain.count(m), s.domain.plural() }),
        error.FieldNotInDomain => return c.failAt(.invalid_argument, "/selector/where", "area applies to faces and length to edges; set domain to match", &.{}, "a where comparison does not apply to {s}", .{s.domain.plural()}),
        error.UnknownAttribute, error.AttributeNotScalar => return c.failAt(.not_found, "/selector", "where compares x y z nx ny nz area length index or a scalar attribute of the selector's domain", try scalarAttributes(c, m, s.domain), "'{s}' is not a scalar {s} attribute of '{s}'", .{ diag.attribute, @tagName(s.domain), t.name(c) }),
    };
    if (!allow_empty and bits.count() == 0) {
        // A common slip: a vertex's normal averages its faces', so a cube
        // corner points 55 degrees away from each face it touches.
        const hint = if (s.domain == .vert and s.root.normal != null)
            "vertex normals average their faces' normals; to pick a face's vertices use domain face with normal, or widen within"
        else
            "check it with mesh.select_preview; positions and normals are in world space unless space is local";
        return c.failAt(.invalid_argument, "/selector", hint, &.{}, "the selector matched no {s} of '{s}'", .{ s.domain.plural(), t.name(c) });
    }
    return .{ .s = s, .bits = bits };
}

fn scalarAttributes(c: *Call, m: *const Mesh, d: sel.Domain) HandlerError![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    const want: core.types.Domain = switch (d) {
        .vert => .point,
        .edge => .edge,
        .face => .face,
    };
    for (m.attrs[0..m.attr_count]) |*a| {
        if (a.domain != want) continue;
        switch (a.data) {
            .float, .int, .boolean => try list.append(c.arena, try c.arena.dupe(u8, a.name.slice())),
            else => {},
        }
    }
    return list.items;
}

/// "face" or "faces" by count, for summaries.
fn noun(d: sel.Domain, n: usize) []const u8 {
    const p = d.plural();
    return if (n == 1) p[0 .. p.len - 1] else p;
}

fn indices(c: *Call, bits: *const sel.Bits) HandlerError![]u32 {
    const out = try c.arena.alloc(u32, bits.count());
    var it = bits.iterator(.{});
    var i: usize = 0;
    while (it.next()) |x| : (i += 1) out[i] = @intCast(x);
    return out;
}

fn writeCounts(c: *Call, m: *const Mesh) HandlerError!void {
    try c.field("counts");
    try c.out.beginObject();
    try c.out.objectField("verts");
    try c.out.write(m.vertCount());
    try c.out.objectField("edges");
    try c.out.write(m.edgeCount());
    try c.out.objectField("faces");
    try c.out.write(m.faceCount());
    try c.out.objectField("triangles");
    try c.out.write(m.triangleCount());
    try c.out.endObject();
}

/// Writes `result`: a selector for `sorted` in `domain`.
fn writeResult(c: *Call, domain: sel.Domain, sorted: []const u32) HandlerError!void {
    try c.field("result");
    try c.out.beginObject();
    try c.out.objectField("domain");
    try c.out.write(@tagName(domain));
    try c.out.objectField("index");
    if (!try selector.writeIndices(&c.out, sorted, 4096)) {
        try c.warn("the result has more than 4096 index runs and was cut short; select by rule instead", .{});
    }
    try c.out.endObject();
}

fn noteShared(c: *Call, t: Target) HandlerError!void {
    const users = core.edit.userCount(&c.doc().db, t.mh);
    if (users > 1) try c.warn("mesh '{s}' is shared by {d} objects; all of them change", .{ t.mesh(c).name.slice(), users });
}

fn selectPreview(c: *Call) HandlerError!void {
    const t = try target(c);
    const s = try evaluate(c, t, .face, true);
    const m = t.mesh(c);
    const n = s.bits.count();
    const total = s.s.domain.count(m);
    try c.field("object");
    try c.out.write(t.name(c));
    try c.field("domain");
    try c.out.write(@tagName(s.s.domain));
    try c.field("count");
    try c.out.write(n);
    try c.field("total");
    try c.out.write(total);
    try c.field("index");
    if (!try selector.writeIndices(&c.out, try indices(c, &s.bits), 64)) {
        try c.field("index_truncated");
        try c.out.write(true);
    }
    const view: ops.Xform = t.xf orelse .{ .m = t.world, .inv = v.identity, .nm = v.identity };
    var verts = try sel.toVerts(c.arena, m, s.s.domain, &s.bits);
    if (ops.transform.bounds(m.positions.slice(), &verts, view)) |b| {
        try c.field("bounds");
        try common.writeBounds(&c.out, b);
        try c.field("center");
        try common.writeVec(&c.out, ops.transform.median(m.positions.slice(), &verts, view));
    }
    if (s.s.domain == .face and n > 0) {
        // Area-weighted: Newell vectors through the inverse-transpose.
        const off = m.face_offsets.slice();
        const cv = m.corner_verts.slice();
        var acc: math.Vec3 = .{ 0, 0, 0 };
        var it = s.bits.iterator(.{});
        while (it.next()) |f| acc = v.add(acc, v.transformDir(view.nm, math.triangulate.newellNormal(m.positions.slice(), cv[off[f]..off[f + 1]])));
        if (v.length(acc) > 0) {
            try c.field("normal");
            try common.writeVec(&c.out, v.normalize(acc));
        }
    }
    try writeCounts(c, m);
    try c.say("Selector matches {d} of {d} {s} of '{s}'.", .{ n, total, s.s.domain.plural(), t.name(c) });
}

fn transformElements(c: *Call) HandlerError!void {
    const t = try target(c);
    const xf = try t.editXform(c);
    const s = try evaluate(c, t, .vert, false);
    const m = t.mesh(c);
    var verts = try sel.toVerts(c.arena, m, s.s.domain, &s.bits);
    const pos_ro = m.positions.slice();
    const pivot = std.meta.stringToEnum(enum { median, bounds, origin, point }, c.args.str("pivot").?).?;
    const center: math.Vec3 = switch (pivot) {
        .median => ops.transform.median(pos_ro, &verts, xf),
        .bounds => blk: {
            const b = ops.transform.bounds(pos_ro, &verts, xf).?;
            break :blk v.scale(v.add(b[0], b[1]), 0.5);
        },
        .origin => v.translation(t.world),
        .point => c.args.vec3("point") orelse return c.failAt(.invalid_argument, "/point", "", &.{}, "pivot 'point' needs point [x, y, z]", .{}),
    };
    const rotate = c.args.vec3("rotate").?;
    const p: ops.transform.Params = .{
        .translate = c.args.vec3("translate").?,
        .rotate = v.eulerToQuat(common.degVec(rotate), .xyz),
        .scale = c.args.vec3("scale").?,
        .pivot = center,
    };
    const zero: math.Vec3 = .{ 0, 0, 0 };
    const one: math.Vec3 = .{ 1, 1, 1 };
    const identity = std.mem.eql(f32, &p.translate, &zero) and std.mem.eql(f32, &rotate, &zero) and std.mem.eql(f32, &p.scale, &one);
    if (identity) {
        try c.warn("translate, rotate and scale are all neutral; nothing moved", .{});
    } else {
        ops.transform.apply(try m.positions.mut(c.doc().gpa), &verts, xf, p);
        for (m.positions.slice()) |q| for (q) |x| if (!std.math.isFinite(x)) {
            return c.fail(.invalid_argument, "the transform produced non-finite positions; nothing changed", .{});
        };
    }
    try noteShared(c, t);
    try c.markChanged(t.mh, m.name.slice());
    const moved = try indices(c, &verts);
    try writeResult(c, .vert, moved);
    try writeCounts(c, m);
    try c.say("Transformed {d} {s} of '{s}'.", .{ moved.len, noun(.vert, moved.len), t.name(c) });
}

/// The EditMesh round trip shared by the topology tools.
const Edit = struct {
    em: EditMesh,

    fn begin(c: *Call, t: Target) HandlerError!Edit {
        return .{ .em = try load(c, t) };
    }

    fn load(c: *Call, t: Target) HandlerError!EditMesh {
        return EditMesh.fromMesh(c.doc().gpa, t.mesh(c)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return c.fail(.internal, "the stored mesh of '{s}' is inconsistent and cannot be edited", .{t.name(c)}),
        };
    }

    /// Validates the result (FR-GEO-3), stores it as the object's mesh and
    /// writes `result`, `counts` and warnings.
    fn commit(e: *Edit, c: *Call, t: Target, out: *const ops.Outcome) HandlerError!void {
        const gpa = c.doc().gpa;
        if (e.em.check()) |msg| return c.fail(.internal, "the operator left broken topology ({s}); nothing changed", .{msg});
        // Problems the edit introduced, not ones the mesh already had; the
        // stored mesh is only re-read when the result has any.
        const winding = e.em.windingConflicts();
        const degenerate = e.em.degenerateFaces();
        if (winding > 0 or degenerate > 0) {
            var before = try load(c, t);
            defer before.deinit();
            const w0 = before.windingConflicts();
            const d0 = before.degenerateFaces();
            if (winding > w0) try c.warn("{d} edge(s) now join faces wound in opposite directions; normals may look flipped there", .{winding - w0});
            if (degenerate > d0) try c.warn("{d} face(s) now have zero area", .{degenerate - d0});
        }
        if (out.degenerate_faces > 0) try c.warn("{d} face(s) collapsed and were removed", .{out.degenerate_faces});

        var maps: geom.editmesh.Maps = undefined;
        var fresh = e.em.toMesh(gpa, &maps) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return c.fail(.internal, "the operator left broken topology; nothing changed", .{}),
        };
        defer maps.deinit(gpa);
        var stored = false;
        defer if (!stored) fresh.releaseRefs(gpa);
        if (geom.build.validate(&fresh)) |msg| return c.fail(.internal, "the operator produced an invalid mesh ({s}); nothing changed", .{msg});
        const m = t.mesh(c);
        const tris = fresh.triangleCount();
        const tris_before = m.triangleCount();
        if (tris > tris_before) try c.spendTriangles(tris - tris_before);

        fresh.name = m.name;
        fresh.materials = m.materials.retain();
        m.releaseRefs(gpa);
        m.* = fresh;
        stored = true;

        const map = switch (out.domain) {
            .vert => maps.verts,
            .edge => maps.edges,
            .face => maps.faces,
        };
        var result: std.ArrayList(u32) = .empty;
        for (out.selected.items) |x| if (map[x] != geom.editmesh.none) try result.append(c.arena, map[x]);
        std.mem.sort(u32, result.items, {}, std.sort.asc(u32));
        try noteShared(c, t);
        try c.markChanged(t.mh, m.name.slice());
        try writeResult(c, out.domain, result.items);
        try writeCounts(c, m);
    }

    fn deinit(e: *Edit) void {
        e.em.deinit();
    }
};

fn opFailed(c: *Call, err: ops.Error) HandlerError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NoNormal => c.failAt(.invalid_argument, "/distance", "give offset [x, y, z] instead", &.{}, "the selection has no normal to move along (loose geometry, or normals that cancel)", .{}),
        else => c.fail(.internal, "the operator met inconsistent topology; nothing changed", .{}),
    };
}

fn extrude(c: *Call) HandlerError!void {
    const t = try target(c);
    const xf = try t.editXform(c);
    const s = try evaluate(c, t, .face, false);
    const offset = c.args.vec3("offset");
    const distance = c.args.float("distance");
    if (offset == null and distance == null) return c.failAt(.invalid_argument, "/distance", "e.g. distance 0.5 along the normal, or offset [0, 0, 0.5]", &.{}, "give distance or offset", .{});
    if (offset != null and distance != null) try c.warn("both offset and distance given; offset wins", .{});
    const p: ops.region.ExtrudeParams = .{
        .offset = offset,
        .distance = distance orelse 0,
        .mode = std.meta.stringToEnum(ops.region.Mode, c.args.str("mode").?).?,
    };
    var e = try Edit.begin(c, t);
    defer e.deinit();
    const list = try indices(c, &s.bits);
    var out = switch (s.s.domain) {
        .face => ops.region.extrudeFaces(&e.em, c.doc().gpa, list, xf, p),
        .edge => ops.region.extrudeEdges(&e.em, c.doc().gpa, list, xf, p),
        .vert => ops.region.extrudeVerts(&e.em, c.doc().gpa, list, xf, p),
    } catch |err| return opFailed(c, err);
    defer out.deinit(c.doc().gpa);
    if (p.mode == .individual and s.s.domain != .face) try c.warn("mode individual applies to faces only", .{});
    try e.commit(c, t, &out);
    const how = if (offset) |o| try std.fmt.allocPrint(c.arena, "by [{d:.3}, {d:.3}, {d:.3}]", .{ o[0], o[1], o[2] }) else try std.fmt.allocPrint(c.arena, "{d:.3} m along the normal", .{p.distance});
    const m = t.mesh(c);
    try c.say("Extruded {d} {s} of '{s}' {s}; it now has {d} verts, {d} faces.", .{ list.len, noun(s.s.domain, list.len), t.name(c), how, m.vertCount(), m.faceCount() });
}

fn faceList(c: *Call, t: Target, s: Selection) HandlerError![]u32 {
    var faces = try sel.toFaces(c.arena, t.mesh(c), s.s.domain, &s.bits);
    if (faces.count() == 0) return c.failAt(.invalid_argument, "/selector", "a vertex or edge selector picks the faces whose corners (or edges) are all selected", &.{}, "the selector covers no whole face of '{s}'", .{t.name(c)});
    return indices(c, &faces);
}

fn inset(c: *Call) HandlerError!void {
    const t = try target(c);
    const xf = try t.editXform(c);
    const s = try evaluate(c, t, .face, false);
    const faces = try faceList(c, t, s);
    var e = try Edit.begin(c, t);
    defer e.deinit();
    var out = ops.region.inset(&e.em, c.doc().gpa, faces, xf, .{
        .thickness = c.args.float("thickness").?,
        .depth = c.args.float("depth").?,
        .mode = std.meta.stringToEnum(ops.region.Mode, c.args.str("mode").?).?,
    }) catch |err| return opFailed(c, err);
    defer out.deinit(c.doc().gpa);
    try e.commit(c, t, &out);
    const m = t.mesh(c);
    try c.say("Inset {d} {s} of '{s}'; it now has {d} verts, {d} faces.", .{ faces.len, noun(.face, faces.len), t.name(c), m.vertCount(), m.faceCount() });
}

fn triangulate(c: *Call) HandlerError!void {
    const t = try target(c);
    const s = try evaluate(c, t, .face, false);
    const faces = try faceList(c, t, s);
    var e = try Edit.begin(c, t);
    defer e.deinit();
    var out = ops.triangulate.triangulate(&e.em, c.doc().gpa, faces, .{
        .quad = std.meta.stringToEnum(ops.triangulate.QuadMethod, c.args.str("quad_method").?).?,
        .ngon = std.meta.stringToEnum(ops.triangulate.NgonMethod, c.args.str("ngon_method").?).?,
    }) catch |err| return opFailed(c, err);
    defer out.deinit(c.doc().gpa);
    try e.commit(c, t, &out);
    try c.say("Triangulated {d} {s} of '{s}' into {d} triangles.", .{ faces.len, noun(.face, faces.len), t.name(c), out.selected.items.len });
}

fn merge(c: *Call) HandlerError!void {
    const t = try target(c);
    const xf = try t.editXform(c);
    const s = try evaluate(c, t, .vert, false);
    var verts = try sel.toVerts(c.arena, t.mesh(c), s.s.domain, &s.bits);
    const list = try indices(c, &verts);
    var e = try Edit.begin(c, t);
    defer e.deinit();
    var out = ops.merge.merge(&e.em, c.doc().gpa, list, xf, .{
        .mode = std.meta.stringToEnum(ops.merge.Mode, c.args.str("mode").?).?,
        .threshold = c.args.float("threshold").?,
    }) catch |err| return opFailed(c, err);
    defer out.deinit(c.doc().gpa);
    if (out.merged_verts == 0) try c.warn("no vertices were merged", .{});
    try e.commit(c, t, &out);
    try c.field("merged");
    try c.out.write(out.merged_verts);
    try c.say("Merged {d} of {d} selected verts of '{s}' away; it now has {d} verts.", .{ out.merged_verts, list.len, t.name(c), t.mesh(c).vertCount() });
}
