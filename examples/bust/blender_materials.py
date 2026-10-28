"""Gate G1.5, materials and bake: builds each material of bust_spec.py as a
Blender node tree (values from the spec, Blender's defaults for the rest)
and compares every value Zender's canonical scene.json stores; then bakes
the crown's camouflage and the breadstick crust with Cycles on the same
meshes and UVs and compares Zender's baked images texel by texel.

blender -b --factory-startup --python examples/bust/blender_materials.py -- <zender bust.glb> <zender bust.json> <report.json>

The bake comparison counts only texels whose centres lie on the baked faces
(margins differ by design) in the 8-bit sRGB values both images store.
"""
import bpy, json, math, os, struct, sys, tempfile, time
import numpy as np
from mathutils import Matrix, Vector, Euler

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bust_spec as B

GLB, SCENE, REPORT = sys.argv[sys.argv.index("--") + 1:][:3]
T0 = time.time()
def log(*a): print(f"[{time.time() - T0:6.1f}s]", *a, flush=True)

bpy.ops.wm.read_factory_settings(use_empty=True)

# ---------------------------------------------------------------- spec -> node tree
PRINCIPLED = {  # Zender property -> Principled BSDF input
    "base_color": "Base Color", "metallic": "Metallic", "roughness": "Roughness", "ior": "IOR", "alpha": "Alpha",
    "transmission": "Transmission Weight", "emission_color": "Emission Color", "emission_strength": "Emission Strength",
    "coat_weight": "Coat Weight", "coat_roughness": "Coat Roughness", "coat_ior": "Coat IOR", "coat_tint": "Coat Tint",
    "sheen_weight": "Sheen Weight", "sheen_roughness": "Sheen Roughness", "sheen_tint": "Sheen Tint",
    "specular_ior_level": "Specular IOR Level", "specular_tint": "Specular Tint",
}
TEX_INPUTS = {  # recipe field -> node input
    "noise": {"scale": "Scale", "detail": "Detail", "roughness": "Roughness", "lacunarity": "Lacunarity", "distortion": "Distortion"},
    "wave": {"scale": "Scale", "distortion": "Distortion", "detail": "Detail", "detail_scale": "Detail Scale", "detail_roughness": "Detail Roughness", "phase": "Phase Offset"},
    "voronoi": {"scale": "Scale", "randomness": "Randomness"},
}
NODE = {"noise": "ShaderNodeTexNoise", "wave": "ShaderNodeTexWave", "voronoi": "ShaderNodeTexVoronoi"}

def texture_chain(nt, r):
    """Texture Coordinate -> Mapping -> texture (-> Color Ramp); returns
    (texture node, ramp node or None, output socket)."""
    coords = nt.nodes.new("ShaderNodeTexCoord")
    mapping = nt.nodes.new("ShaderNodeMapping")
    nt.links.new(coords.outputs[{"object": "Object", "generated": "Generated", "uv": "UV", "normal": "Normal"}[r.get("coords", "object")]], mapping.inputs["Vector"])
    m = r.get("mapping", {})
    mapping.inputs["Location"].default_value = m.get("location", [0, 0, 0])
    mapping.inputs["Rotation"].default_value = [math.radians(x) for x in m.get("rotation", [0, 0, 0])]
    mapping.inputs["Scale"].default_value = m.get("scale", [1, 1, 1])
    tex = nt.nodes.new(NODE[r["texture"]])
    nt.links.new(mapping.outputs["Vector"], tex.inputs["Vector"])
    for k, name in TEX_INPUTS[r["texture"]].items():
        if k in r: tex.inputs[name].default_value = r[k]
    if r["texture"] == "wave":
        tex.wave_type = r.get("wave_type", "bands").upper()
        d = r.get("direction", "x").upper()
        if tex.wave_type == "BANDS": tex.bands_direction = d
        else: tex.rings_direction = d
        tex.wave_profile = {"sine": "SIN", "saw": "SAW", "triangle": "TRI"}[r.get("profile", "sine")]
    out = tex.outputs["Fac"] if r["texture"] != "voronoi" else tex.outputs["Distance"]
    ramp = None
    if "ramp" in r:
        ramp = nt.nodes.new("ShaderNodeValToRGB")
        cr = ramp.color_ramp
        cr.interpolation = r["ramp"]["mode"].upper()
        stops = r["ramp"]["stops"]
        while len(cr.elements) < len(stops): cr.elements.new(1.0)
        for el, (pos, col) in zip(cr.elements, stops):
            el.position = pos; el.color = [*col, 1][:4]
        nt.links.new(out, ramp.inputs["Fac"])
        out = ramp.outputs["Color"]
    return tex, ramp, out

def build_material(name, spec, emit=None):
    """The material as Blender nodes; with emit, that input's texture also
    drives an Emission shader to the output, for an EMIT bake."""
    mat = bpy.data.materials.new(name); mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    chains = {}
    for k, val in spec.items():
        if k == "normal":
            tex, ramp, out = texture_chain(nt, val["bump"])
            bump = nt.nodes.new("ShaderNodeBump")
            bump.inputs["Strength"].default_value = val.get("strength", 1)
            bump.inputs["Distance"].default_value = val.get("distance", 1)
            bump.invert = val.get("invert", False)
            nt.links.new(tex.outputs["Fac"], bump.inputs["Height"])
            nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
            chains[k] = (tex, ramp, bump)
        elif isinstance(val, dict):
            tex, ramp, out = texture_chain(nt, val)
            nt.links.new(out, bsdf.inputs[PRINCIPLED[k]])
            chains[k] = (tex, ramp, None)
            if k == emit:
                em = nt.nodes.new("ShaderNodeEmission")
                nt.links.new(out, em.inputs["Color"])
                nt.links.new(em.outputs["Emission"], nt.nodes["Material Output"].inputs["Surface"])
        elif k == "use_backface_culling":
            mat.use_backface_culling = val
        else:
            sock = bsdf.inputs[PRINCIPLED[k]]
            sock.default_value = [*val, 1][:len(sock.default_value)] if isinstance(val, list) else val
    return mat, bsdf, chains

# ---------------------------------------------------------------- one-to-one values
def close(a, b, tol=1e-6):
    a = list(a) if hasattr(a, "__len__") and not isinstance(a, str) else a
    b = list(b) if hasattr(b, "__len__") and not isinstance(b, str) else b
    if isinstance(a, list):
        return isinstance(b, list) and len(a) == len(b) and all(close(x, y, tol) for x, y in zip(a, b))
    if isinstance(a, (bool, str)) or isinstance(b, (bool, str)): return a == b
    return abs(float(a) - float(b)) <= tol * max(1.0, abs(float(b)))

def compare_recipe(where, r, tex, ramp, bad):
    if tex.bl_idname != NODE[r["texture"]]:
        bad.append(f"{where}: Blender node {tex.bl_idname}, Zender {r['texture']}"); return
    link = tex.inputs["Vector"].links[0].from_node  # Mapping
    for k, name in (("location", "Location"), ("scale", "Scale")):
        if not close(link.inputs[name].default_value, r["mapping"][k]): bad.append(f"{where}.mapping.{k}: Blender {list(link.inputs[name].default_value)}, Zender {r['mapping'][k]}")
    if not close(link.inputs["Rotation"].default_value, r["mapping"]["rotation"]): bad.append(f"{where}.mapping.rotation (rad)")
    src = link.inputs["Vector"].links[0].from_socket.name.lower()
    if src != r["coords"]: bad.append(f"{where}.coords: Blender {src}, Zender {r['coords']}")
    for k, name in TEX_INPUTS[r["texture"]].items():
        if k not in r: bad.append(f"{where}.{k}: missing in Zender"); continue
        if not close(tex.inputs[name].default_value, r[k]): bad.append(f"{where}.{k}: Blender {tex.inputs[name].default_value}, Zender {r[k]}")
    if r["texture"] == "noise" and (tex.noise_type != "FBM" or not tex.normalize or tex.noise_dimensions != "3D"):
        bad.append(f"{where}: Blender noise is not 3D normalised fBM")
    if r["texture"] == "wave":
        d = tex.bands_direction if tex.wave_type == "BANDS" else tex.rings_direction
        for k, b in (("wave_type", tex.wave_type.lower()), ("direction", d.lower()), ("profile", {"SIN": "sine", "SAW": "saw", "TRI": "triangle"}[tex.wave_profile])):
            if r.get(k) != b: bad.append(f"{where}.{k}: Blender {b}, Zender {r.get(k)}")
    if (ramp is None) != ("ramp" not in r):
        bad.append(f"{where}.ramp: present in only one"); return
    if ramp:
        cr = ramp.color_ramp
        if cr.interpolation.lower() != r["ramp"]["mode"]: bad.append(f"{where}.ramp.mode: Blender {cr.interpolation}, Zender {r['ramp']['mode']}")
        zs = r["ramp"]["stops"]
        if len(cr.elements) != len(zs): bad.append(f"{where}.ramp: {len(cr.elements)} stops in Blender, {len(zs)} in Zender")
        for i, (el, (pos, col)) in enumerate(zip(cr.elements, zs)):
            if not close(el.position, pos) or not close(el.color, col): bad.append(f"{where}.ramp.stops[{i}]: Blender {el.position} {list(el.color)}, Zender {pos} {col}")

scene_json = json.load(open(SCENE))
rows = []
for zm in scene_json["materials"]:
    name = zm["name"]; spec = B.MATERIALS.get(name)
    if spec is None:
        rows.append(dict(material=name, error="not in bust_spec.MATERIALS")); continue
    mat, bsdf, chains = build_material(name, spec)
    bad, n = [], 0
    for k, socket in PRINCIPLED.items():
        n += 1
        if k in chains: continue  # textured: compared below
        bv = bsdf.inputs[socket].default_value
        bv = list(bv)[:len(zm["properties"][k])] if hasattr(bv, "__len__") else bv
        if not close(bv, zm["properties"][k]): bad.append(f"{k}: Blender {bv}, Zender {zm['properties'][k]}")
    n += 1
    if mat.use_backface_culling != zm["properties"]["use_backface_culling"]: bad.append("use_backface_culling")
    ztex = zm.get("textures", {})
    if set(ztex) != set(chains): bad.append(f"textured inputs: Blender {sorted(chains)}, Zender {sorted(ztex)}")
    for k, (tex, ramp, bump) in chains.items():
        if k not in ztex: continue
        r = ztex[k]["bump"] if k == "normal" else ztex[k]
        compare_recipe(f"{k}", r, tex, ramp, bad)
        n += 1
        if bump:
            for f, name_ in (("strength", "Strength"), ("distance", "Distance")):
                if not close(bump.inputs[name_].default_value, ztex[k][f]): bad.append(f"normal.{f}: Blender {bump.inputs[name_].default_value}, Zender {ztex[k][f]}")
            if bump.invert != ztex[k]["invert"]: bad.append("normal.invert")
    rows.append(dict(material=name, checked=n, mismatches=bad, **{"pass": not bad}))
    log(f"{name:22s} {'PASS' if not bad else 'FAIL'}" + "".join(f"\n    {b}" for b in bad))

# ---------------------------------------------------------------- bake against Cycles
def glb_parts(path):
    data = open(path, "rb").read(); jlen = struct.unpack_from("<I", data, 12)[0]
    return json.loads(data[20:20 + jlen]), data, 20 + jlen + 8

def glb_image(j, data, bin0, name):
    """The PNG Zender exported for an image, loaded into Blender."""
    im = next(i for i in j["images"] if i.get("name") == name)
    bv = j["bufferViews"][im["bufferView"]]
    path = os.path.join(tempfile.mkdtemp(), name + ".png")
    open(path, "wb").write(data[bin0 + bv.get("byteOffset", 0):bin0 + bv.get("byteOffset", 0) + bv["byteLength"]])
    img = bpy.data.images.load(path)
    return np.array(img.pixels[:], np.float32).reshape(img.size[1], img.size[0], 4)

def glb_mesh(j, data, bin0, name):
    """Z-up positions, (u, v) with Blender's v, and triangles of a mesh node."""
    def acc(i):
        a = j["accessors"][i]; bv = j["bufferViews"][a["bufferView"]]
        dt = {5126: np.float32, 5125: np.uint32, 5123: np.uint16}[a["componentType"]]; k = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[a["type"]]
        return np.frombuffer(data, dt, a["count"] * k, bin0 + bv.get("byteOffset", 0) + a.get("byteOffset", 0)).reshape(a["count"], k)
    n = next(n for n in j["nodes"] if n.get("name") == name)
    assert "rotation" not in n and "translation" not in n, "expects an untransformed node"
    p = j["meshes"][n["mesh"]]["primitives"][0]
    v = acc(p["attributes"]["POSITION"]).astype(np.float64); uv = acc(p["attributes"]["TEXCOORD_0"]).astype(np.float64)
    return np.stack([v[:, 0], -v[:, 2], v[:, 1]], 1), np.stack([uv[:, 0], 1 - uv[:, 1]], 1), acc(p["indices"]).reshape(-1, 3).astype(np.int64)

def to_srgb8(lin):
    lin = np.clip(lin, 0, 1)
    s = np.where(lin <= 0.0031308, lin * 12.92, 1.055 * np.power(lin, 1 / 2.4) - 0.055)
    return np.round(s * 255)

def coverage(uv_tris, size):
    """Texels whose centres lie inside any UV triangle."""
    mask = np.zeros((size, size), bool)
    for t in uv_tris:
        xs, ys = t[:, 0] * size, t[:, 1] * size
        area = (xs[1] - xs[0]) * (ys[2] - ys[0]) - (xs[2] - xs[0]) * (ys[1] - ys[0])
        if abs(area) < 1e-12: continue
        x0, x1 = int(max(0, math.floor(xs.min()))), int(min(size - 1, math.ceil(xs.max())))
        y0, y1 = int(max(0, math.floor(ys.min()))), int(min(size - 1, math.ceil(ys.max())))
        gx, gy = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
        b0 = ((xs[1] - gx) * (ys[2] - gy) - (xs[2] - gx) * (ys[1] - gy)) / area
        b1 = ((xs[2] - gx) * (ys[0] - gy) - (xs[0] - gx) * (ys[2] - gy)) / area
        inside = (b0 >= 1e-4) & (b1 >= 1e-4) & (1 - b0 - b1 >= 1e-4)
        mask[y0:y1 + 1, x0:x1 + 1] |= inside
    return mask

scene = bpy.context.scene
scene.render.engine = "CYCLES"; scene.cycles.device = "CPU"; scene.cycles.samples = 1
scene.render.bake.margin = 0; scene.render.bake.use_clear = True

def bake(name, mesh_name, verts, faces, corner_uvs, loc, rot, mat_name, size, zender_image):
    me = bpy.data.meshes.new(mesh_name); me.from_pydata([tuple(map(float, p)) for p in verts], [], [tuple(map(int, f)) for f in faces]); me.update()
    uvl = me.uv_layers.new(name="UVMap"); uvl.data.foreach_set("uv", np.asarray(corner_uvs, np.float32).ravel())
    ob = bpy.data.objects.new(mesh_name, me); scene.collection.objects.link(ob)
    ob.matrix_world = Matrix.Translation(Vector(loc)) @ Euler(rot, "XYZ").to_matrix().to_4x4()
    mat, _, _ = build_material(mat_name + " (bake)", B.MATERIALS[mat_name], emit="base_color")
    me.materials.append(mat)
    img = bpy.data.images.new(name, size, size, float_buffer=True)
    node = mat.node_tree.nodes.new("ShaderNodeTexImage"); node.image = img; mat.node_tree.nodes.active = node
    for o in scene.objects: o.select_set(o is ob)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.bake(type="EMIT")
    ref = np.array(img.pixels[:], np.float32).reshape(size, size, 4)
    # Fan triangles of each face, in UV space.
    uv_tris, c = [], 0
    for f in faces:
        for k in range(1, len(f) - 1): uv_tris.append(np.array([corner_uvs[c], corner_uvs[c + k], corner_uvs[c + k + 1]]))
        c += len(f)
    mask = coverage(uv_tris, size)
    zb = np.round(zender_image[..., :3] * 255)   # Blender loads PNG rows bottom-up, as baked
    bb = to_srgb8(ref[..., :3])
    d = (zb - bb)[mask] / 255
    rmse = float(np.sqrt((d ** 2).mean()))
    row = dict(bake=name, texels=int(mask.sum()), rmse=rmse, rmse_255=rmse * 255, max_255=float(np.abs(d).max() * 255),
               off_by_more_than_2=float((np.abs(d).max(1) > 2 / 255).mean()))
    row["pass"] = rmse <= 1 / 255
    log(f"bake {name:24s} {row['texels']} texels  RMSE {row['rmse_255']:.3f}/255  max {row['max_255']:.0f}/255  >2/255: {row['off_by_more_than_2'] * 100:.2f}%  {'PASS' if row['pass'] else 'FAIL'}")
    bpy.data.objects.remove(ob)
    return row

j, data, bin0 = glb_parts(GLB)
verts, faces, uvs, mats = B.crown_mesh()
keep = [i for i, m in enumerate(mats) if m == 0]
corner = []
c = 0
for i, f in enumerate(faces):
    if mats[i] == 0: corner.extend(uvs[c:c + len(f)])
    c += len(f)
rows.append(bake("Camouflage_base_color", "Crown", verts, [faces[i] for i in keep], corner, B.CROWN_LOC, B.CROWN_ROT, "Camouflage", 512,
                 glb_image(j, data, bin0, "Camouflage_base_color")))
wv, wuv, wt = glb_mesh(j, data, bin0, "Whiskers")
rows.append(bake("Breadstick_base_color", "Whiskers", wv, wt.tolist(), wuv[wt.ravel()].tolist(), (0, 0, 0), (0, 0, 0), "Breadstick", 256,
                 glb_image(j, data, bin0, "Breadstick_base_color")))

json.dump(dict(rows=rows, passed=sum(1 for r in rows if r.get("pass")), total=len(rows)), open(REPORT, "w"), indent=1)
log(f"{sum(1 for r in rows if r.get('pass'))} of {len(rows)} checks pass; report {REPORT}")
