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

pub fn selectorParam(comptime domain: []const u8, comptime required: bool) Param {
    return .{
        .name = "selector",
        .type = .selector,
        .doc = "Elements, default domain " ++ domain ++ (if (required) "" else "; omitted = all") ++ ", e.g. {\"normal\":[0,0,1]}; grammar in mesh.select_preview",
        .required = required,
    };
}

/// Soft selection: shared by the tools that move or smooth vertices.
const falloff_params = [_]Param{
    .{ .name = "falloff", .type = .{ .number = .{ .min = 0, .max = 1e6, .unit = .metres } }, .doc = "Soft selection radius: vertices this close to the selection follow, fading out", .default = .{ .number = 0 } },
    .{ .name = "falloff_curve", .type = .{ .enumeration = &.{ "smooth", "sphere", "root", "linear", "sharp", "constant" } }, .doc = "Fade shape", .default = .{ .string = "smooth" } },
    .{ .name = "falloff_connected", .type = .boolean, .doc = "Measure along edges, so nearby parts that are not connected stay put", .default = .{ .boolean = false } },
};

fn falloffArgs(c: *Call) ops.falloff.Params {
    return .{
        .radius = @floatCast(c.args.float("falloff").?),
        .curve = std.meta.stringToEnum(ops.falloff.Curve, c.args.str("falloff_curve").?).?,
        .connected = c.args.boolean("falloff_connected").?,
    };
}

fn stopOf(c: *Call) ?geom.editmesh.Stop {
    return if (c.server.pool.deadline) |d| .{ .deadline = d, .io = c.server.io } else null;
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
        .description = "Move, rotate (Euler XYZ, deg) and scale selected vertices along world axes: scale, then rotate, about the pivot, then translate (m). Faces and edges move their vertices. With falloff (m), nearby vertices follow partway (soft selection), for smooth organic shaping. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"object\":\"Cube\",\"selector\":{\"domain\":\"vert\",\"where\":\"z > 0\"},\"scale\":[0.5,0.5,1]}.",
        .params = common.mutating(&([_]Param{
            object_param,
            selectorParam("vert", true),
            .{ .name = "translate", .type = .{ .vec3 = .{ .min = -1e9, .max = 1e9, .unit = .metres } }, .doc = "Offset [x, y, z]", .default = .{ .vec3 = .{ 0, 0, 0 } } },
            .{ .name = "rotate", .type = .{ .vec3 = .{ .min = -1e6, .max = 1e6, .unit = .degrees } }, .doc = "Euler XYZ rotation about the pivot", .default = .{ .vec3 = .{ 0, 0, 0 } } },
            .{ .name = "scale", .type = .{ .vec3 = .{ .min = -1e6, .max = 1e6 } }, .doc = "Scale about the pivot", .default = .{ .vec3 = .{ 1, 1, 1 } } },
            .{ .name = "pivot", .type = .{ .enumeration = &.{ "median", "bounds", "origin", "point" } }, .doc = "median of the vertices, centre of their bounds, object origin, or 'point'", .default = .{ .string = "median" } },
            .{ .name = "point", .type = .{ .vec3 = .{ .min = -1e9, .max = 1e9, .unit = .metres } }, .doc = "Pivot when pivot is 'point'" },
        } ++ falloff_params)),
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
    .{
        .name = "mesh.loop_cut",
        .title = "Loop cut",
        .description = "Add edge loops. Each selected edge picks its ring: the edges met walking across quads from it, to a boundary, non-quad face or non-manifold edge. Ring edges split evenly into cuts + 1 parts and the quads are cut across. The new loop edges are the result; slide them with mesh.transform_elements. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"object\":\"Cube\",\"selector\":{\"domain\":\"edge\",\"direction\":[0,0,1],\"within\":5},\"cuts\":2}.",
        .params = common.mutating(&.{
            object_param,
            selectorParam("edge", true),
            .{ .name = "cuts", .type = .{ .integer = .{ .min = 1, .max = ops.loopcut.max_cuts } }, .doc = "Loops added per ring", .default = .{ .integer = 1 } },
        }),
        .kind = .mutating,
        .handler = loopCut,
    },
    .{
        .name = "mesh.bevel",
        .title = "Bevel edges",
        .description = "Bevel edges: cut each back by width (m, measured in its faces) and replace it with segments faces; 1 is a flat chamfer, more give a round profile, and corners where three or more meet get a round patch. Widths that would overlap are reduced (warning). Edges need two faces and their vertices a closed surface around them. The new faces are the result. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"object\":\"Cube\",\"selector\":{},\"width\":0.1,\"segments\":4}.",
        .params = common.mutating(&.{
            object_param,
            selectorParam("edge", true),
            .{ .name = "width", .type = .{ .number = .{ .min = 0, .max = 1e6, .unit = .metres } }, .doc = "Offset from each edge", .default = .{ .number = 0.1 } },
            .{ .name = "segments", .type = .{ .integer = .{ .min = 1, .max = ops.bevel.max_segments } }, .doc = "Faces across each bevel", .default = .{ .integer = 1 } },
        }),
        .kind = .mutating,
        .handler = bevel,
    },
    .{
        .name = "mesh.uv_unwrap",
        .title = "UV unwrap",
        .description = "Unwrap faces into the UVMap layer: split into charts, flatten each with least-squares conformal maps, scale to one texel density and pack into 0..1. smart also starts a new chart where faces turn more than angle_limit; conformal cuts only at seams (edges) and mesh borders. Corners of other faces keep their UVs. The faces are the result. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"object\":\"Cylinder\",\"method\":\"conformal\",\"seams\":{\"domain\":\"edge\",\"union\":[{\"where\":\"abs(z) > 0.99\"},{\"index\":[0]}]}}.",
        .params = common.mutating(&.{
            object_param,
            selectorParam("face", false),
            .{ .name = "method", .type = .{ .enumeration = &.{ "smart", "conformal" } }, .doc = "How charts are found", .default = .{ .string = "smart" } },
            .{ .name = "angle_limit", .type = .{ .number = .{ .min = 1, .max = 89, .unit = .degrees } }, .doc = "smart: largest normal turn within a chart", .default = .{ .number = 66 } },
            .{ .name = "seams", .type = .selector, .doc = "Edges to cut along, as a selector (default domain edge)" },
            .{ .name = "margin", .type = .{ .number = .{ .min = 0, .max = 0.2 } }, .doc = "Gap around charts, fraction of the 0..1 square", .default = .{ .number = 0.01 } },
        }),
        .kind = .mutating,
        .handler = uvUnwrap,
    },
    .{
        .name = "mesh.boolean",
        .title = "Boolean",
        .description = "Combine a mesh object with another (the operand) in world space: difference cuts the operand away, union joins them, intersect keeps the overlap. Both must be closed solids. Faces keep their UVs, smooth shading and materials; the operand's materials join the object's slots. The operand is then hidden, deleted or kept. The faces from the operand (e.g. the walls of a hole) are the result. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"object\":\"Wall\",\"operand\":\"Window Cutter\",\"operation\":\"difference\"}.",
        .params = common.mutating(&.{
            object_param,
            .{ .name = "operand", .type = .{ .name_ref = .{} }, .doc = "Mesh object to combine with", .required = true },
            .{ .name = "operation", .type = .{ .enumeration = &.{ "difference", "union", "intersect" } }, .doc = "How to combine", .default = .{ .string = "difference" } },
            .{ .name = "operand_action", .type = .{ .enumeration = &.{ "hide", "delete", "keep" } }, .doc = "What happens to the operand afterwards", .default = .{ .string = "hide" } },
        }),
        .kind = .mutating,
        .handler = boolean,
    },
    .{
        .name = "mesh.smooth",
        .title = "Smooth vertices",
        .description = "Relax selected vertices toward their neighbours, iterations times by factor, removing lumps and blending seams (e.g. where a union joined a nose to a face). preserve_volume keeps the size (Taubin smoothing); boundary vertices stay put unless pin_boundary is false. With falloff (m) the effect fades out around the selection. The selected vertices are the result. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"object\":\"Head\",\"selector\":{\"domain\":\"vert\",\"sphere\":{\"center\":[0,-0.9,-0.1],\"radius\":0.25}},\"iterations\":10}.",
        .params = common.mutating(&([_]Param{
            object_param,
            selectorParam("vert", false),
            .{ .name = "iterations", .type = .{ .integer = .{ .min = 1, .max = ops.smooth.max_iterations } }, .doc = "Passes", .default = .{ .integer = 5 } },
            .{ .name = "factor", .type = .{ .number = .{ .min = 0, .max = 1 } }, .doc = "Fraction of the way to the neighbour mean per pass", .default = .{ .number = 0.5 } },
            .{ .name = "preserve_volume", .type = .boolean, .doc = "Counter each pass so the shape does not shrink", .default = .{ .boolean = true } },
            .{ .name = "pin_boundary", .type = .boolean, .doc = "Keep vertices on open edges fixed", .default = .{ .boolean = true } },
        } ++ falloff_params)),
        .kind = .mutating,
        .handler = smoothVerts,
    },
    .{
        .name = "mesh.sculpt",
        .title = "Sculpt stroke",
        .description = "Brush a stroke over a mesh as Blender's sculpt mode does. stroke is a path of world points, snapped to the nearest vertex; a dab falls every spacing x radius and moves vertices within radius (m) by the falloff. Brushes: draw (raise along the area normal), inflate (along each normal), flatten, pinch, crease (pinch and dig), smooth, grab (move the area under the first point to the last). subtract digs in; symmetry mirrors each dab across the object's local axis. Works best on dense meshes, e.g. after a subdivision modifier is applied. Example: {\"scene_id\":\"scn_1a2b3c4d\",\"object\":\"Head\",\"brush\":\"draw\",\"stroke\":[[0.3,-0.9,0.4],[0.5,-0.85,0.45]],\"radius\":0.08,\"symmetry\":\"x\"}.",
        .params = common.mutating(&.{
            object_param,
            .{ .name = "brush", .type = .{ .enumeration = std.meta.fieldNames(ops.sculpt.Brush) }, .doc = "Brush", .default = .{ .string = "draw" } },
            .{ .name = "stroke", .type = .{ .points = .{} }, .doc = "Path of [x, y, z] world points", .required = true },
            .{ .name = "radius", .type = .{ .number = .{ .min = 1e-5, .max = 1e6, .unit = .metres } }, .doc = "Brush radius", .default = .{ .number = 0.1 } },
            .{ .name = "strength", .type = .{ .number = .{ .min = 0, .max = 1 } }, .doc = "Brush strength", .default = .{ .number = 0.5 } },
            .{ .name = "subtract", .type = .boolean, .doc = "Dig in instead of raising (draw, inflate, crease)", .default = .{ .boolean = false } },
            .{ .name = "symmetry", .type = .{ .enumeration = &.{ "none", "x", "y", "z" } }, .doc = "Mirror each dab across this local axis", .default = .{ .string = "none" } },
            falloff_params[1],
            .{ .name = "spacing", .type = .{ .number = .{ .min = 0.05, .max = 2 } }, .doc = "Dab spacing, fraction of the radius", .default = .{ .number = 0.25 } },
        }),
        .kind = .mutating,
        .handler = sculpt,
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
    return targetFor(c, try c.object("object"));
}

/// The faces the call's `selector` picks on mesh object `oh`, sorted; an
/// error result when it picks none.
pub fn selectedFaces(c: *Call, oh: IdHandle) HandlerError![]u32 {
    const t = try targetFor(c, oh);
    return faceList(c, t, try evaluate(c, t, .face, false));
}

fn targetFor(c: *Call, oh: IdHandle) HandlerError!Target {
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
    return evaluateArg(c, t, "selector", default_domain, allow_empty);
}

/// Evaluates the selector in argument `arg` (`selector`, or another
/// selector-typed parameter such as `seams`).
fn evaluateArg(c: *Call, t: Target, comptime arg: []const u8, default_domain: sel.Domain, allow_empty: bool) HandlerError!Selection {
    const at = "/" ++ arg;
    var failure: schema.Failure = undefined;
    const s = (try selector.parse(c.arena, c.args.value(arg), default_domain, at, &failure)) orelse {
        return c.failAt(.invalid_argument, failure.path, failure.hint, failure.valid_values, "{s}", .{failure.message});
    };
    const m = t.mesh(c);
    var diag: sel.Diag = .{};
    const bits = sel.evaluate(c.arena, m, s, t.world, &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IndexOutOfRange => return c.failAt(.invalid_argument, at, "indices change after topology edits: use the 'result' of the last call, or select by rule", &.{}, "index {d} is out of range: '{s}' has {d} {s}", .{ diag.index, t.name(c), s.domain.count(m), s.domain.plural() }),
        error.FieldNotInDomain => return c.failAt(.invalid_argument, at ++ "/where", "area applies to faces and length to edges; set domain to match", &.{}, "a where comparison does not apply to {s}", .{s.domain.plural()}),
        error.UnknownAttribute, error.AttributeNotScalar => return c.failAt(.not_found, at, "where compares x y z nx ny nz area length index or a scalar attribute of the selector's domain", try scalarAttributes(c, m, s.domain), "'{s}' is not a scalar {s} attribute of '{s}'", .{ diag.attribute, @tagName(s.domain), t.name(c) }),
    };
    if (!allow_empty and bits.count() == 0) {
        // A common slip: a vertex's normal averages its faces', so a cube
        // corner points 55 degrees away from each face it touches.
        const hint = if (s.domain == .vert and s.root.normal != null)
            "vertex normals average their faces' normals; to pick a face's vertices use domain face with normal, or widen within"
        else
            "check it with mesh.select_preview; positions and normals are in world space unless space is local";
        return c.failAt(.invalid_argument, at, hint, &.{}, "the selector matched no {s} of '{s}'", .{ s.domain.plural(), t.name(c) });
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
    const soft = falloffArgs(c);
    var affected: usize = verts.count();
    if (identity) {
        try c.warn("translate, rotate and scale are all neutral; nothing moved", .{});
    } else if (soft.radius > 0) {
        const gpa = c.doc().gpa;
        const w = try c.arena.alloc(f32, m.vertCount());
        ops.falloff.weights(gpa, m, &verts, xf, soft, stopOf(c), w) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DeadlineExceeded => return error.ToolFailed,
        };
        affected = 0;
        for (w) |x| affected += @intFromBool(x > 0);
        ops.transform.applyWeighted(try m.positions.mut(gpa), w, xf, p);
    } else {
        ops.transform.apply(try m.positions.mut(c.doc().gpa), &verts, xf, p);
    }
    if (!identity) for (m.positions.slice()) |q| for (q) |x| if (!std.math.isFinite(x)) {
        return c.fail(.invalid_argument, "the transform produced non-finite positions; nothing changed", .{});
    };
    try noteShared(c, t);
    try c.markChanged(t.mh, m.name.slice());
    const moved = try indices(c, &verts);
    try writeResult(c, .vert, moved);
    try c.field("affected");
    try c.out.write(affected);
    try writeCounts(c, m);
    if (affected > moved.len) {
        try c.say("Transformed {d} {s} of '{s}', and {d} more partway through the falloff.", .{ moved.len, noun(.vert, moved.len), t.name(c), affected - moved.len });
    } else {
        try c.say("Transformed {d} {s} of '{s}'.", .{ moved.len, noun(.vert, moved.len), t.name(c) });
    }
}

/// The EditMesh round trip shared by the topology tools.
const Edit = struct {
    em: EditMesh,

    fn begin(c: *Call, t: Target) HandlerError!Edit {
        var em = try load(c, t);
        // Operators stop at the call's wall-time limit (SEC-3).
        if (c.server.pool.deadline) |d| em.stop = .{ .deadline = d, .io = c.server.io };
        return .{ .em = em };
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
        // The command core sees the expired deadline and reports it.
        error.DeadlineExceeded => error.ToolFailed,
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

fn loopCut(c: *Call) HandlerError!void {
    const t = try target(c);
    const s = try evaluate(c, t, .edge, false);
    var edges = try sel.toEdges(c.arena, t.mesh(c), s.s.domain, &s.bits);
    const seeds = try indices(c, &edges);
    var e = try Edit.begin(c, t);
    defer e.deinit();
    const cuts: u32 = @intCast(c.args.int("cuts").?);
    var out = ops.loopcut.loopCut(&e.em, c.doc().gpa, seeds, .{ .cuts = cuts }) catch |err| return opFailed(c, err);
    defer out.deinit(c.doc().gpa);
    if (out.rings == 0) return c.failAt(.invalid_argument, "/selector", "select an edge between quads, e.g. {\"domain\":\"edge\",\"direction\":[0,0,1]} for a box's vertical edges", &.{}, "none of the {d} selected edges borders a quad, so there is no ring to cut", .{seeds.len});
    if (out.skipped > 0) try c.warn("{d} selected edge(s) border no quad and were skipped", .{out.skipped});
    try e.commit(c, t, &out);
    const m = t.mesh(c);
    try c.say("Cut {d} ring(s) of '{s}' with {d} loop(s) each; it now has {d} verts, {d} faces.", .{ out.rings, t.name(c), cuts, m.vertCount(), m.faceCount() });
}

fn bevel(c: *Call) HandlerError!void {
    const t = try target(c);
    const xf = try t.editXform(c);
    const s = try evaluate(c, t, .edge, false);
    var edges = try sel.toEdges(c.arena, t.mesh(c), s.s.domain, &s.bits);
    const list = try indices(c, &edges);
    const width = c.args.float("width").?;
    var e = try Edit.begin(c, t);
    defer e.deinit();
    var out = ops.bevel.bevel(&e.em, c.doc().gpa, list, xf, .{
        .width = width,
        .segments = @intCast(c.args.int("segments").?),
    }) catch |err| switch (err) {
        error.NonManifold => return c.failAt(.invalid_argument, "/selector", "bevel edges of closed surfaces (box, cylinder, sphere); fix flipped faces first, or check the mesh with scene.validate", &.{}, "a vertex of the selected edges lies on an open boundary, joins more than one fan of faces, or sits between faces wound opposite ways", .{}),
        else => return opFailed(c, err),
    };
    defer out.deinit(c.doc().gpa);
    if (out.selected.items.len == 0) return c.failAt(.invalid_argument, "/selector", "bevel works on edges between two faces", &.{}, "none of the {d} selected edges has exactly two faces", .{list.len});
    if (out.skipped > 0) try c.warn("{d} selected edge(s) without exactly two faces were skipped", .{out.skipped});
    if (out.width_used < width) try c.warn("width reduced from {d:.4} to {d:.4} m so the cuts of neighbouring edges do not cross", .{ width, out.width_used });
    try e.commit(c, t, &out);
    try c.field("width");
    try c.out.write(out.width_used);
    const m = t.mesh(c);
    try c.say("Bevelled {d} edge(s) of '{s}' by {d:.3} m; it now has {d} verts, {d} faces.", .{ list.len - out.skipped, t.name(c), out.width_used, m.vertCount(), m.faceCount() });
}

fn uvUnwrap(c: *Call) HandlerError!void {
    const t = try target(c);
    const s = try evaluate(c, t, .face, false);
    const faces = try faceList(c, t, s);
    const m = t.mesh(c);
    var seams: ?sel.Bits = null;
    if (c.args.value("seams") != null) {
        const ss = try evaluateArg(c, t, "seams", .edge, true);
        seams = try sel.toEdges(c.arena, m, ss.s.domain, &ss.bits);
    }
    const keep: ?[]const [2]f32 = if (m.attribute(Mesh.uv_name)) |a|
        (if (a.domain == .corner and a.data == .float2) a.data.float2.slice() else null)
    else
        null;
    const gpa = c.doc().gpa;
    const stop: ?geom.editmesh.Stop = if (c.server.pool.deadline) |d| .{ .deadline = d, .io = c.server.io } else null;
    const r = geom.uv.unwrap(gpa, m, faces, t.world, if (seams) |*b| b else null, keep, stop, .{
        .method = std.meta.stringToEnum(geom.uv.Method, c.args.str("method").?).?,
        .angle_limit = v.degToRad(@floatCast(c.args.float("angle_limit").?)),
        .margin = @floatCast(c.args.float("margin").?),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DeadlineExceeded => return error.ToolFailed, // reported by the command core
    };
    const shared = core.Shared([2]f32).fromOwned(gpa, r.uvs) catch |e| {
        gpa.free(r.uvs);
        return e;
    };
    const data: core.types.AttrData = .{ .float2 = shared };
    m.setAttribute(gpa, Mesh.uv_name, .corner, data) catch {
        return c.fail(.invalid_operation, "'{s}' already has the most attributes a mesh can hold", .{m.name.slice()});
    };
    if (r.closed > 0) try c.warn("{d} chart(s) closed on themselves with no seam and were split by angle instead; add seams for control", .{r.closed});
    try noteShared(c, t);
    try c.markChanged(t.mh, m.name.slice());
    try writeResult(c, .face, faces);
    try c.field("charts");
    try c.out.write(r.charts);
    try c.say("Unwrapped {d} {s} of '{s}' into {d} chart(s) in UVMap.", .{ faces.len, noun(.face, faces.len), t.name(c), r.charts });
}

fn boolean(c: *Call) HandlerError!void {
    const B = geom.ops.boolean;
    const t = try target(c);
    _ = try t.editXform(c);
    const doc = c.doc();
    const gpa = doc.gpa;
    const oh = try c.object("operand");
    if (oh.eql(t.ob)) return c.failAt(.invalid_argument, "/operand", "pick another object to combine with", &.{}, "an object cannot be combined with itself", .{});
    const ob2 = doc.db.get(.object, oh).?;
    const op_name = try c.arena.dupe(u8, ob2.name.slice());
    const mh2 = (if (ob2.kind == .mesh) ob2.data else null) orelse {
        return c.failAt(.invalid_argument, "/operand", "booleans combine mesh objects", &.{}, "'{s}' is a {s}, not a mesh", .{ op_name, @tagName(ob2.kind) });
    };
    if (mh2.eql(t.mh)) return c.failAt(.invalid_argument, "/operand", "make the operand a separate copy with object.duplicate (linked: false)", &.{}, "'{s}' and '{s}' share one mesh", .{ t.name(c), op_name });
    if (!B.available) return c.fail(.invalid_operation, "this build of Zender has no boolean support (it was built with -Dboolean=none)", .{});
    const world2 = core.edit.worldMatrix(&doc.db, oh) catch return error.OutOfMemory;
    const op: B.Op = switch (std.meta.stringToEnum(enum { difference, @"union", intersect }, c.args.str("operation").?).?) {
        .difference => .difference,
        .@"union" => .union_,
        .intersect => .intersect,
    };
    var failure: B.Failure = .none;
    var out = B.apply(gpa, .{ .mesh = t.mesh(c), .world = t.world }, .{ .mesh = doc.db.get(.mesh, mh2).?, .world = world2 }, op, &failure) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unavailable => return c.fail(.invalid_operation, "this build of Zender has no boolean support", .{}),
        error.BooleanFailed => {
            const closed = "booleans need closed solids: no holes or loose faces, every edge shared by exactly two faces wound the same way; scene.validate lists open edges";
            return switch (failure) {
                .not_manifold_target => c.failAt(.invalid_argument, "/object", closed, &.{}, "'{s}' is not a closed solid", .{t.name(c)}),
                .not_manifold_operand => c.failAt(.invalid_argument, "/operand", closed, &.{}, "'{s}' is not a closed solid", .{op_name}),
                .invalid_target => c.failAt(.invalid_argument, "/object", "", &.{}, "'{s}' has unusable geometry (non-finite positions)", .{t.name(c)}),
                .invalid_operand => c.failAt(.invalid_argument, "/operand", "", &.{}, "'{s}' has unusable geometry (non-finite positions)", .{op_name}),
                .too_large => c.fail(.budget_exceeded, "the boolean result is too large to represent", .{}),
                .none, .other => c.fail(.internal, "the boolean failed; nothing changed", .{}),
            };
        },
        error.InvalidTopology, error.TooManyAttributes => return c.fail(.internal, "the boolean result could not be stored; nothing changed", .{}),
    };
    defer gpa.free(out.from_operand);
    var stored = false;
    defer if (!stored) out.mesh.releaseRefs(gpa);

    const m = t.mesh(c);
    for (m.attrs[0..m.attr_count]) |*a| {
        const n = a.name.slice();
        if (!std.mem.eql(u8, n, Mesh.uv_name) and !std.mem.eql(u8, n, "sharp_face") and !std.mem.eql(u8, n, "material_index")) {
            try c.warn("attribute '{s}' is not carried through booleans and was dropped", .{n});
        }
    }
    const tris = out.mesh.triangleCount();
    if (tris > m.triangleCount()) try c.spendTriangles(tris - m.triangleCount());
    out.mesh.name = m.name;
    m.releaseRefs(gpa);
    m.* = out.mesh;
    stored = true;
    if (m.faceCount() == 0) try c.warn("the result is empty (no overlap, or everything was cut away)", .{});
    try noteShared(c, t);
    try c.markChanged(t.mh, m.name.slice());

    const action = std.meta.stringToEnum(enum { hide, delete, keep }, c.args.str("operand_action").?).?;
    switch (action) {
        .hide => {
            ob2.hide_render = true;
            ob2.hide_viewport = true;
            try c.markChanged(oh, op_name);
        },
        .delete => {
            var it = doc.db.object.iterator();
            while (it.next()) |e| if (e.value.parent) |p| if (p.eql(oh)) try c.markChanged(e.handle, e.value.name.slice());
            core.edit.deleteObject(doc, oh) catch return error.OutOfMemory;
            try c.markChanged(oh, op_name);
        },
        .keep => {},
    }
    try writeResult(c, .face, out.from_operand);
    try writeCounts(c, m);
    const verb = switch (op) {
        .difference => "Cut",
        .union_ => "Joined",
        .intersect => "Intersected",
    };
    try c.say("{s} '{s}' with '{s}' ({s} the operand); it now has {d} verts, {d} faces.", .{ verb, t.name(c), op_name, @tagName(action), m.vertCount(), m.faceCount() });
}

fn sculpt(c: *Call) HandlerError!void {
    const t = try target(c);
    const xf = try t.editXform(c);
    const m = t.mesh(c);
    const gpa = c.doc().gpa;
    const path = try c.args.points(c.arena, "stroke");
    var touched = try sel.Bits.initEmpty(c.arena, m.vertCount());
    const stats = ops.sculpt.stroke(gpa, m, try m.positions.mut(gpa), xf, path, .{
        .brush = std.meta.stringToEnum(ops.sculpt.Brush, c.args.str("brush").?).?,
        .radius = @floatCast(c.args.float("radius").?),
        .strength = @floatCast(c.args.float("strength").?),
        .subtract = c.args.boolean("subtract").?,
        .curve = std.meta.stringToEnum(ops.falloff.Curve, c.args.str("falloff_curve").?).?,
        .symmetry = std.meta.stringToEnum(ops.sculpt.Symmetry, c.args.str("symmetry").?).?,
        .spacing = @floatCast(c.args.float("spacing").?),
    }, stopOf(c), &touched) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DeadlineExceeded => return error.ToolFailed,
    };
    if (stats.moved == 0) try c.warn("no vertex lay within the radius of the stroke; check the stroke points against mesh.select_preview bounds", .{});
    if (m.vertCount() < 2000 and stats.moved > 0) try c.warn("'{s}' has only {d} vertices; sculpting looks smoother on a denser mesh (apply a subdivision modifier first)", .{ t.name(c), m.vertCount() });
    try noteShared(c, t);
    try c.markChanged(t.mh, m.name.slice());
    try writeResult(c, .vert, try indices(c, &touched));
    try c.field("dabs");
    try c.out.write(stats.dabs);
    try c.field("moved");
    try c.out.write(stats.moved);
    try writeCounts(c, m);
    try c.say("Sculpted '{s}' with {s}: {d} dabs moved {d} vertices.", .{ t.name(c), c.args.str("brush").?, stats.dabs, stats.moved });
}

fn smoothVerts(c: *Call) HandlerError!void {
    const t = try target(c);
    const xf = try t.editXform(c);
    const s = try evaluate(c, t, .vert, false);
    const m = t.mesh(c);
    const gpa = c.doc().gpa;
    var verts = try sel.toVerts(c.arena, m, s.s.domain, &s.bits);
    const w = try c.arena.alloc(f32, m.vertCount());
    ops.falloff.weights(gpa, m, &verts, xf, falloffArgs(c), stopOf(c), w) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DeadlineExceeded => return error.ToolFailed,
    };
    ops.smooth.smooth(gpa, m, try m.positions.mut(gpa), w, .{
        .iterations = @intCast(c.args.int("iterations").?),
        .factor = @floatCast(c.args.float("factor").?),
        .preserve_volume = c.args.boolean("preserve_volume").?,
        .pin_boundary = c.args.boolean("pin_boundary").?,
    }, stopOf(c)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DeadlineExceeded => return error.ToolFailed,
    };
    var affected: usize = 0;
    for (w) |x| affected += @intFromBool(x > 0);
    try noteShared(c, t);
    try c.markChanged(t.mh, m.name.slice());
    const list = try indices(c, &verts);
    try writeResult(c, .vert, list);
    try c.field("affected");
    try c.out.write(affected);
    try writeCounts(c, m);
    try c.say("Smoothed {d} vertices of '{s}' ({d} passes).", .{ affected, t.name(c), c.args.int("iterations").? });
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
