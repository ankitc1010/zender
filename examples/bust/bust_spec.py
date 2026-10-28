"""The blue armoured bust (replica of a turntable video), described once for
both builds of the P1.5 gate G1.5:

- gen_zender.py writes it as a Zender command log (examples/bust.jsonl);
- blender_parity.py builds the same parts with Blender's own tools (bmesh,
  curves, modifiers) and numpy for the implicit parts, reads Zender's glTF
  and compares them part by part;
- blender_materials.py builds the materials as Blender node trees and
  compares their values and Cycles' bakes with Zender's.

Implicit parts are mesh.from_sdf step programs. evaluate() below runs a
program with the semantics Zender documents: steps in order, smooth
min/max with the exact minimum when values are a blend radius apart, each
shape sampled only near itself (its bounds grown by blend and two voxels),
chains filled segment by segment, groups combined as one shape. Units are
metres; the head's centre is the origin, the face looks down -Y, Z is up.
"""
import math
import numpy as np

AXIS_Y = 0.35
F = np.float32

def V(*a):
    return np.array(a, dtype=np.float64)

def r5(x):
    return [round(float(c), 5) for c in x] if hasattr(x, "__len__") else round(float(x), 5)

# ---------------------------------------------------------------- program helpers
def E(c, r, op="add", blend=0.0, **kw):
    return dict(op=op, blend=blend, shape=dict(type="ellipsoid", location=r5(c), radii=r5(r)), **kw)
def Cp(a, b, ra, rb=None, op="add", blend=0.0, **kw):
    return dict(op=op, blend=blend, shape=dict(type="capsule", a=r5(a), b=r5(b), radii=[ra, ra if rb is None else rb]), **kw)
def S(c, r, op="add", blend=0.0):
    return dict(op=op, blend=blend, shape=dict(type="sphere", location=r5(c), radius=r))
def T(c, R, r, sx=1.0, sy=1.0, op="add", blend=0.0):
    return dict(op=op, blend=blend, shape=dict(type="torus", location=r5(c), major_radius=R, minor_radius=r, stretch=[sx, sy]))
def H(loc, n, op="add", blend=0.0):
    return dict(op=op, blend=blend, shape=dict(type="half_space", location=r5(loc), normal=r5(n)))
def G(steps, op="add", blend=0.0, offset=0.0):
    return dict(op=op, blend=blend, offset=offset, steps=steps)

# ---------------------------------------------------------------- head
def head_steps():
    st = [E((0, 0.05, 0.2), (0.68, 0.98, 1.0)), E((0, -0.45, -0.42), (0.5, 0.58, 0.7), blend=0.22), E((0, -0.6, 0.45), (0.52, 0.38, 0.36), blend=0.15)]
    for s in (-1, 1):
        st += [Cp((s * 0.47, -0.25, -0.45), (s * 0.2, -0.82, -0.9), 0.09, 0.08, blend=0.18),
               E((s * 0.38, -0.7, 0.1), (0.17, 0.15, 0.12), blend=0.14),
               E((s * 0.36, -0.86, -0.4), (0.1, 0.08, 0.13), op="subtract", blend=0.1),
               Cp((s * 0.08, -0.95, 0.5), (s * 0.42, -0.8, 0.47), 0.075, 0.05, blend=0.1)]
    st.append(E((0, -0.85, -0.86), (0.21, 0.16, 0.16), blend=0.14))
    for s in (-1, 1):
        st.append(E((s * 0.27, -0.97, 0.33), (0.16, 0.14, 0.11), op="subtract", blend=0.07))
    for s in (-1, 1):
        st += [E((s * 0.27, -0.83, 0.32), (0.12, 0.1, 0.075), blend=0.025),
               Cp((s * 0.15, -0.86, 0.365), (s * 0.39, -0.8, 0.365), 0.036, 0.03, blend=0.03),
               Cp((s * 0.18, -0.85, 0.265), (s * 0.39, -0.8, 0.275), 0.016, blend=0.025)]
    st += [Cp((0, -0.95, 0.38), (0, -1.15, -0.2), 0.045, 0.06, blend=0.06), S((0, -1.14, -0.21), 0.07, blend=0.04)]
    for s in (-1, 1):
        st += [E((s * 0.1, -1.04, -0.27), (0.075, 0.065, 0.06), blend=0.05),
               E((s * 0.055, -1.11, -0.33), (0.03, 0.04, 0.02), op="subtract", blend=0.01),
               Cp((s * 0.2, -0.97, -0.53), (s * 0.02, -1.06, -0.49), 0.035, 0.045, blend=0.04)]
    st += [Cp((-0.13, -1.0, -0.61), (0.13, -1.0, -0.61), 0.06, blend=0.04),
           Cp((-0.21, -1.045, -0.555), (0.21, -1.045, -0.555), 0.012, op="subtract", blend=0.012),
           E((0, -1.0, -0.72), (0.1, 0.05, 0.04), op="subtract", blend=0.03),
           Cp((0, -1.11, -0.37), (0, -1.08, -0.47), 0.015, op="subtract", blend=0.02)]
    for s in (-1, 1):
        st.append(E((s * 0.67, 0.08, 0.05), (0.07, 0.15, 0.23), blend=0.05))
    st.append(Cp((0, 0.0, -0.55), (0, 0.05, -2.0), 0.64, 0.76, blend=0.25))
    for s in (-1, 1):
        st.append(Cp((s * 0.4, 0.05, -0.7), (s * 0.1, -0.45, -1.75), 0.13, 0.1, blend=0.12))
    return st

# ---------------------------------------------------------------- hair: 40 in-phase S-wave locks
HC, HR = V(0, 0.2, 0.27), V(1.08, 1.14, 1.05)
PHI1 = math.radians(120)
FACE_C, FACE_R = (0, -1.05, -0.35), (0.64, 0.85, 0.95)
def taper(dt): return 1 - 0.36 * min(1.0, max(0.0, dt))
def hair_bottom(y): return -0.85 - 0.22 * (y + 0.7)
def in_face(p): return sum(((p[k] - FACE_C[k]) / FACE_R[k]) ** 2 for k in range(3)) < 1.0
def norm(v): return v / np.linalg.norm(v)
def hair_point(theta, t):
    if t <= PHI1:
        u = V(math.sin(t) * math.cos(theta), math.sin(t) * math.sin(theta), math.cos(t))
        return HC + HR * u, norm(u / HR)
    s1 = math.sin(PHI1) * taper(t - PHI1)
    p = HC + V(HR[0] * s1 * math.cos(theta), HR[1] * s1 * math.sin(theta), HR[2] * math.cos(PHI1) - (t - PHI1) * HR[2])
    return p, norm(V(math.cos(theta) / HR[0], math.sin(theta) / HR[1], 0))

def lock_paths():
    rng = np.random.default_rng(11)
    paths = []
    n = 40
    for i in range(n):
        theta0 = 2 * math.pi * (i + 0.5) / n
        ta = (0.3 if i % 4 == 0 else 0.62 if i % 4 == 2 else 0.95) + rng.uniform(-0.04, 0.04)
        ph = 1.0 * math.sin(2 * theta0) + 0.6 * math.sin(5 * theta0 + 1.0) + rng.normal(0, 0.2)
        lam, amp, r0 = 0.6, 0.1, rng.uniform(0.088, 0.102)
        pts, rads = [], []
        t = ta
        while t < 4.0:
            rho = max(0.3, HR[0] * math.sin(min(t, PHI1)))
            env = min(1.0, (t - ta) / 0.25)
            th = theta0 + env * amp * math.sin(2 * math.pi * t / lam + ph) / rho
            p, nrm = hair_point(th, t)
            if len(pts) > 2 and (in_face(p) or p[2] < hair_bottom(p[1])): break
            crest = env * math.sin(2 * math.pi * t / lam + ph) ** 2
            r = r0 * (1 - 0.18 * min(1.0, (t - ta) / 2.5)) * (0.86 + 0.14 * crest)
            pts.append(p + nrm * (r * 0.55 * crest)); rads.append(r)
            t += 0.035
        if len(pts) < 4: continue
        Tg = norm(pts[-1] - pts[-2]); _, N = hair_point(theta0, t)
        Sd = norm(np.cross(Tg, N)) * (1 if math.cos(2 * math.pi * t / lam + ph) > 0 else -1)
        rho0, re, pe = rads[-1] * 1.5, rads[-1], pts[-1]
        for k in range(1, 8):
            al = 1.3 * math.pi * k / 7
            pts.append(pe + Tg * (rho0 * math.sin(al)) + Sd * (rho0 * (1 - math.cos(al))))
            rads.append(re * (1 - 0.45 * k / 7))
        paths.append((pts, rads))
    return paths

def hair_steps():
    st = [E(HC, HR * 0.94), E((0, 0.25, -0.55), (0.82, 0.88, 0.75), blend=0.1)]
    for pts, rads in lock_paths():
        st.append(dict(op="add", blend=0.03, shape=dict(type="chain", points=[r5(p) for p in pts], radii=[r5(r) for r in rads])))
    st.append(H((0, 0, -1.004), norm(V(0, 0.22, 1)), op="subtract", blend=0.06))
    st.append(E(FACE_C, FACE_R, op="subtract", blend=0.04))
    return st

# ---------------------------------------------------------------- cuirass and straps
def torso_steps():
    st = [E((0, AXIS_Y, -3.05), (1.5, 1.12, 1.6))]
    for s in (-1, 1):
        st += [E((s * 0.55, -0.55, -2.5), (0.62, 0.38, 0.42), blend=0.2),
               E((s * 1.55, AXIS_Y, -2.5), (0.6, 0.7, 0.8), blend=0.2),
               Cp((s * 0.45, 0.32, -1.8), (s * 1.45, AXIS_Y, -2.12), 0.3, 0.32, blend=0.25)]
    st += [Cp((0, 0.05, -1.6), (0, 0.15, -2.4), 0.62, blend=0.15),
           E((0, -0.02, -2.05), (0.95, 0.72, 0.5), blend=0.2),
           T((0, 0.06, -1.8), 0.74, 0.045, 1.0, 0.95, blend=0.02),
           H((0, 0, -3.95), (0, 0, -1), op="intersect")]
    return st

def strap_band(half):
    """The over-shoulder strap's footprint: |x| follows the shoulder from front
    to back (x = 0.84 + 0.2u^2 + 0.1u, u = (y - 0.3) / 0.85), as tall boxes
    along that curve, mirrored."""
    ys = np.linspace(-1.15, 1.85, 31)
    xs = 0.84 + 0.2 * ((ys - 0.3) / 0.85) ** 2 + 0.1 * (ys - 0.3) / 0.85
    st = []
    for i in range(len(ys) - 1):
        dx, dy = xs[i + 1] - xs[i], ys[i + 1] - ys[i]
        L = math.hypot(dx, dy)
        phi = math.degrees(math.atan2(-dx, dy))
        st.append(dict(op="add", shape=dict(type="box", size=r5([2 * half, L + 0.02, 3.0]), location=r5([(xs[i] + xs[i + 1]) / 2, (ys[i] + ys[i + 1]) / 2, -2.65]), rotation=[0, 0, r5(phi)], mirror_x=True)))
    return st

def cuirass_steps():
    region = [H((0, AXIS_Y, 0), (0, -1, 0)), H((0, 0, -2.2), (0, 0, -1))]   # the back, and the front above the medallions
    strap = G([G(torso_steps(), offset=0.085), G(strap_band(0.13), op="intersect"), G(region, op="intersect")], blend=0.01)
    return torso_steps() + [strap]

def leather_steps():
    return [G(torso_steps(), offset=0.045), G(strap_band(0.21), op="intersect")]

# ---------------------------------------------------------------- medallions
def medallion_steps():
    face = [E((0, 0, 0.02), (0.15, 0.17, 0.075))]
    for k in range(12):
        a = 2 * math.pi * k / 12
        face.append(S((0.2 * math.cos(a), 0.2 * math.sin(a), 0.03), 0.05, blend=0.03))
    face.append(Cp((0, 0.07, 0.07), (0, -0.04, 0.1), 0.022, 0.03, blend=0.02))
    for s in (-1, 1):
        face.append(E((s * 0.055, 0.05, 0.09), (0.03, 0.018, 0.03), op="subtract", blend=0.01))
    face.append(Cp((-0.05, -0.08, 0.08), (0.05, -0.08, 0.08), 0.012, op="subtract", blend=0.01))
    return [dict(op="add", shape=dict(type="cylinder", radius=0.3, depth=0.05)), T((0, 0, 0.025), 0.3, 0.035), G(face, blend=0.02)]

MEDALLIONS = [("Medallion Chest L", -0.95, -2.12, True, 0.95), ("Medallion Chest R", 0.95, -2.12, True, 0.95),
              ("Medallion Centre", 0.0, -2.95, True, 1.15), ("Medallion Back L", -1.15, -2.35, False, 1.0),
              ("Medallion Back R", 1.15, -2.35, False, 1.0)]

def euler_from_matrix(m):
    """Blender's XYZ Euler of a rotation matrix (columns are the local axes)."""
    sy = math.hypot(m[0][0], m[1][0])
    if sy > 1e-6:
        return (math.atan2(m[2][1], m[2][2]), math.atan2(-m[2][0], sy), math.atan2(m[1][0], m[0][0]))
    return (math.atan2(-m[1][2], m[1][1]), math.atan2(-m[2][0], sy), 0.0)

def rotation_z_to(n):
    """Shortest rotation taking +Z to unit n, as a matrix."""
    z = V(0, 0, 1); n = norm(n)
    c = float(np.dot(z, n)); ax = np.cross(z, n); s = np.linalg.norm(ax)
    if s < 1e-9: return np.eye(3) if c > 0 else np.diag([1, -1, -1])
    ax /= s; ang = math.atan2(s, c)
    K = np.array([[0, -ax[2], ax[1]], [ax[2], 0, -ax[0]], [-ax[1], ax[0], 0]])
    return np.eye(3) + math.sin(ang) * K + (1 - math.cos(ang)) * K @ K

def medallion_placements():
    """Where each medallion sits: on the cuirass surface (a ray from the torso
    axis along -Y or +Y), facing along the surface normal."""
    steps = cuirass_steps()
    out = []
    for name, x, z, front, size in MEDALLIONS:
        ys = np.linspace(AXIS_Y, AXIS_Y + (-1.6 if front else 1.6), 400)
        pts = np.stack([np.full_like(ys, x), ys, np.full_like(ys, z)], 1)
        f = point_eval(steps, pts)
        i = int(np.argmax(f > 0)); p = pts[i]
        e = 0.01
        g = V(*[point_eval(steps, (p + e * np.eye(3)[k])[None])[0] - point_eval(steps, (p - e * np.eye(3)[k])[None])[0] for k in range(3)])
        n = norm(g)
        R = rotation_z_to(n)
        out.append(dict(name=name, location=p - n * 0.01, rotation=euler_from_matrix(R), scale=size))
    return out

# ---------------------------------------------------------------- crown: a band of camouflage under tan points
CROWN_LOC = (0, 0.14, 1.12)
CROWN_ROT = (math.radians(-12), math.radians(-4), 0.0)   # Ry(-4) after Rx(-12), as Blender XYZ Euler
PEAKS = [-45, 45, 117, -117, 180]
def tooth(a_deg):
    best = 0.0
    for p in PEAKS:
        dd = abs((a_deg - p + 180) % 360 - 180)
        best = max(best, 1 - dd / 27)
    return 0.44 * best

def crown_mesh():
    seg = 180; rows_z = [-0.17, -0.1, -0.03, 0.04, 0.1]
    verts = []
    cols = []
    for i in range(seg):
        a = 2 * math.pi * i / seg
        a_front = math.degrees(a) + 90
        top = 0.14 + tooth(((a_front + 180) % 360) - 180)
        zs = rows_z + [0.14, 0.14 + (top - 0.14) * 0.5, top]
        col = []
        for z in zs:
            flare = 1 + 0.08 * (z + 0.17)
            col.append(len(verts)); verts.append((0.76 * flare * math.cos(a), 0.93 * flare * math.sin(a), z))
        cols.append(col)
    faces, uvs, mats = [], [], []
    for i in range(seg):
        a, b = cols[i], cols[(i + 1) % seg]
        for r in range(len(a) - 1):
            f = [a[r], b[r], b[r + 1], a[r + 1]]
            faces.append(f); mats.append(0 if r < 4 else 1)
            for (ii, vi) in zip([i, i + 1, i + 1, i], f):
                uvs.append((ii / seg, (verts[vi][2] + 0.17) / 0.75))
    return [r5(v) for v in verts], faces, [r5(u) for u in uvs], mats

# ---------------------------------------------------------------- breadsticks
def whisker_splines():
    out = []
    for s in (-1, 1):
        for a, b in [((0.18, -1.09, -0.3), (1.42, -1.38, -0.14)), ((0.2, -1.08, -0.42), (1.45, -1.38, -0.55)),
                     ((0.22, -1.05, -0.56), (1.35, -1.3, -0.88))]:
            A, B = V(s * a[0], a[1], a[2]), V(s * b[0], b[1], b[2])
            out.append([r5(A - norm(B - A) * 0.06), r5(B)])
    return out

# ---------------------------------------------------------------- shoulder guards
def pauldron_frame(s):
    O = V(s * 1.55, AXIS_Y, -1.8); d = norm(V(s * 0.38, 0, -0.925)); e1 = norm(V(s * 0.925, 0, 0.38))
    e2 = norm(np.cross(d, e1))
    return O, e1, e2, d

def pauldron_parts():
    """Shells (lathe profiles with fluted strips) and rims (arcs of tube), per
    side. Strips are counted per full turn so both builds place them alike."""
    R_cap = lambda t: 0.002 + 0.87 * math.sqrt(max(0.0, 1 - ((0.12 - t) / 0.42) ** 2))
    R1 = lambda t: 0.86 + 0.08 * (t - 0.08)
    R2 = lambda t: 0.9 + 0.05 * (t - 0.45) - 0.05 * (t - 0.45) ** 2
    arm = (-128.0, 128.0)
    shells, rims = [], []
    for s in (-1, 1):
        side = "LR"[s > 0]
        O, e1, e2, d = pauldron_frame(s)
        rot = euler_from_matrix(np.stack([e1, e2, d], 1))
        def prof(R, t0, t1, n): return [[r5(t0 + (t1 - t0) * k / n), r5(R(t0 + (t1 - t0) * k / n))] for k in range(n + 1)]
        common = dict(location=r5(O), rotation=rot)
        shells.append(dict(name=f"Pauldron Cap {side}", profile=prof(R_cap, -0.3, 0.12, 20), segments=96, angle=(-180.0, 180.0), relief=(0, 0, 0), thickness=0.04, **common))
        shells.append(dict(name=f"Pauldron Scales {side}", profile=prof(R1, 0.08, 0.5, 14), segments=240, angle=arm, relief=(42, 0.022, 0.006), thickness=0.03, **common))
        shells.append(dict(name=f"Pauldron Strips {side}", profile=prof(R2, 0.45, 1.5, 24), segments=264, angle=arm, relief=(31, 0.035, 0.012), thickness=0.03, **common))
        for name, t, r, bevel, mat in [(f"Pauldron Rim {side}", 0.12, 0.87, 0.04, "Blue Metal Engraved"), (f"Pauldron Rope {side}", 0.5, R1(0.5) + 0.02, 0.032, "Rope Metal")]:
            pts = []
            for j in range(73):
                b = math.radians(arm[0] + (arm[1] - arm[0]) * j / 72)
                pts.append(r5(O + d * t + (e1 * math.cos(b) + e2 * math.sin(b)) * r))
            rims.append(dict(name=name, points=pts, bevel=bevel, material=mat))
    return shells, rims

def relief_at(count, depth, groove, u):
    """Zender's fluted relief at u, the fraction of a full turn."""
    if count == 0: return 0.0
    x = u * count; t = x - math.floor(x)
    e = abs(2 * t - 1)
    return depth * (1 - e ** 6) - groove * math.exp(-((t - 0.5) / 0.06) ** 2)

# ---------------------------------------------------------------- materials (material.create properties)
BLUE = [0.025, 0.07, 0.34]
MATERIALS = {
    "Blue Metal": dict(base_color=BLUE, metallic=1, roughness=0.17, coat_weight=0.6, coat_roughness=0.04, coat_tint=[0.75, 0.85, 1]),
    "Blue Metal Engraved": dict(base_color=BLUE, metallic=1, roughness=0.2, coat_weight=0.6, coat_roughness=0.04,
                                normal=dict(bump=dict(texture="wave", wave_type="rings", direction="x", scale=3, distortion=6, detail=3), strength=0.5, distance=0.01)),
    "Rope Metal": dict(base_color=BLUE, metallic=1, roughness=0.22,
                       normal=dict(bump=dict(texture="wave", direction="diagonal", scale=28), strength=0.8, distance=1)),
    "Camouflage": dict(roughness=0.85, base_color=dict(texture="noise", scale=2.6, detail=2, roughness=0.55, distortion=0.6,
                       ramp=dict(mode="constant", stops=[[0.0, [0.012, 0.018, 0.007]], [0.36, [0.025, 0.045, 0.01]], [0.45, [0.1, 0.06, 0.02]],
                                                         [0.52, [0.018, 0.03, 0.008]], [0.58, [0.05, 0.016, 0.007]], [0.64, [0.19, 0.035, 0.026]], [0.69, [0.035, 0.05, 0.012]]]))),
    "Crown Tan": dict(base_color=[0.13, 0.055, 0.016], roughness=0.6),
    "Breadstick": dict(roughness=0.45, base_color=dict(texture="noise", scale=60, ramp=dict(mode="linear", stops=[[0.35, [0.2, 0.05, 0.01]], [0.65, [0.42, 0.15, 0.03]]])),
                       normal=dict(bump=dict(texture="noise", scale=60), strength=0.25, distance=1)),
    "Maroon Leather": dict(base_color=[0.075, 0.004, 0.012], roughness=0.35),
}

# ---------------------------------------------------------------- the implicit parts
SDF_PARTS = [
    dict(name="Head", steps=head_steps, voxel=0.0125, lo=(-0.85, -1.35, -2.05), hi=(0.85, 1.1, 1.25), material="Blue Metal"),
    dict(name="Hair", steps=hair_steps, voxel=0.012, lo=(-1.25, -1.15, -1.45), hi=(1.25, 1.55, 1.45), material="Blue Metal"),
    dict(name="Cuirass", steps=cuirass_steps, voxel=0.022, lo=(-2.4, -1.1, -4.0), hi=(2.4, 1.8, -1.3), material="Blue Metal Engraved"),
    dict(name="Leather Straps", steps=leather_steps, voxel=0.018, lo=(-1.5, -1.1, -4.0), hi=(1.5, 1.8, -1.3), material="Maroon Leather"),
    dict(name="Medallion", steps=medallion_steps, voxel=0.006, lo=(-0.36, -0.36, -0.05), hi=(0.36, 0.36, 0.16), material="Blue Metal"),
]

# ---------------------------------------------------------------- numpy evaluation, as mesh.from_sdf
BIG = F(1e6)

def smin(a, b, k):
    if k <= 0: return np.minimum(a, b)
    h = F(0.5) + F(0.5) * (b - a) / F(k)
    blend = b + (a - b) * h - F(k) * h * (F(1) - h)
    return np.where(np.abs(a - b) >= F(k), np.minimum(a, b), blend)

def smax(a, b, k):
    return -smin(-a, -b, k)

def rot_matrix(rx, ry, rz):
    cx, sx, cy, sy, cz, sz = math.cos(rx), math.sin(rx), math.cos(ry), math.sin(ry), math.cos(rz), math.sin(rz)
    Rx = np.array([[1, 0, 0], [0, cx, -sx], [0, sx, cx]]); Ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]]); Rz = np.array([[cz, -sz, 0], [sz, cz, 0], [0, 0, 1]])
    return Rz @ Ry @ Rx

def shape_of(sh):
    """(distance function of points (N, 3) in world space, local bounds or None)."""
    loc = np.array(sh.get("location", [0, 0, 0]), np.float64)
    rot = [math.radians(x) for x in sh.get("rotation", [0, 0, 0])]
    sc = float(sh.get("scale", 1))
    M = rot_matrix(*rot)
    t = sh["type"]
    if t == "sphere":
        r = sh["radius"]; lb = (V(-r, -r, -r), V(r, r, r))
        f = lambda q: np.linalg.norm(q, axis=1) - F(r)
    elif t == "ellipsoid":
        rr = np.array(sh["radii"], F); lb = (-rr.astype(float), rr.astype(float))
        def f(q):
            qq = q / rr; k0 = np.sqrt((qq * qq).sum(1)); q2 = qq / rr; k1 = np.sqrt((q2 * q2).sum(1))
            return np.where(k1 > 0, k0 * (k0 - F(1)) / np.where(k1 > 0, k1, F(1)), -F(rr.min()))
    elif t == "box":
        half = np.array(sh["size"], F) / F(2); rnd = F(min(sh.get("round", 0), float(half.min()))); lb = (-half.astype(float), half.astype(float))
        def f(q):
            d = np.abs(q) - half + rnd
            return np.sqrt((np.maximum(d, 0) ** 2).sum(1)) + np.minimum(d.max(1), 0) - rnd
    elif t == "capsule":
        a, b = np.array(sh["a"], F), np.array(sh["b"], F); ra, rb = (sh["radii"] if "radii" in sh else [sh["radius"]] * 2)
        r = max(ra, rb); lb = (np.minimum(a, b) - r, np.maximum(a, b) + r)
        f = lambda q: capsule(q, a, b, F(ra), F(rb))
    elif t == "torus":
        R, r = sh["major_radius"], sh["minor_radius"]; sx, sy = sh.get("stretch", [1, 1])
        lb = (V(-(R + r) * sx, -(R + r) * sy, -r), V((R + r) * sx, (R + r) * sy, r))
        def f(q):
            qx = np.sqrt((q[:, 0] / F(sx)) ** 2 + (q[:, 1] / F(sy)) ** 2) - F(R)
            return np.sqrt(qx * qx + q[:, 2] ** 2) - F(r)
    elif t == "cylinder":
        r, h = sh["radius"], sh["depth"] / 2; lb = (V(-r, -r, -h), V(r, r, h))
        def f(q):
            d0 = np.sqrt(q[:, 0] ** 2 + q[:, 1] ** 2) - F(r); d1 = np.abs(q[:, 2]) - F(h)
            return np.minimum(np.maximum(d0, d1), 0) + np.sqrt(np.maximum(d0, 0) ** 2 + np.maximum(d1, 0) ** 2)
    elif t == "half_space":
        n = norm(np.array(sh["normal"], float)).astype(F); lb = None
        f = lambda q: q @ n
    else:
        raise ValueError(t)
    Mi = M.T.astype(F); locf = loc.astype(F)
    def world(p):
        q = ((p - locf) @ Mi.T) / F(sc)
        return f(q) * F(sc)
    def dist(p):
        d = world(p)
        if sh.get("mirror_x"):
            pm = p.copy(); pm[:, 0] = -pm[:, 0]; d = np.minimum(d, world(pm))
        return d
    if lb is None: return dist, None
    corners = np.array([[lb[(c >> k) & 1][k] for k in range(3)] for c in range(8)])
    wc = loc + (corners * sc) @ M.T
    lo, hi = wc.min(0), wc.max(0)
    if sh.get("mirror_x"): lo[0], hi[0] = min(lo[0], -hi[0]), max(hi[0], -lo[0])
    return dist, (lo, hi)

def capsule(q, a, b, ra, rb):
    pa = q - a; ba = b - a; bb = F(np.dot(ba, ba))
    h = np.clip((pa @ ba) / bb, 0, 1) if bb > 0 else np.zeros(len(q), F)
    return np.sqrt(((pa - ba[None] * h[:, None]) ** 2).sum(1)) - (ra + (rb - ra) * h)

def added_bounds(steps):
    lo = hi = None
    for st in steps:
        if st.get("op", "add") != "add": continue
        if "shape" in st:
            if st["shape"]["type"] == "chain":
                P = np.array(st["shape"]["points"]); r = max(st["shape"]["radii"]); b = (P.min(0) - r, P.max(0) + r)
            else:
                b = shape_of(st["shape"])[1]
                if b is None: return False, None
            g = max(st.get("offset", 0), 0)
            b = (b[0] - g, b[1] + g)
        else:
            ok, b = added_bounds(st["steps"])
            if not ok: return False, None
            if b is None: continue
        k = st.get("blend", 0)
        b = (np.asarray(b[0]) - k, np.asarray(b[1]) + k)
        lo = b[0] if lo is None else np.minimum(lo, b[0]); hi = b[1] if hi is None else np.maximum(hi, b[1])
    return True, (None if lo is None else (lo, hi))

class Grid:
    def __init__(self, lo, hi, voxel):
        self.o = np.array(lo, F); self.v = F(voxel)
        self.n = [int(np.ceil((F(hi[a]) - F(lo[a])) / F(voxel))) + 1 for a in range(3)]
        self.axes = [self.o[a] + self.v * np.arange(self.n[a], dtype=F) for a in range(3)]
    def rng(self, b):
        r = []
        for a in range(3):
            l = np.floor((F(b[0][a]) - self.o[a]) / self.v); h = np.ceil((F(b[1][a]) - self.o[a]) / self.v) + 1
            r.append((int(np.clip(l, 0, self.n[a])), int(np.clip(h, 0, self.n[a]))))
        return r
    def points(self, r):
        X, Y, Z = np.meshgrid(self.axes[0][r[0][0]:r[0][1]], self.axes[1][r[1][0]:r[1][1]], self.axes[2][r[2][0]:r[2][1]], indexing="ij")
        return np.stack([X.ravel(), Y.ravel(), Z.ravel()], 1)

def combine(d, s, op, k):
    if op == "add": return smin(d, s, k)
    if op == "subtract": return smax(d, -s, k)
    return smax(d, s, k)

def run(steps, g, field):
    margin = 2 * float(g.v)
    full = [(0, g.n[0]), (0, g.n[1]), (0, g.n[2])]
    for st in steps:
        op, k, off = st.get("op", "add"), st.get("blend", 0.0), st.get("offset", 0.0)
        if "shape" in st and st["shape"]["type"] == "chain" and op != "intersect":
            sh = st["shape"]; P = np.array(sh["points"], F); R = np.array(sh["radii"], F) - F(off)
            b = (P.min(0).astype(float) - float(np.max(sh["radii"])) - max(off, 0), P.max(0).astype(float) + float(np.max(sh["radii"])) + max(off, 0))
            r = g.rng((b[0] - k - margin, b[1] + k + margin))
            if any(x1 <= x0 for x0, x1 in r): continue
            tmp = np.full([x1 - x0 for x0, x1 in r], BIG, F)
            for i in range(len(P) - 1):
                gg = max(R[i], R[i + 1]) + k + margin
                sb = g.rng((np.minimum(P[i], P[i + 1]) - gg, np.maximum(P[i], P[i + 1]) + gg))
                sb = [(max(a0, r0), min(a1, r1)) for (a0, a1), (r0, r1) in zip(sb, r)]
                if any(x1 <= x0 for x0, x1 in sb): continue
                pts = g.points(sb)
                sub = tuple(slice(a0 - r0, a1 - r0) for (a0, a1), (r0, _) in zip(sb, r))
                tmp[sub] = np.minimum(tmp[sub], capsule(pts, P[i], P[i + 1], R[i], R[i + 1]).reshape(tmp[sub].shape))
            sl = tuple(slice(a, b) for a, b in r)
            field[sl] = combine(field[sl], tmp, op, k)
        elif "shape" in st:
            dist, b = shape_of(st["shape"])
            if op == "intersect" or b is None: r = full
            else:
                gg = max(off, 0) + k + margin
                r = g.rng((b[0] - gg, b[1] + gg))
            if any(x1 <= x0 for x0, x1 in r): continue
            sl = tuple(slice(a, b) for a, b in r)
            s = (dist(g.points(r)) - F(off)).reshape(field[sl].shape)
            field[sl] = combine(field[sl], s, op, k)
        else:
            tmp = np.full(field.shape, BIG, F)
            run(st["steps"], g, tmp)
            ok, b = added_bounds(st["steps"])
            if op == "intersect" or not ok or b is None: r = full
            else:
                gg = k + max(off, 0) + margin
                r = g.rng((b[0] - gg, b[1] + gg))
            sl = tuple(slice(a, b) for a, b in r)
            field[sl] = combine(field[sl], tmp[sl] - F(off), op, k)

def evaluate(steps, lo, hi, voxel):
    """The sampled field of a program, as mesh.from_sdf samples it."""
    g = Grid(lo, hi, voxel)
    field = np.full(g.n, BIG, F)
    run(steps, g, field)
    return g, field

def point_eval(steps, pts):
    """Exact field values at points (no regions): for placing things."""
    pts = np.asarray(pts, F)
    d = np.full(len(pts), BIG, F)
    for st in steps:
        op, k, off = st.get("op", "add"), st.get("blend", 0.0), st.get("offset", 0.0)
        if "shape" in st:
            sh = st["shape"]
            if sh["type"] == "chain":
                P = np.array(sh["points"], F); R = np.array(sh["radii"], F)
                s = np.min([capsule(pts, P[i], P[i + 1], R[i], R[i + 1]) for i in range(len(P) - 1)], 0)
            else:
                s = shape_of(sh)[0](pts)
        else:
            s = point_eval(st["steps"], pts)
        d = combine(d, s - F(off), op, k)
    return d
