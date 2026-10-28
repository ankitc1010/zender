"""Writes examples/bust.jsonl: the bust of bust_spec.py as a Zender command
log, built with P1.5's tools only (mesh.from_sdf, mesh.from_data,
mesh.revolve, curve.add, material recipes and material.bake).

python3 examples/bust/gen_zender.py
zender run examples/bust.jsonl -o bust.glb
"""
import json, math, os
import bust_spec as B

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "bust.jsonl")
deg = lambda e: [round(math.degrees(x), 4) for x in e]

calls = [("scene.create", {"name": "Bust", "template": "empty", "seed": 0})]
for name, props in B.MATERIALS.items():
    calls.append(("material.create", {"name": name, "properties": props}))

# Implicit parts; the medallion once, then linked copies placed on the cuirass.
place = B.medallion_placements()
for part in B.SDF_PARTS:
    p = {"name": part["name"], "voxel_size": part["voxel"], "bounds_min": list(part["lo"]), "bounds_max": list(part["hi"]),
         "steps": part["steps"](), "material": part["material"]}
    if part["name"] == "Medallion":
        first = place[0]
        p.update(name=first["name"], location=B.r5(first["location"]), rotation=deg(first["rotation"]), scale=[first["scale"]] * 3)
    calls.append(("mesh.from_sdf", p))
for m in place:
    if m is not place[0]:
        calls.append(("object.duplicate", {"object": place[0]["name"], "name": m["name"], "linked": True}))
        calls.append(("object.transform", {"object": m["name"], "location": B.r5(m["location"]), "rotation": deg(m["rotation"]), "scale": [m["scale"]] * 3}))
    calls.append(("modifier.add", {"object": m["name"], "type": "subdivision", "properties": {"levels": 0, "render_levels": 1}}))

# Crown: camouflage band (slot 0) under tan points (slot 1), thickened and bevelled.
verts, faces, uvs, mats = B.crown_mesh()
calls.append(("mesh.from_data", {"name": "Crown", "vertices": verts, "faces": faces, "uvs": uvs, "material_index": mats, "smooth": True,
                                 "material": "Camouflage", "location": list(B.CROWN_LOC), "rotation": deg(B.CROWN_ROT)}))
calls.append(("material.assign", {"objects": ["Crown"], "material": "Crown Tan", "slot": 1}))
calls.append(("modifier.add", {"object": "Crown", "type": "solidify", "properties": {"thickness": 0.035, "offset": 1}}))
calls.append(("modifier.add", {"object": "Crown", "type": "bevel", "properties": {"width": 0.01, "segments": 2, "angle_limit": 30}}))

# Breadsticks.
calls.append(("curve.add", {"name": "Whiskers", "splines": [{"points": s} for s in B.whisker_splines()], "bevel_depth": 0.034,
                            "bevel_resolution": 4, "fill_caps": True, "material": "Breadstick"}))

# Shoulder guards: lathed shells with fluted strips, rims and rope as tube arcs.
shells, rims = B.pauldron_parts()
for sh in shells:
    count, depth, groove = sh["relief"]
    calls.append(("mesh.revolve", {"name": sh["name"], "profile": sh["profile"], "segments": sh["segments"], "angle_start": sh["angle"][0],
                                   "angle_end": sh["angle"][1], "relief_count": count, "relief_depth": depth, "relief_groove": groove,
                                   "material": "Blue Metal Engraved", "location": sh["location"], "rotation": deg(sh["rotation"])}))
    calls.append(("modifier.add", {"object": sh["name"], "type": "solidify", "properties": {"thickness": sh["thickness"], "offset": -1}}))
    calls.append(("modifier.add", {"object": sh["name"], "type": "subdivision", "properties": {"levels": 0, "render_levels": 1}}))
for rim in rims:
    calls.append(("curve.add", {"name": rim["name"], "splines": [{"points": rim["points"]}], "bevel_depth": rim["bevel"], "bevel_resolution": 4, "material": rim["material"]}))

# The studio: the video's front camera and five area lights (they render in P3).
R_CAM, Z_CAM = 12.8, -0.7
calls.append(("camera.add", {"name": "Cam Front", "location": [0, B.AXIS_Y - R_CAM, Z_CAM], "look_at": [0, B.AXIS_Y, Z_CAM], "lens": 50}))
for name, loc, energy, size, color in [("Key", (-5, -8, 5), 2600, 5, (1, 1, 1)), ("Fill", (7, -6, 0), 900, 6, (0.85, 0.9, 1.0)),
                                       ("Rim", (5, 7, 4), 2200, 4, (1, 1, 1)), ("Top", (0, 0, 9), 1200, 6, (1, 1, 1)),
                                       ("Back Left", (-6, 6, 1), 1200, 5, (0.8, 0.88, 1.0))]:
    calls.append(("light.add", {"type": "area", "name": name, "location": list(loc), "look_at": [0, 0.2, -0.6], "energy": energy,
                                "color": list(color), "properties": {"size": size}}))

# Textures glTF can carry: the camouflage and the breadstick crust, baked.
calls.append(("material.bake", {"object": "Crown", "inputs": ["base_color"], "size": 512}))
calls.append(("curve.to_mesh", {"object": "Whiskers"}))
# Each spline's tube spans the whole UV square; unwrap so the six sticks get
# their own islands before baking.
calls.append(("mesh.uv_unwrap", {"object": "Whiskers"}))
calls.append(("material.bake", {"object": "Whiskers", "inputs": ["base_color", "normal"], "size": 256}))

with open(OUT, "w") as f:
    for rev, (tool, params) in enumerate(calls):
        f.write(json.dumps({"tool": tool, "params": params, "seed": 0, "scene_rev": rev}, separators=(",", ":")) + "\n")
print(f"{len(calls)} calls -> {os.path.normpath(OUT)} ({os.path.getsize(OUT)} bytes)")
