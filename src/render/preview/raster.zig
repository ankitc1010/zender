//! Preview renderer: a tiled rasteriser for fast agent feedback (TRD §8).
//!
//! Pipeline: transform every visible mesh instance to clip space, clip
//! triangles against the near plane, bin them to 64×64 tiles in scene order,
//! then rasterise and shade each tile independently on the shared pool.
//! Tiles own disjoint pixels and walk their triangles in the same order for
//! any thread count, so the image is bit-identical across thread counts.
//!
//! Shading is Lambert with a camera-relative key light, a fill and an
//! ambient term, plus emission; output uses the Standard sRGB transform.

const std = @import("std");
const math = @import("math");
const ir = @import("ir");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const v = math.vec;

pub const tile_size = 64;
const no_tri = std.math.maxInt(u32);

pub const View = struct {
    /// Camera-to-world matrix (camera looks along its local −Z, +Y up).
    camera_to_world: Mat4,
    projection: Mat4,
    /// Lens shift in NDC units.
    shift_ndc: [2]f32 = .{ 0, 0 },
};

pub const Options = struct {
    width: u32,
    height: u32,
    /// Node index of the camera to render through; null uses the scene's
    /// active camera, or an automatic three-quarter view when there is none.
    camera: ?u32 = null,
    wireframe: bool = false,
    transparent: bool = false,
    pool: math.Pool,
};

pub const Result = struct {
    width: u32,
    height: u32,
    /// sRGB-encoded RGBA, top row first.
    rgba: []u8,
    /// Distance along the view axis in metres; +inf for background.
    depth: []f32,
    /// Node index + 1 per pixel; 0 for background.
    object_id: []u32,
    /// Triangles rasterised, after clipping and dropping those that cover
    /// no pixel centre.
    triangles: usize,
    camera_name: []const u8,

    pub fn deinit(r: *Result, gpa: Allocator) void {
        gpa.free(r.rgba);
        gpa.free(r.depth);
        gpa.free(r.object_id);
        r.* = undefined;
    }
};

const Instance = struct {
    node: u32,
    mesh: *const ir.Mesh,
    /// Local → view-space rotation for normals (inverse-transpose).
    normal_to_view: Mat4,
    vert_base: u32,
    color: [3]f32,
    emission: [3]f32,
    cull_back: bool,
    /// Material colour per slot (when faces use several slots).
    slot_colors: []const [3]f32,
    slot_emission: []const [3]f32,
};

const ScreenVert = struct {
    x: f32,
    y: f32,
    /// NDC depth mapped to 0..1.
    z: f32,
    w_inv: f32,
    /// Signed distance to the near plane in clip space (z + w); ≥ 0 is visible.
    d: f32,
    view_z: f32,
};

/// 32 bytes; dense meshes produce millions of these.
const Tri = struct {
    /// Indices into the screen-vertex buffer, or into `clip_verts` when
    /// `clipped` is set (each clip vertex has its barycentric coordinates
    /// in the original triangle in `clip_bary`).
    v: [3]u32,
    /// Mesh-local corners holding each original vertex's normal.
    c: [3]u32,
    inst: u32,
    slot: u16,
    clipped: bool,
};

const Ctx = struct {
    opts: Options,
    scene: *const ir.Scene,
    insts: []const Instance,
    verts: []const ScreenVert,
    clip_verts: []const ScreenVert,
    clip_bary: []const [3]f32,
    tris: []const Tri,
    tile_start: []const u32,
    tile_tris: []const u32,
    tiles_x: u32,
    background: [4]f32,
    rgba: []u8,
    depth: []f32,
    object_id: []u32,
};

/// Builds the automatic view used when a scene has no camera: Blender's
/// default camera direction, framing the bounds of all visible geometry.
pub fn autoView(scene: *const ir.Scene, aspect: f32) View {
    var lo: Vec3 = .{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
    var hi: Vec3 = .{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
    for (scene.nodes) |n| {
        if (n.hide_render or n.kind != .mesh) continue;
        for (scene.meshes[n.kind.mesh].positions) |p| {
            const w = v.transformPoint(n.world, p);
            lo = v.min3(lo, w);
            hi = v.max3(hi, w);
        }
    }
    if (!(lo[0] <= hi[0])) {
        lo = .{ -1, -1, -1 };
        hi = .{ 1, 1, 1 };
    }
    const center = v.scale(v.add(lo, hi), 0.5);
    const radius = @max(0.01, v.length(v.sub(hi, lo)) / 2);
    const yfov: f32 = 0.6;
    const fov_min = if (aspect >= 1) yfov else 2 * std.math.atan(@tan(yfov / 2) * aspect);
    const dist = radius / @sin(fov_min / 2) * 1.05;
    const dir = v.normalize(.{ 7.36, -6.93, 4.96 });
    const eye = v.add(center, v.scale(dir, dist));
    const rot = v.lookRotation(v.sub(center, eye), .{ 0, 0, 1 });
    return .{
        .camera_to_world = v.compose(eye, rot, .{ 1, 1, 1 }),
        .projection = v.perspective(yfov, aspect, @max(1e-3, dist - radius * 2), dist + radius * 2),
    };
}

/// The view through camera node `node`, for an image of the given aspect.
pub fn cameraView(scene: *const ir.Scene, node: u32, aspect: f32) View {
    const n = scene.nodes[node];
    const cam = scene.cameras[n.kind.camera];
    // Strip scale from the camera matrix; Blender ignores it for the view.
    const d = v.decompose(n.world);
    const c2w = v.compose(d.t, d.r, .{ 1, 1, 1 });
    const fov = cam.fov(aspect);
    const proj = switch (cam.projection) {
        .perspective => v.perspective(fov.y, aspect, cam.clip_start, cam.clip_end),
        .orthographic => v.orthographic(fov.half_w, fov.half_h, cam.clip_start, cam.clip_end),
    };
    // Shift is a fraction of the larger image side.
    const larger = @max(aspect, 1.0);
    return .{
        .camera_to_world = c2w,
        .projection = proj,
        .shift_ndc = .{ 2 * cam.shift[0] * larger / aspect, 2 * cam.shift[1] * larger },
    };
}

pub const RenderError = Allocator.Error || error{InvalidCamera};

pub fn render(gpa: Allocator, scene: *const ir.Scene, opts: Options) RenderError!Result {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const width = opts.width;
    const height = opts.height;
    const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    const cam_node = opts.camera orelse scene.active_camera;
    var camera_name: []const u8 = "(automatic view)";
    const view = if (cam_node) |cn| blk: {
        if (cn >= scene.nodes.len or scene.nodes[cn].kind != .camera) return error.InvalidCamera;
        camera_name = scene.nodes[cn].name;
        break :blk cameraView(scene, cn, aspect);
    } else autoView(scene, aspect);
    const world_to_view = v.invert(view.camera_to_world) orelse return error.InvalidCamera;
    const view_proj = v.matMul(view.projection, world_to_view);

    // Instances and their screen vertices.
    var insts: std.ArrayList(Instance) = .empty;
    var n_verts: usize = 0;
    for (scene.nodes, 0..) |n, i| {
        if (n.hide_render or n.kind != .mesh) continue;
        const mesh = &scene.meshes[n.kind.mesh];
        const slots = @max(1, n.materials.len);
        const colors = try arena.alloc([3]f32, slots);
        const emis = try arena.alloc([3]f32, slots);
        var cull = false;
        for (0..slots) |s| {
            const mat: ?ir.Material = if (s < n.materials.len) if (n.materials[s]) |m| scene.materials[m] else null else null;
            if (mat) |m| {
                colors[s] = .{ m.base_color[0], m.base_color[1], m.base_color[2] };
                emis[s] = v.scale(m.emission_color, m.emission_strength);
                if (s == 0) cull = !m.double_sided;
            } else {
                colors[s] = .{ 0.8, 0.8, 0.8 };
                emis[s] = .{ 0, 0, 0 };
            }
        }
        try insts.append(arena, .{
            .node = @intCast(i),
            .mesh = mesh,
            .normal_to_view = v.matMul(world_to_view, v.normalMatrix(n.world)),
            .vert_base = @intCast(n_verts),
            .color = colors[0],
            .emission = emis[0],
            .cull_back = cull,
            .slot_colors = colors,
            .slot_emission = emis,
        });
        n_verts += mesh.positions.len;
    }

    const fw: f32 = @floatFromInt(width);
    const fh: f32 = @floatFromInt(height);

    // Work is split into chunks of consecutive faces (and vertices) per
    // instance. Each chunk's output depends only on its range, and chunks are
    // merged in order, so the triangle order is the scene order.
    var vchunks: std.ArrayList(Range) = .empty;
    var fchunks: std.ArrayList(Range) = .empty;
    for (insts.items, 0..) |inst, ii| {
        const nv: u32 = @intCast(inst.mesh.positions.len);
        var s: u32 = 0;
        while (s < nv) : (s += vert_chunk) try vchunks.append(arena, .{ .inst = @intCast(ii), .lo = s, .hi = @min(nv, s + vert_chunk) });
        const nf: u32 = @intCast(inst.mesh.faceCount());
        s = 0;
        while (s < nf) : (s += face_chunk) try fchunks.append(arena, .{ .inst = @intCast(ii), .lo = s, .hi = @min(nf, s + face_chunk) });
    }

    const verts = try arena.alloc(ScreenVert, n_verts);
    const tctx: SetupCtx = .{
        .gpa = gpa,
        .insts = insts.items,
        .nodes = scene.nodes,
        .verts = verts,
        .view_proj = view_proj,
        .world_to_view = world_to_view,
        .width = fw,
        .height = fh,
        .shift = view.shift_ndc,
        .vchunks = vchunks.items,
        .fchunks = fchunks.items,
        .outs = try arena.alloc(ChunkOut, fchunks.items.len),
    };
    @memset(tctx.outs, .{});
    defer for (tctx.outs) |*o| o.deinit(gpa);
    opts.pool.parallelFor(vchunks.items.len, &tctx, SetupCtx.transform);
    opts.pool.parallelFor(fchunks.items.len, &tctx, SetupCtx.triangles);

    // Merge chunk outputs in order.
    var n_tris: usize = 0;
    var n_clip: usize = 0;
    const tri_base = try arena.alloc(u32, tctx.outs.len);
    const clip_base = try arena.alloc(u32, tctx.outs.len);
    for (tctx.outs, 0..) |*o, k| {
        if (o.oom) return error.OutOfMemory;
        tri_base[k] = @intCast(n_tris);
        clip_base[k] = @intCast(n_clip);
        n_tris += o.tris.items.len;
        n_clip += o.clip.items.len;
    }
    const tris = try arena.alloc(Tri, n_tris);
    const clip_verts = try arena.alloc(ScreenVert, n_clip);
    const clip_bary = try arena.alloc([3]f32, n_clip);
    const rects = try arena.alloc([4]u8, n_tris);
    const tiles_x = (width + tile_size - 1) / tile_size;
    const tiles_y = (height + tile_size - 1) / tile_size;
    const n_tiles = tiles_x * tiles_y;
    // Per chunk, per tile triangle counts: binning in parallel stays in order.
    const counts = try arena.alloc(u32, tctx.outs.len * n_tiles);
    @memset(counts, 0);
    var mctx: MergeCtx = .{
        .outs = tctx.outs,
        .tri_base = tri_base,
        .clip_base = clip_base,
        .tris = tris,
        .verts = verts,
        .clip_verts = clip_verts,
        .clip_bary = clip_bary,
        .rects = rects,
        .counts = counts,
        .tiles_x = tiles_x,
        .tiles_y = tiles_y,
        .n_tiles = n_tiles,
    };
    opts.pool.parallelFor(tctx.outs.len, &mctx, MergeCtx.merge);

    // Tile starts, then each chunk's write position inside each tile.
    const tile_start = try arena.alloc(u32, n_tiles + 1);
    tile_start[0] = 0;
    for (0..n_tiles) |t| {
        var sum: u32 = 0;
        for (0..tctx.outs.len) |k| sum += counts[k * n_tiles + t];
        tile_start[t + 1] = tile_start[t] + sum;
    }
    for (0..n_tiles) |t| {
        var pos = tile_start[t];
        for (0..tctx.outs.len) |k| {
            const n = counts[k * n_tiles + t];
            counts[k * n_tiles + t] = pos;
            pos += n;
        }
    }
    mctx.tile_tris = try arena.alloc(u32, tile_start[n_tiles]);
    opts.pool.parallelFor(tctx.outs.len, &mctx, MergeCtx.fill);

    const n_px = @as(usize, width) * height;
    const rgba = try gpa.alloc(u8, n_px * 4);
    errdefer gpa.free(rgba);
    const depth = try gpa.alloc(f32, n_px);
    errdefer gpa.free(depth);
    const object_id = try gpa.alloc(u32, n_px);
    errdefer gpa.free(object_id);

    const bg = v.scale(scene.world.color, scene.world.strength);
    var ctx: Ctx = .{
        .opts = opts,
        .scene = scene,
        .insts = insts.items,
        .verts = verts,
        .clip_verts = clip_verts,
        .clip_bary = clip_bary,
        .tris = tris,
        .tile_start = tile_start,
        .tile_tris = mctx.tile_tris,
        .tiles_x = tiles_x,
        .background = .{ bg[0], bg[1], bg[2], if (opts.transparent) 0 else 1 },
        .rgba = rgba,
        .depth = depth,
        .object_id = object_id,
    };
    opts.pool.parallelFor(n_tiles, &ctx, renderTile);
    if (opts.wireframe) drawWireframe(&ctx, view_proj, world_to_view, view.shift_ndc);

    return .{
        .width = width,
        .height = height,
        .rgba = rgba,
        .depth = depth,
        .object_id = object_id,
        .triangles = n_tris,
        .camera_name = camera_name,
    };
}

const vert_chunk = 16384;
const face_chunk = 8192;

const Range = struct { inst: u32, lo: u32, hi: u32 };

/// One face chunk's triangles; clipped triangles index `clip` locally.
const ChunkOut = struct {
    tris: std.ArrayList(Tri) = .empty,
    clip: std.ArrayList(ScreenVert) = .empty,
    clip_bary: std.ArrayList([3]f32) = .empty,
    oom: bool = false,

    fn deinit(o: *ChunkOut, gpa: Allocator) void {
        o.tris.deinit(gpa);
        o.clip.deinit(gpa);
        o.clip_bary.deinit(gpa);
    }
};

const SetupCtx = struct {
    gpa: Allocator,
    insts: []const Instance,
    nodes: []const ir.Node,
    verts: []ScreenVert,
    view_proj: Mat4,
    world_to_view: Mat4,
    width: f32,
    height: f32,
    shift: [2]f32,
    vchunks: []const Range,
    fchunks: []const Range,
    outs: []ChunkOut,

    fn transform(c: *const SetupCtx, k: usize) void {
        const r = c.vchunks[k];
        const inst = c.insts[r.inst];
        const world = c.nodes[inst.node].world;
        const mvp = v.matMul(c.view_proj, world);
        const mv = v.matMul(c.world_to_view, world);
        for (r.lo..r.hi) |i| {
            c.verts[inst.vert_base + i] = project(mvp, mv, inst.mesh.positions[i], c.width, c.height, c.shift);
        }
    }

    fn triangles(c: *const SetupCtx, k: usize) void {
        c.trianglesInner(k) catch {
            c.outs[k].oom = true;
        };
    }

    fn trianglesInner(c: *const SetupCtx, k: usize) Allocator.Error!void {
        const r = c.fchunks[k];
        const out = &c.outs[k];
        const inst = c.insts[r.inst];
        const m = inst.mesh;
        const world = c.nodes[inst.node].world;
        const mvp = v.matMul(c.view_proj, world);
        const mv = v.matMul(c.world_to_view, world);
        var local: std.ArrayList(u32) = .empty;
        defer local.deinit(c.gpa);
        try out.tris.ensureTotalCapacity(c.gpa, (r.hi - r.lo) * 2);
        for (r.lo..r.hi) |f| {
            const start = m.face_offsets[f];
            const corners = m.corner_verts[start..m.face_offsets[f + 1]];
            local.clearRetainingCapacity();
            try math.triangulate.triangulate(c.gpa, m.positions, corners, &local);
            const slot: u16 = if (m.face_material.len > 0) m.face_material[f] else 0;
            var t: usize = 0;
            while (t < local.items.len) : (t += 3) {
                const cn = [3]u32{ start + local.items[t], start + local.items[t + 1], start + local.items[t + 2] };
                const vi = [3]u32{ inst.vert_base + m.corner_verts[cn[0]], inst.vert_base + m.corner_verts[cn[1]], inst.vert_base + m.corner_verts[cn[2]] };
                const sv = [3]ScreenVert{ c.verts[vi[0]], c.verts[vi[1]], c.verts[vi[2]] };
                const inside = @as(u8, @intFromBool(sv[0].d >= 0)) + @intFromBool(sv[1].d >= 0) + @intFromBool(sv[2].d >= 0);
                if (inside == 0) continue;
                if (inside == 3) {
                    if (offscreen(sv, c.width, c.height) or missesPixelCentres(sv)) continue;
                    try out.tris.append(c.gpa, .{ .v = vi, .c = cn, .inst = r.inst, .slot = slot, .clipped = false });
                    continue;
                }
                try clipNear(c.gpa, out, mvp, mv, m.positions, m.corner_verts, cn, r.inst, slot, c.width, c.height, c.shift);
            }
        }
    }
};

const MergeCtx = struct {
    outs: []ChunkOut,
    tri_base: []const u32,
    clip_base: []const u32,
    tris: []Tri,
    verts: []const ScreenVert,
    clip_verts: []ScreenVert,
    clip_bary: [][3]f32,
    rects: [][4]u8,
    counts: []u32,
    tiles_x: u32,
    tiles_y: u32,
    n_tiles: usize,
    tile_tris: []u32 = &.{},

    /// Copies chunk `k` into the global arrays and counts its tiles.
    fn merge(c: *const MergeCtx, k: usize) void {
        const o = &c.outs[k];
        const tb = c.tri_base[k];
        const cb = c.clip_base[k];
        @memcpy(c.clip_verts[cb..][0..o.clip.items.len], o.clip.items);
        @memcpy(c.clip_bary[cb..][0..o.clip.items.len], o.clip_bary.items);
        const counts = c.counts[k * c.n_tiles ..][0..c.n_tiles];
        for (o.tris.items, 0..) |src, i| {
            var t = src;
            if (t.clipped) for (&t.v) |*x| {
                x.* += cb;
            };
            c.tris[tb + i] = t;
            const sv = triVerts(t, c.verts, c.clip_verts);
            const tile_f: f32 = tile_size;
            const max_tx: f32 = @floatFromInt(c.tiles_x - 1);
            const max_ty: f32 = @floatFromInt(c.tiles_y - 1);
            const rect = [4]u8{
                @intFromFloat(std.math.clamp(@floor(@min(sv[0].x, @min(sv[1].x, sv[2].x)) / tile_f), 0, max_tx)),
                @intFromFloat(std.math.clamp(@floor(@min(sv[0].y, @min(sv[1].y, sv[2].y)) / tile_f), 0, max_ty)),
                @intFromFloat(std.math.clamp(@floor(@max(sv[0].x, @max(sv[1].x, sv[2].x)) / tile_f), 0, max_tx)),
                @intFromFloat(std.math.clamp(@floor(@max(sv[0].y, @max(sv[1].y, sv[2].y)) / tile_f), 0, max_ty)),
            };
            c.rects[tb + i] = rect;
            for (rect[1]..@as(usize, rect[3]) + 1) |ty| for (rect[0]..@as(usize, rect[2]) + 1) |tx| {
                counts[ty * c.tiles_x + tx] += 1;
            };
        }
    }

    /// Writes chunk `k`'s triangle indices into each tile's list, at the
    /// positions the prefix sums reserved for it.
    fn fill(c: *const MergeCtx, k: usize) void {
        const o = &c.outs[k];
        const tb = c.tri_base[k];
        const pos = c.counts[k * c.n_tiles ..][0..c.n_tiles];
        for (0..o.tris.items.len) |i| {
            const rect = c.rects[tb + i];
            for (rect[1]..@as(usize, rect[3]) + 1) |ty| for (rect[0]..@as(usize, rect[2]) + 1) |tx| {
                const t = ty * c.tiles_x + tx;
                c.tile_tris[pos[t]] = tb + @as(u32, @intCast(i));
                pos[t] += 1;
            };
        }
    }
};

/// True when the triangle's bounds contain no pixel centre, so it cannot
/// cover any sample; dense meshes drop most of their triangles here.
fn missesPixelCentres(sv: [3]ScreenVert) bool {
    const min_x = @min(sv[0].x, @min(sv[1].x, sv[2].x));
    const max_x = @max(sv[0].x, @max(sv[1].x, sv[2].x));
    const min_y = @min(sv[0].y, @min(sv[1].y, sv[2].y));
    const max_y = @max(sv[0].y, @max(sv[1].y, sv[2].y));
    return @ceil(min_x - 0.5) > @floor(max_x - 0.5) or @ceil(min_y - 0.5) > @floor(max_y - 0.5);
}

const identity3: [3][3]f32 = .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };

fn project(mvp: Mat4, mv: Mat4, p: Vec3, width: f32, height: f32, shift: [2]f32) ScreenVert {
    const x = mvp[0] * p[0] + mvp[4] * p[1] + mvp[8] * p[2] + mvp[12];
    const y = mvp[1] * p[0] + mvp[5] * p[1] + mvp[9] * p[2] + mvp[13];
    const z = mvp[2] * p[0] + mvp[6] * p[1] + mvp[10] * p[2] + mvp[14];
    const w = mvp[3] * p[0] + mvp[7] * p[1] + mvp[11] * p[2] + mvp[15];
    const vz = mv[2] * p[0] + mv[6] * p[1] + mv[10] * p[2] + mv[14];
    return clipToScreen(.{ x, y, z, w }, vz, width, height, shift);
}

fn clipToScreen(c: [4]f32, view_z: f32, width: f32, height: f32, shift: [2]f32) ScreenVert {
    const d = c[2] + c[3];
    if (c[3] <= 1e-20) return .{ .x = 0, .y = 0, .z = 0, .w_inv = 0, .d = @min(d, -1e-30), .view_z = view_z };
    const iw = 1 / c[3];
    return .{
        .x = ((c[0] * iw + shift[0]) * 0.5 + 0.5) * width,
        .y = (0.5 - (c[1] * iw + shift[1]) * 0.5) * height,
        .z = c[2] * iw * 0.5 + 0.5,
        .w_inv = iw,
        .d = d,
        .view_z = view_z,
    };
}

fn offscreen(sv: [3]ScreenVert, w: f32, h: f32) bool {
    if (sv[0].x < 0 and sv[1].x < 0 and sv[2].x < 0) return true;
    if (sv[0].y < 0 and sv[1].y < 0 and sv[2].y < 0) return true;
    if (sv[0].x > w and sv[1].x > w and sv[2].x > w) return true;
    if (sv[0].y > h and sv[1].y > h and sv[2].y > h) return true;
    return false;
}

fn triVerts(tri: Tri, verts: []const ScreenVert, clip_verts: []const ScreenVert) [3]ScreenVert {
    const src = if (tri.clipped) clip_verts else verts;
    return .{ src[tri.v[0]], src[tri.v[1]], src[tri.v[2]] };
}

/// Sutherland–Hodgman against the near plane in clip space, tracking each new
/// vertex's barycentric coordinates in the original triangle.
fn clipNear(
    gpa: Allocator,
    out_chunk: *ChunkOut,
    mvp: Mat4,
    mv: Mat4,
    positions: []const Vec3,
    corner_verts: []const u32,
    c: [3]u32,
    inst: u32,
    slot: u16,
    width: f32,
    height: f32,
    shift: [2]f32,
) Allocator.Error!void {
    const P = struct { clip: [4]f32, vz: f32, bary: [3]f32 };
    var in: [3]P = undefined;
    for (0..3) |k| {
        const p = positions[corner_verts[c[k]]];
        var cl: [4]f32 = undefined;
        for (0..4) |r| cl[r] = mvp[r] * p[0] + mvp[4 + r] * p[1] + mvp[8 + r] * p[2] + mvp[12 + r];
        const vz = mv[2] * p[0] + mv[6] * p[1] + mv[10] * p[2] + mv[14];
        in[k] = .{ .clip = cl, .vz = vz, .bary = identity3[k] };
    }
    var out: [4]P = undefined;
    var n: usize = 0;
    for (0..3) |k| {
        const a = in[k];
        const b = in[(k + 1) % 3];
        const da = a.clip[2] + a.clip[3];
        const db = b.clip[2] + b.clip[3];
        if (da >= 0) {
            out[n] = a;
            n += 1;
        }
        if ((da >= 0) != (db >= 0)) {
            const t = da / (da - db);
            var p: P = undefined;
            for (0..4) |r| p.clip[r] = a.clip[r] + (b.clip[r] - a.clip[r]) * t;
            // Nudge onto the visible side so the vertex projects.
            p.clip[2] = @max(p.clip[2], -p.clip[3]);
            p.vz = a.vz + (b.vz - a.vz) * t;
            for (0..3) |r| p.bary[r] = a.bary[r] + (b.bary[r] - a.bary[r]) * t;
            out[n] = p;
            n += 1;
        }
    }
    if (n < 3) return;
    const base: u32 = @intCast(out_chunk.clip.items.len);
    for (out[0..n]) |p| {
        try out_chunk.clip.append(gpa, clipToScreen(p.clip, p.vz, width, height, shift));
        try out_chunk.clip_bary.append(gpa, p.bary);
    }
    for (1..n - 1) |k| {
        try out_chunk.tris.append(gpa, .{
            .v = .{ base, base + @as(u32, @intCast(k)), base + @as(u32, @intCast(k + 1)) },
            .c = c,
            .inst = inst,
            .slot = slot,
            .clipped = true,
        });
    }
}

fn edge(ax: f32, ay: f32, bx: f32, by: f32, px: f32, py: f32) f32 {
    return (bx - ax) * (py - ay) - (by - ay) * (px - ax);
}

fn renderTile(ctx: *const Ctx, tile: usize) void {
    const tx: u32 = @intCast(tile % ctx.tiles_x);
    const ty: u32 = @intCast(tile / ctx.tiles_x);
    const x0 = tx * tile_size;
    const y0 = ty * tile_size;
    const x1 = @min(x0 + tile_size, ctx.opts.width);
    const y1 = @min(y0 + tile_size, ctx.opts.height);

    var zbuf: [tile_size * tile_size]f32 = undefined;
    var tbuf: [tile_size * tile_size]u32 = undefined;
    @memset(&zbuf, std.math.inf(f32));
    @memset(&tbuf, no_tri);

    for (ctx.tile_tris[ctx.tile_start[tile]..ctx.tile_start[tile + 1]]) |ti| {
        const tri = ctx.tris[ti];
        var sv = triVerts(tri, ctx.verts, ctx.clip_verts);
        // Screen y points down, so front faces (CCW in NDC) have area < 0.
        var area = edge(sv[0].x, sv[0].y, sv[1].x, sv[1].y, sv[2].x, sv[2].y);
        if (area == 0 or !std.math.isFinite(area)) continue;
        if (area > 0) {
            if (ctx.insts[tri.inst].cull_back) continue;
            std.mem.swap(ScreenVert, &sv[1], &sv[2]);
            area = -area;
        }
        const min_x = @max(@as(f32, @floatFromInt(x0)), @floor(@min(sv[0].x, @min(sv[1].x, sv[2].x))));
        const max_x = @min(@as(f32, @floatFromInt(x1 - 1)), @ceil(@max(sv[0].x, @max(sv[1].x, sv[2].x))));
        const min_y = @max(@as(f32, @floatFromInt(y0)), @floor(@min(sv[0].y, @min(sv[1].y, sv[2].y))));
        const max_y = @min(@as(f32, @floatFromInt(y1 - 1)), @ceil(@max(sv[0].y, @max(sv[1].y, sv[2].y))));
        if (min_x > max_x or min_y > max_y) continue;
        const inv_area = 1 / area;
        var py = min_y;
        while (py <= max_y) : (py += 1) {
            var px = min_x;
            while (px <= max_x) : (px += 1) {
                const cx = px + 0.5;
                const cy = py + 0.5;
                // Edge functions are ≤ 0 inside for this winding.
                const e0 = edge(sv[1].x, sv[1].y, sv[2].x, sv[2].y, cx, cy);
                const e1 = edge(sv[2].x, sv[2].y, sv[0].x, sv[0].y, cx, cy);
                const e2 = edge(sv[0].x, sv[0].y, sv[1].x, sv[1].y, cx, cy);
                if (e0 > 0 or e1 > 0 or e2 > 0) continue;
                const b0 = e0 * inv_area;
                const b1 = e1 * inv_area;
                const b2 = e2 * inv_area;
                const z = b0 * sv[0].z + b1 * sv[1].z + b2 * sv[2].z;
                if (z < 0 or z > 1) continue;
                const lx: u32 = @as(u32, @intFromFloat(px)) - x0;
                const ly: u32 = @as(u32, @intFromFloat(py)) - y0;
                const k = ly * tile_size + lx;
                if (z < zbuf[k]) {
                    zbuf[k] = z;
                    tbuf[k] = ti;
                }
            }
        }
    }

    // Deferred shading: one shade per pixel.
    const key = v.normalize(.{ -0.45, 0.55, 0.7 });
    const fill = v.normalize(.{ 0.6, -0.2, 0.5 });
    for (y0..y1) |y| {
        for (x0..x1) |x| {
            const k = (y - y0) * tile_size + (x - x0);
            const out = y * ctx.opts.width + x;
            if (tbuf[k] == no_tri) {
                writePixel(ctx.rgba[out * 4 ..][0..4], ctx.background);
                ctx.depth[out] = std.math.inf(f32);
                ctx.object_id[out] = 0;
                continue;
            }
            const tri = ctx.tris[tbuf[k]];
            const inst = ctx.insts[tri.inst];
            const sv = triVerts(tri, ctx.verts, ctx.clip_verts);
            const cx = @as(f32, @floatFromInt(x)) + 0.5;
            const cy = @as(f32, @floatFromInt(y)) + 0.5;
            const area = edge(sv[0].x, sv[0].y, sv[1].x, sv[1].y, sv[2].x, sv[2].y);
            var b = [3]f32{
                edge(sv[1].x, sv[1].y, sv[2].x, sv[2].y, cx, cy) / area,
                edge(sv[2].x, sv[2].y, sv[0].x, sv[0].y, cx, cy) / area,
                edge(sv[0].x, sv[0].y, sv[1].x, sv[1].y, cx, cy) / area,
            };
            // Perspective-correct weights.
            var sum: f32 = 0;
            for (0..3) |i| {
                b[i] *= sv[i].w_inv;
                sum += b[i];
            }
            if (sum != 0) for (&b) |*x_| {
                x_.* /= sum;
            };
            var view_z: f32 = 0;
            for (0..3) |i| view_z += b[i] * sv[i].view_z;
            // Map to the original triangle's corners.
            var ob: [3]f32 = .{ 0, 0, 0 };
            for (0..3) |i| {
                const basis = if (tri.clipped) ctx.clip_bary[tri.v[i]] else identity3[i];
                for (0..3) |r| ob[r] += b[i] * basis[r];
            }
            const normals = inst.mesh.corner_normals;
            var nl: Vec3 = .{ 0, 0, 0 };
            for (0..3) |r| nl = v.add(nl, v.scale(normals[tri.c[r]], ob[r]));
            var n = v.normalize(v.transformDir(inst.normal_to_view, nl));
            // Double-sided: shade the side facing the camera.
            if (n[2] < 0) n = v.scale(n, -1);
            const slot = @min(tri.slot, inst.slot_colors.len - 1);
            const base = inst.slot_colors[slot];
            const emis = inst.slot_emission[slot];
            const light = 0.22 + 0.68 * @max(0, v.dot(n, key)) + 0.18 * @max(0, v.dot(n, fill));
            const col = [4]f32{
                base[0] * light + emis[0],
                base[1] * light + emis[1],
                base[2] * light + emis[2],
                1,
            };
            writePixel(ctx.rgba[out * 4 ..][0..4], col);
            ctx.depth[out] = -view_z;
            ctx.object_id[out] = inst.node + 1;
        }
    }
}

/// Standard view transform: clamp, then the sRGB transfer function.
pub fn linearToSrgb8(x: f32) u8 {
    const c = std.math.clamp(x, 0, 1);
    const s = if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(s * 255));
}

fn writePixel(dst: *[4]u8, c: [4]f32) void {
    dst[0] = linearToSrgb8(c[0]);
    dst[1] = linearToSrgb8(c[1]);
    dst[2] = linearToSrgb8(c[2]);
    dst[3] = @intFromFloat(@round(std.math.clamp(c[3], 0, 1) * 255));
}

/// Overlays mesh edges, depth-tested against the shaded image. Runs on one
/// thread after the tiles, in scene order.
fn drawWireframe(ctx: *Ctx, view_proj: Mat4, world_to_view: Mat4, shift: [2]f32) void {
    const w: f32 = @floatFromInt(ctx.opts.width);
    const h: f32 = @floatFromInt(ctx.opts.height);
    for (ctx.insts) |inst| {
        const world = ctx.scene.nodes[inst.node].world;
        const mvp = v.matMul(view_proj, world);
        const mv = v.matMul(world_to_view, world);
        for (inst.mesh.edges) |e| {
            const a = project(mvp, mv, inst.mesh.positions[e[0]], w, h, shift);
            const b = project(mvp, mv, inst.mesh.positions[e[1]], w, h, shift);
            if (a.d < 0 or b.d < 0) continue;
            const dx = b.x - a.x;
            const dy = b.y - a.y;
            const steps: usize = @intFromFloat(@min(8192, @max(@abs(dx), @abs(dy)) + 1));
            for (0..steps + 1) |s| {
                const t = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(steps));
                const x = a.x + dx * t;
                const y = a.y + dy * t;
                if (x < 0 or y < 0 or x >= w or y >= h) continue;
                const xi: usize = @intFromFloat(x);
                const yi: usize = @intFromFloat(y);
                const k = yi * ctx.opts.width + xi;
                // Perspective-correct view depth along the edge.
                const iw = a.w_inv + (b.w_inv - a.w_inv) * t;
                const vz = (a.view_z * a.w_inv + (b.view_z * b.w_inv - a.view_z * a.w_inv) * t) / iw;
                const dist = -vz;
                if (dist > ctx.depth[k] * 1.002 + 1e-4) continue;
                const px = ctx.rgba[k * 4 ..][0..4];
                for (0..3) |c| px[c] = @intCast((@as(u16, px[c]) * 3) / 10);
                px[3] = 255;
            }
        }
    }
}

test "renders a quad in front of the automatic view and is thread-count independent" {
    const gpa = std.testing.allocator;
    const mesh: ir.Mesh = .{
        .name = "Quad",
        .positions = &.{ .{ -1, -1, 0 }, .{ 1, -1, 0 }, .{ 1, 1, 0 }, .{ -1, 1, 0 } },
        .face_offsets = &.{ 0, 4 },
        .corner_verts = &.{ 0, 1, 2, 3 },
        .corner_normals = &.{ .{ 0, 0, 1 }, .{ 0, 0, 1 }, .{ 0, 0, 1 }, .{ 0, 0, 1 } },
        .corner_uvs = &.{},
        .face_material = &.{},
        .edges = &.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 } },
    };
    const scene: ir.Scene = .{
        .name = "S",
        .nodes = &.{.{ .name = "Quad", .parent = null, .local = v.identity, .world = v.identity, .kind = .{ .mesh = 0 }, .materials = &.{}, .hide_render = false }},
        .meshes = &.{mesh},
        .materials = &.{},
        .cameras = &.{},
        .lights = &.{},
        .world = .{ .color = .{ 0.05, 0.05, 0.05 }, .strength = 1 },
        .active_camera = null,
        .resolution = .{ 64, 64 },
        .fps = 24,
        .frame_start = 1,
        .frame_end = 1,
    };
    var hashes: [3]u64 = undefined;
    for ([_]usize{ 1, 4, 16 }, 0..) |threads, i| {
        var r = try render(gpa, &scene, .{ .width = 150, .height = 100, .wireframe = true, .pool = .{ .io = std.testing.io, .threads = threads } });
        defer r.deinit(gpa);
        // The centre pixel sees the quad.
        try std.testing.expectEqual(@as(u32, 1), r.object_id[50 * 150 + 75]);
        try std.testing.expectEqual(@as(u32, 0), r.object_id[0]);
        hashes[i] = std.hash.Wyhash.hash(0, r.rgba);
    }
    try std.testing.expectEqual(hashes[0], hashes[1]);
    try std.testing.expectEqual(hashes[0], hashes[2]);
}

test "floor through the near plane is clipped, not dropped" {
    const gpa = std.testing.allocator;
    const floor: ir.Mesh = .{
        .name = "Floor",
        .positions = &.{ .{ -50, -50, 0 }, .{ 50, -50, 0 }, .{ 50, 50, 0 }, .{ -50, 50, 0 } },
        .face_offsets = &.{ 0, 4 },
        .corner_verts = &.{ 0, 1, 2, 3 },
        .corner_normals = &.{ .{ 0, 0, 1 }, .{ 0, 0, 1 }, .{ 0, 0, 1 }, .{ 0, 0, 1 } },
        .corner_uvs = &.{},
        .face_material = &.{},
        .edges = &.{},
    };
    const cam: ir.Camera = .{ .name = "Cam", .projection = .perspective, .lens_mm = 50, .sensor_width_mm = 36, .sensor_height_mm = 24, .sensor_fit = .auto, .ortho_scale = 6, .clip_start = 0.1, .clip_end = 100, .shift = .{ 0, 0 } };
    // Eye 0.5 m above the floor, looking along +Y, tilted down 10°.
    const rot = v.eulerToQuat(.{ v.degToRad(80), 0, 0 }, .xyz);
    const cam_world = v.compose(.{ 0, 0, 0.5 }, rot, .{ 1, 1, 1 });
    const scene: ir.Scene = .{
        .name = "S",
        .nodes = &.{
            .{ .name = "Floor", .parent = null, .local = v.identity, .world = v.identity, .kind = .{ .mesh = 0 }, .materials = &.{}, .hide_render = false },
            .{ .name = "Cam", .parent = null, .local = cam_world, .world = cam_world, .kind = .{ .camera = 0 }, .materials = &.{}, .hide_render = false },
        },
        .meshes = &.{floor},
        .materials = &.{},
        .cameras = &.{cam},
        .lights = &.{},
        .world = .{ .color = .{ 0.05, 0.05, 0.05 }, .strength = 1 },
        .active_camera = 1,
        .resolution = .{ 160, 90 },
        .fps = 24,
        .frame_start = 1,
        .frame_end = 1,
    };
    var first: u64 = 0;
    for ([_]usize{ 1, 3, 16 }) |threads| {
        var r = try render(gpa, &scene, .{ .width = 160, .height = 90, .pool = .{ .io = std.testing.io, .threads = threads } });
        defer r.deinit(gpa);
        // Bottom rows see the floor right in front of the camera; top rows see sky.
        try std.testing.expectEqual(@as(u32, 1), r.object_id[89 * 160 + 80]);
        try std.testing.expectEqual(@as(u32, 0), r.object_id[0 * 160 + 80]);
        try std.testing.expect(r.depth[89 * 160 + 80] < 5);
        const h = std.hash.Wyhash.hash(0, r.rgba);
        if (first == 0) first = h else try std.testing.expectEqual(first, h);
    }
}
