"""Reference values for Zender's procedural texture kernels, from Blender's
own Cycles nodes: each recipe drives an emission plane seen by an
orthographic camera, rendered to float EXR with a near-zero pixel filter so
each pixel is the node's value at the pixel centre. Writes
tests/textures/blender_refs.json.

blender -b --factory-startup --python scripts/blender_texture_refs.py
"""
import bpy, json, os, sys
N = 32            # samples per side
STRIDE = 8        # rendered at N x STRIDE pixels; every STRIDE-th pixel kept, so
                  # Cycles' sub-pixel sample offset shrinks by STRIDE
Z = 0.37          # object-space z of the plane, off the noise lattice
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "src", "math", "testdata", "blender_texture_refs.json")

RECIPES = [
    {"name": "noise_default", "texture": "noise"},
    {"name": "noise_camo", "texture": "noise", "scale": 2.6, "detail": 2, "roughness": 0.55, "distortion": 0.6},
    {"name": "noise_plain", "texture": "noise", "scale": 3, "detail": 0},
    {"name": "noise_fraction", "texture": "noise", "scale": 4, "detail": 2.5, "roughness": 0.7, "lacunarity": 2.5},
    {"name": "wave_bands_x", "texture": "wave", "scale": 3},
    {"name": "wave_rings_saw", "texture": "wave", "wave_type": "rings", "direction": "spherical", "profile": "saw", "scale": 2},
    {"name": "wave_rings_distorted", "texture": "wave", "wave_type": "rings", "direction": "spherical", "scale": 3, "distortion": 6, "detail": 3},
    {"name": "wave_diag_tri", "texture": "wave", "direction": "diagonal", "profile": "tri", "scale": 1.5, "phase": 0.7},
    {"name": "voronoi_distance", "texture": "voronoi", "scale": 4},
    {"name": "voronoi_color", "texture": "voronoi", "scale": 3, "randomness": 0.6, "output": "color"},
    {"name": "ramp_constant", "texture": "noise", "scale": 2.6, "detail": 2, "roughness": 0.55, "distortion": 0.6,
     "ramp": {"mode": "constant", "stops": [[0, [0.1, 0.2, 0.05]], [0.45, [0.3, 0.2, 0.07]], [0.6, [0.55, 0.12, 0.09]]]}},
    {"name": "ramp_ease", "texture": "wave", "scale": 2, "ramp": {"mode": "ease", "stops": [[0.2, [1, 0, 0]], [0.8, [0, 0, 1]]]}},
    {"name": "mapped", "texture": "noise", "scale": 2, "mapping": {"location": [0.3, -0.2, 0.1], "rotation": [20, 0, 35], "scale": [1, 2, 0.5]}},
]

def build(recipe):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    me = bpy.data.meshes.new("Plane")
    me.from_pydata([(-1, -1, Z), (1, -1, Z), (1, 1, Z), (-1, 1, Z)], [], [(0, 1, 2, 3)])
    ob = bpy.data.objects.new("Plane", me); sc.collection.objects.link(ob)
    mat = bpy.data.materials.new("M"); mat.use_nodes = True; nt = mat.node_tree; nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial"); em = nt.nodes.new("ShaderNodeEmission")
    nt.links.new(em.outputs[0], out.inputs["Surface"])
    tc = nt.nodes.new("ShaderNodeTexCoord"); vec = tc.outputs["Object"]
    if "mapping" in recipe:
        m = nt.nodes.new("ShaderNodeMapping"); mp = recipe["mapping"]
        m.inputs["Location"].default_value = mp["location"]
        m.inputs["Rotation"].default_value = [x * 3.141592653589793 / 180 for x in mp["rotation"]]
        m.inputs["Scale"].default_value = mp["scale"]
        nt.links.new(vec, m.inputs["Vector"]); vec = m.outputs["Vector"]
    t = recipe["texture"]
    if t == "noise":
        n = nt.nodes.new("ShaderNodeTexNoise")
        for k, sock in (("scale", "Scale"), ("detail", "Detail"), ("roughness", "Roughness"), ("lacunarity", "Lacunarity"), ("distortion", "Distortion")):
            if k in recipe: n.inputs[sock].default_value = recipe[k]
        val = n.outputs["Fac"]
    elif t == "wave":
        n = nt.nodes.new("ShaderNodeTexWave")
        n.wave_type = recipe.get("wave_type", "bands").upper()
        d = recipe.get("direction", "x").upper()
        if n.wave_type == "BANDS": n.bands_direction = d
        else: n.rings_direction = d
        n.wave_profile = {"sine": "SIN", "saw": "SAW", "tri": "TRI"}[recipe.get("profile", "sine")]
        for k, sock in (("scale", "Scale"), ("distortion", "Distortion"), ("detail", "Detail"), ("detail_scale", "Detail Scale"), ("detail_roughness", "Detail Roughness"), ("phase", "Phase Offset")):
            if k in recipe: n.inputs[sock].default_value = recipe[k]
        val = n.outputs["Fac"]
    else:
        n = nt.nodes.new("ShaderNodeTexVoronoi")
        for k, sock in (("scale", "Scale"), ("randomness", "Randomness")):
            if k in recipe: n.inputs[sock].default_value = recipe[k]
        val = n.outputs["Color" if recipe.get("output") == "color" else "Distance"]
    nt.links.new(vec, n.inputs["Vector"])
    if "ramp" in recipe:
        r = nt.nodes.new("ShaderNodeValToRGB"); cr = r.color_ramp; rr = recipe["ramp"]
        cr.interpolation = rr["mode"].upper()
        st = rr["stops"]
        cr.elements[0].position, cr.elements[0].color = st[0][0], (*st[0][1], 1)
        cr.elements[1].position, cr.elements[1].color = st[1][0], (*st[1][1], 1)
        for pos, col in st[2:]:
            e = cr.elements.new(pos); e.color = (*col, 1)
        nt.links.new(val, r.inputs["Fac"]); val = r.outputs["Color"]
    nt.links.new(val, em.inputs["Color"])
    me.materials.append(mat)
    cam = bpy.data.cameras.new("C"); cam.type = "ORTHO"; cam.ortho_scale = 2
    co = bpy.data.objects.new("C", cam); sc.collection.objects.link(co); co.location = (0, 0, 5); sc.camera = co
    r = sc.render; r.engine = "CYCLES"; r.resolution_x = r.resolution_y = N * STRIDE; r.resolution_percentage = 100
    sc.cycles.samples = 1; sc.cycles.use_denoising = False; sc.cycles.filter_width = 0.01; sc.cycles.pixel_filter_type = "BOX"
    sc.view_settings.view_transform = "Standard"
    r.image_settings.file_format = "OPEN_EXR"; r.image_settings.color_depth = "32"; r.image_settings.exr_codec = "NONE"
    return sc

refs = {"size": N, "stride": STRIDE, "z": Z, "recipes": []}
ONLY = os.environ.get("ONLY")
for rec in RECIPES:
    if ONLY and rec["name"] not in ONLY.split(","): continue
    sc = build(rec)
    path = os.path.join(os.environ.get("EXR_DIR", bpy.app.tempdir), rec["name"] + ".exr")
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
    img = bpy.data.images.load(path, check_existing=False)
    img.reload()
    if img.size[0] == 0:
        img.source = "FILE"; img.filepath = path; img.reload()
    print("img", rec["name"], tuple(img.size), len(img.pixels), os.path.exists(path), flush=True)
    px = list(img.pixels)  # bottom row first, RGBA
    W = N * STRIDE
    rgb = []
    for row in range(N):
        for col in range(N):
            i = (row * STRIDE + STRIDE // 2) * W + col * STRIDE + STRIDE // 2
            rgb.append([round(px[4 * i + c], 7) for c in range(3)])
    refs["recipes"].append({"recipe": rec, "rgb": rgb})
    print("ref", rec["name"], rgb[0], flush=True)
json.dump(refs, open(OUT, "w"), separators=(",", ":"))
print("wrote", OUT)
