"""Gate G1.5: builds the bust of bust_spec.py with Blender's own tools,
reads Zender's glTF of examples/bust.jsonl, and compares the two part by
part (symmetric vertex Hausdorff distance and enclosed volume).

blender -b --factory-startup --python examples/bust/blender_parity.py -- <zender bust.glb> <report.json> [<blend to save>]

ONLY=Head,Hair limits the run to those parts and merges their rows into an
existing report, so a phone can check the big parts one process at a time.

The Zender meshes are read straight from the GLB with numpy.
Implicit parts are sampled with numpy by bust_spec.evaluate (mesh.from_sdf's
semantics) and meshed by the same surface-nets rule; the crown, sticks,
shoulder guards and rims use bmesh, curves and Blender's modifiers.
"""
import bpy, bmesh, json, math, os, sys, time
import numpy as np
from mathutils import Matrix, Vector, Euler, kdtree

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bust_spec as B
from sdf_np import surface_nets

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
GLB, REPORT = ARGS[0], ARGS[1]
ONLY = set(filter(None, os.environ.get("ONLY", "").split(",")))
T0 = time.time()
def log(*a): print(f"[{time.time() - T0:6.1f}s]", *a, flush=True)
def want(name): return not ONLY or name in ONLY

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
built = {}   # part name -> (Blender object, tolerance m, closed)

def link(name, data):
    ob = bpy.data.objects.new("B:" + name, data); scene.collection.objects.link(ob)
    return ob

def mesh_object(name, verts, faces):
    me = bpy.data.meshes.new(name); me.from_pydata([tuple(map(float, v)) for v in verts], [], [tuple(map(int, f)) for f in faces]); me.update()
    return link(name, me)

# ---------------------------------------------------------------- implicit parts
med_mesh = None
medallions = [m for m in B.medallion_placements() if want(m["name"])]
for part in B.SDF_PARTS:
    if not (medallions if part["name"] == "Medallion" else want(part["name"])): continue
    g, field = B.evaluate(part["steps"](), part["lo"], part["hi"], part["voxel"])
    verts, quads = surface_nets(field, g.o, float(g.v))
    log(part["name"], "grid", g.n, len(verts), "verts")
    if part["name"] == "Medallion":
        me = bpy.data.meshes.new("Medallion"); me.from_pydata(verts.tolist(), [], quads.tolist()); me.update(); med_mesh = me
        continue
    built[part["name"]] = (mesh_object(part["name"], verts, quads), float(part["voxel"]), True)
    del g, field, verts, quads
for m in medallions:
    ob = link(m["name"], med_mesh)
    ob.matrix_world = Matrix.Translation(Vector(m["location"])) @ Euler(m["rotation"], "XYZ").to_matrix().to_4x4() @ Matrix.Scale(m["scale"], 4)
    sub = ob.modifiers.new("Subdivision", "SUBSURF"); sub.levels = 1; sub.render_levels = 1
    built[m["name"]] = (ob, 0.006 * m["scale"], True)

# ---------------------------------------------------------------- crown
if want("Crown"):
    verts, faces, uvs, mats = B.crown_mesh()
    crown = mesh_object("Crown", verts, faces)
    sol = crown.modifiers.new("Thickness", "SOLIDIFY"); sol.thickness = 0.035; sol.offset = 1
    bev = crown.modifiers.new("Bevel", "BEVEL"); bev.width = 0.01; bev.segments = 2; bev.limit_method = "ANGLE"; bev.angle_limit = math.radians(30)
    crown.matrix_world = Matrix.Translation(Vector(B.CROWN_LOC)) @ Euler(B.CROWN_ROT, "XYZ").to_matrix().to_4x4()
    built["Crown"] = (crown, 0.01, True)

# ---------------------------------------------------------------- breadsticks and rims: curves
def tube(name, splines, bevel, caps):
    cu = bpy.data.curves.new(name, "CURVE"); cu.dimensions = "3D"; cu.bevel_depth = bevel; cu.bevel_resolution = 4; cu.use_fill_caps = caps
    for pts in splines:
        sp = cu.splines.new("POLY"); sp.points.add(len(pts) - 1)
        for P, p in zip(sp.points, pts): P.co = (*p, 1)
    return link(name, cu)
if want("Whiskers"):
    built["Whiskers"] = (tube("Whiskers", B.whisker_splines(), 0.034, True), 0.01, True)
shells, rims = B.pauldron_parts()
for rim in filter(lambda r: want(r["name"]), rims):
    built[rim["name"]] = (tube(rim["name"], [rim["points"]], rim["bevel"], False), 0.01, False)

# ---------------------------------------------------------------- shoulder guards: lathed shells
for sh in filter(lambda s: want(s["name"]), shells):
    count, depth, groove = sh["relief"]
    a0, a1 = (math.radians(x) for x in sh["angle"])
    sweep = a1 - a0
    closed = abs(sweep - 2 * math.pi) < 1e-6
    segs = sh["segments"]; cols = segs if closed else segs + 1
    prof = sh["profile"]; n = len(prof)
    bm = bmesh.new(); grid = []
    for j in range(cols):
        b = a0 + sweep * j / segs
        h = B.relief_at(count, depth, groove, sweep * (j / segs) / (2 * math.pi))
        grid.append([bm.verts.new(((r + h) * math.cos(b), (r + h) * math.sin(b), t)) for t, r in prof])
    for j in range(segs):
        j1 = (j + 1) % segs if closed else j + 1
        for k in range(n - 1):
            bm.faces.new((grid[j][k], grid[j1][k], grid[j1][k + 1], grid[j][k + 1]))
    me = bpy.data.meshes.new(sh["name"]); bm.to_mesh(me); bm.free()
    ob = link(sh["name"], me)
    ob.matrix_world = Matrix.Translation(Vector(sh["location"])) @ Euler(sh["rotation"], "XYZ").to_matrix().to_4x4()
    sol = ob.modifiers.new("Thickness", "SOLIDIFY"); sol.thickness = sh["thickness"]; sol.offset = -1
    sub = ob.modifiers.new("Subdivision", "SUBSURF"); sub.levels = 1; sub.render_levels = 1
    built[sh["name"]] = (ob, 0.01, True)
log("Blender parts built:", len(built))

# ---------------------------------------------------------------- Zender's glTF
def read_glb(path):
    """World-space (Z-up) vertices and triangles per mesh node, read with
    numpy; Blender's importer needs several GB for the 3M-triangle bust."""
    import struct
    data = open(path, "rb").read()
    jlen = struct.unpack_from("<I", data, 12)[0]
    j = json.loads(data[20:20 + jlen])
    bin0 = 20 + jlen + 8
    def accessor(i):
        a = j["accessors"][i]; bv = j["bufferViews"][a["bufferView"]]
        dt = {5126: np.float32, 5125: np.uint32, 5123: np.uint16}[a["componentType"]]
        k = {"SCALAR": 1, "VEC3": 3}[a["type"]]
        start = bin0 + bv.get("byteOffset", 0) + a.get("byteOffset", 0)
        return np.frombuffer(data, dt, a["count"] * k, start).reshape(a["count"], k)
    out = {}
    for n in j["nodes"]:
        if "mesh" not in n or n["name"] not in built: continue
        x, y, z, w = n.get("rotation", [0, 0, 0, 1])
        R = np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                      [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                      [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])
        M = R * np.array(n.get("scale", [1, 1, 1]))
        vs, ts, base = [], [], 0
        for prim in j["meshes"][n["mesh"]]["primitives"]:
            v = accessor(prim["attributes"]["POSITION"]).astype(np.float64) @ M.T + np.array(n.get("translation", [0, 0, 0]))
            vs.append(np.stack([v[:, 0], -v[:, 2], v[:, 1]], 1))   # glTF Y-up -> Z-up
            ts.append(accessor(prim["indices"]).reshape(-1, 3).astype(np.int64) + base); base += len(v)
        out[n["name"]] = (np.concatenate(vs), np.concatenate(ts))
    return out
zender = read_glb(GLB)
log("read", len(zender), "Zender meshes")

def world_mesh(ob):
    """World-space vertices and triangles of the evaluated object."""
    dg = bpy.context.evaluated_depsgraph_get()
    ev = ob.evaluated_get(dg)
    me = ev.to_mesh()
    me.calc_loop_triangles()
    M = np.array(ob.matrix_world)
    v = np.empty(len(me.vertices) * 3); me.vertices.foreach_get("co", v); v = v.reshape(-1, 3)
    v = v @ M[:3, :3].T + M[:3, 3]
    t = np.empty(len(me.loop_triangles) * 3, dtype=np.int64); me.loop_triangles.foreach_get("vertices", t)
    ev.to_mesh_clear()
    return v, t.reshape(-1, 3)

def volume(v, t):
    a, b, c = v[t[:, 0]], v[t[:, 1]], v[t[:, 2]]
    return float(np.einsum("ij,ij->i", a, np.cross(b, c)).sum() / 6)

def one_way(src, dst):
    kd = kdtree.KDTree(len(dst))
    for i, p in enumerate(dst): kd.insert(p, i)
    kd.balance()
    d = np.array([kd.find(p)[2] for p in src])
    return float(d.max()), float(d.mean())

rows = []
for name, (bob, tol, closed) in built.items():
    if name not in zender:
        rows.append(dict(part=name, error="missing in Zender's glTF")); continue
    bv, bt = world_mesh(bob); zv, zt = zender[name]
    h1, m1 = one_way(bv, zv); h2, m2 = one_way(zv, bv)
    row = dict(part=name, blender_verts=len(bv), zender_verts=len(zv), hausdorff=max(h1, h2), mean=(m1 + m2) / 2, tolerance=tol)
    if closed:
        vb, vz = volume(bv, bt), volume(zv, zt)
        row.update(volume_blender=vb, volume_zender=vz, volume_diff=abs(vz - vb) / abs(vb))
    row["pass"] = row["hausdorff"] <= tol and (not closed or row["volume_diff"] <= 0.01)
    rows.append(row)
    del bv, bt, zender[name]
    log(f"{name:24s} H {row['hausdorff']:.5f} m (tol {tol:.4f})  mean {row['mean']:.5f}" + (f"  vol {row['volume_diff'] * 100:.3f}%" if closed else "") + ("  PASS" if row["pass"] else "  FAIL"))

if ONLY and os.path.exists(REPORT):
    done = {r["part"] for r in rows}
    rows = [r for r in json.load(open(REPORT))["rows"] if r["part"] not in done] + rows
json.dump(dict(rows=rows, passed=sum(1 for r in rows if r.get("pass")), total=len(rows)), open(REPORT, "w"), indent=1)
log(f"{sum(1 for r in rows if r.get('pass'))} of {len(rows)} parts within tolerance; report {REPORT}")
if len(ARGS) > 2:
    bpy.ops.wm.save_as_mainfile(filepath=ARGS[2])
