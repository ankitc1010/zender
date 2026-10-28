// Scores an agent's result for G1 (TRD §15): reads the canonical scene.json
// the agent exported (io.export, geometry full) and evaluates a task's
// checks against world-space geometry. A task passes when every check does.

import { readFileSync, existsSync, statSync } from 'node:fs';
import { join } from 'node:path';

// ---- matrices (column-major 4x4, as Zender stores them) ----

const identity = () => [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];

function mul(a, b) {
  const o = new Array(16).fill(0);
  for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++) {
    let s = 0;
    for (let k = 0; k < 4; k++) s += a[k * 4 + r] * b[c * 4 + k];
    o[c * 4 + r] = s;
  }
  return o;
}

function axisRot(axis, a) {
  const c = Math.cos(a), s = Math.sin(a), m = identity();
  const [i, j] = axis === 0 ? [1, 2] : axis === 1 ? [2, 0] : [0, 1];
  m[i * 4 + i] = c; m[j * 4 + j] = c; m[i * 4 + j] = s; m[j * 4 + i] = -s;
  return m;
}

function quatMat([x, y, z, w]) {
  return [
    1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0,
    2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0,
    2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0,
    0, 0, 0, 1,
  ];
}

function localMatrix(p, parentInverse) {
  const t = identity();
  [t[12], t[13], t[14]] = p.location;
  let r;
  if (p.rotation_mode === 'quaternion') r = quatMat(p.rotation_quaternion);
  else {
    // Blender's Euler orders name the order axes apply: XYZ is Rz·Ry·Rx.
    r = identity();
    for (const ch of p.rotation_mode) {
      const ax = 'xyz'.indexOf(ch);
      r = mul(axisRot(ax, p.rotation_euler[ax]), r);
    }
  }
  const s = identity();
  [s[0], s[5], s[10]] = p.scale;
  return mul(parentInverse ?? identity(), mul(t, mul(r, s)));
}

const apply = (m, [x, y, z]) => [
  m[0] * x + m[4] * y + m[8] * z + m[12],
  m[1] * x + m[5] * y + m[9] * z + m[13],
  m[2] * x + m[6] * y + m[10] * z + m[14],
];

// ---- the scene, in the shapes checks need ----

export function loadScene(path) {
  const d = JSON.parse(readFileSync(path, 'utf8'));
  const byName = new Map(d.objects.map((o) => [o.name, o]));
  const worldOf = new Map();
  const world = (o, depth = 0) => {
    if (worldOf.has(o.name)) return worldOf.get(o.name);
    const local = localMatrix(o.properties, o.parent_inverse);
    const p = o.parent && byName.get(o.parent);
    const w = p && depth < 64 ? mul(world(p, depth + 1), local) : local;
    worldOf.set(o.name, w);
    return w;
  };
  const meshes = new Map(d.meshes.map((m) => [m.name, m]));
  const objects = d.objects.map((o) => {
    const w = world(o);
    const out = { name: o.name, type: o.properties.type, world: w, props: o.properties, parent: o.parent, modifiers: o.modifiers ?? [], data: o.data };
    if (o.properties.type === 'mesh' && meshes.has(o.data)) {
      const m = meshes.get(o.data);
      const pos = m.attributes.find((a) => a.name === 'position')?.data ?? [];
      const wp = pos.map((p) => apply(w, p));
      out.mesh = m;
      out.points = wp;
      out.faces = m.faces;
      out.materials = m.materials ?? [];
      out.uv = m.attributes.some((a) => a.name === 'UVMap');
      if (wp.length) {
        const lo = [Infinity, Infinity, Infinity], hi = [-Infinity, -Infinity, -Infinity];
        for (const p of wp) for (let k = 0; k < 3; k++) { lo[k] = Math.min(lo[k], p[k]); hi[k] = Math.max(hi[k], p[k]); }
        out.bounds = [lo, hi];
      }
      out.volume = () => {
        let v = 0;
        const off = m.face_offsets, cv = m.corner_verts;
        for (let f = 0; f + 1 < off.length; f++) {
          const a = wp[cv[off[f]]];
          for (let c = off[f] + 1; c + 1 < off[f + 1]; c++) {
            const b = wp[cv[c]], e = wp[cv[c + 1]];
            v += a[0] * (b[1] * e[2] - b[2] * e[1]) - a[1] * (b[0] * e[2] - b[2] * e[0]) + a[2] * (b[0] * e[1] - b[1] * e[0]);
          }
        }
        return v / 6;
      };
    } else {
      const o0 = apply(w, [0, 0, 0]);
      out.bounds = [o0, o0];
    }
    return out;
  });
  return {
    raw: d,
    objects,
    object: (name) => objects.find((o) => o.name.toLowerCase() === name.toLowerCase()),
    materials: new Map(d.materials.map((m) => [m.name, m.properties])),
    lights: new Map(d.lights.map((l) => [l.name, l.properties])),
    cameras: new Map(d.cameras.map((c) => [c.name, c.properties])),
    activeCamera: d.scene.camera,
    collections: d.collections,
  };
}

const near = (a, b, tol) => Math.abs(a - b) <= tol;
const size = (o) => o.bounds[1].map((h, k) => h - o.bounds[0][k]);
const center = (o) => o.bounds[1].map((h, k) => (h + o.bounds[0][k]) / 2);
const fmt = (v) => (Array.isArray(v) ? `[${v.map((x) => +x.toFixed(3)).join(', ')}]` : +(+v).toFixed(3));

// Each check returns null when it passes, else what was wrong.
const checks = {
  object(s, c) {
    const o = s.object(c.name);
    if (!o) return `no object named ${c.name}`;
    if (c.type && o.type !== c.type) return `${c.name} is a ${o.type}, not a ${c.type}`;
    return null;
  },
  count(s, c) {
    const n = s.objects.filter((o) => (!c.type || o.type === c.type) && (!c.prefix || o.name.toLowerCase().startsWith(c.prefix.toLowerCase())) && !o.props.hide_render).length;
    if (c.min != null && n < c.min) return `${n} matching objects, want at least ${c.min}`;
    if (c.max != null && n > c.max) return `${n} matching objects, want at most ${c.max}`;
    return null;
  },
  size(s, c) {
    const o = s.object(c.name);
    if (!o?.mesh) return `no mesh object ${c.name}`;
    const got = size(o);
    return c.size.every((x, k) => x == null || near(got[k], x, c.tol ?? 0.05)) ? null : `${c.name} is ${fmt(got)}, want ${fmt(c.size)}`;
  },
  center(s, c) {
    const o = s.object(c.name);
    if (!o) return `no object ${c.name}`;
    const got = center(o);
    return c.at.every((x, k) => x == null || near(got[k], x, c.tol ?? 0.05)) ? null : `${c.name} centre is ${fmt(got)}, want ${fmt(c.at)}`;
  },
  bound(s, c) {
    // One side of the world bounds on one axis against a value.
    const o = s.object(c.name);
    if (!o?.bounds) return `no object ${c.name}`;
    const k = 'xyz'.indexOf(c.axis);
    const got = o.bounds[c.side === 'min' ? 0 : 1][k];
    if (c.gt != null && !(got > c.gt)) return `${c.name} ${c.side} ${c.axis} is ${fmt(got)}, want > ${c.gt}`;
    if (c.lt != null && !(got < c.lt)) return `${c.name} ${c.side} ${c.axis} is ${fmt(got)}, want < ${c.lt}`;
    if (c.eq != null && !near(got, c.eq, c.tol ?? 0.05)) return `${c.name} ${c.side} ${c.axis} is ${fmt(got)}, want ${c.eq}`;
    return null;
  },
  faces(s, c) {
    const o = s.object(c.name);
    if (!o?.mesh) return `no mesh object ${c.name}`;
    if (c.min != null && o.faces < c.min) return `${c.name} has ${o.faces} faces, want at least ${c.min}`;
    if (c.max != null && o.faces > c.max) return `${c.name} has ${o.faces} faces, want at most ${c.max}`;
    return null;
  },
  volume(s, c) {
    const o = s.object(c.name);
    if (!o?.mesh) return `no mesh object ${c.name}`;
    const v = Math.abs(o.volume());
    if (c.value != null && Math.abs(v - c.value) > (c.rel ?? 0.05) * c.value) return `${c.name} volume ${fmt(v)}, want ${c.value}`;
    if (c.lt != null && !(v < c.lt)) return `${c.name} volume ${fmt(v)}, want < ${c.lt}`;
    if (c.gt != null && !(v > c.gt)) return `${c.name} volume ${fmt(v)}, want > ${c.gt}`;
    return null;
  },
  material(s, c) {
    const o = s.object(c.name);
    if (!o?.mesh) return `no mesh object ${c.name}`;
    const mats = o.materials.filter(Boolean);
    if (!mats.length) return `${c.name} has no material`;
    if (c.material && !mats.some((m) => m.toLowerCase() === c.material.toLowerCase())) return `${c.name} uses ${mats.join(', ')}, not ${c.material}`;
    const props = mats.map((m) => s.materials.get(m));
    if (c.color && !props.some((p) => p && c.color.every((x, k) => near(p.base_color[k], x, c.tol ?? 0.12)))) return `${c.name}'s colours are ${props.map((p) => fmt(p.base_color.slice(0, 3))).join(', ')}, want ${fmt(c.color)}`;
    if (c.metallic != null && !props.some((p) => p && near(p.metallic, c.metallic, 0.15))) return `${c.name} metallic is not ${c.metallic}`;
    if (c.emissive && !props.some((p) => p && p.emission_strength > 0)) return `${c.name} does not emit light`;
    return null;
  },
  modifier(s, c) {
    const o = s.object(c.name);
    if (!o) return `no object ${c.name}`;
    const m = o.modifiers.find((x) => x.type === c.type);
    if (!m) return `${c.name} has no ${c.type} modifier`;
    for (const [k, want] of Object.entries(c.props ?? {})) {
      const got = m.properties[k];
      const ok = typeof want === 'number' ? near(got, want, Math.max(1e-3, Math.abs(want) * 0.02)) : JSON.stringify(got) === JSON.stringify(want);
      if (!ok) return `${c.name} ${c.type} ${k} is ${JSON.stringify(got)}, want ${JSON.stringify(want)}`;
    }
    if (c.target && m.target?.toLowerCase() !== c.target.toLowerCase()) return `${c.name} ${c.type} reads ${m.target}, want ${c.target}`;
    return null;
  },
  no_modifiers(s, c) {
    const o = s.object(c.name);
    if (!o) return `no object ${c.name}`;
    return o.modifiers.length === 0 ? null : `${c.name} still has modifiers (${o.modifiers.map((m) => m.type).join(', ')})`;
  },
  uv(s, c) {
    const o = s.object(c.name);
    if (!o?.mesh) return `no mesh object ${c.name}`;
    return o.uv ? null : `${c.name} has no UV map`;
  },
  camera(s, c) {
    const name = s.activeCamera;
    if (!name) return 'no active camera';
    const cam = s.object(name);
    if (c.lens != null && !near(s.cameras.get(cam.data)?.lens, c.lens, 1)) return `active camera lens is ${s.cameras.get(cam.data)?.lens}, want ${c.lens}`;
    if (c.looks_at) {
      const t = s.object(c.looks_at);
      if (!t) return `no object ${c.looks_at}`;
      const w = cam.world;
      const pos = [w[12], w[13], w[14]];
      const fwd = [-w[8], -w[9], -w[10]];
      const to = center(t).map((x, k) => x - pos[k]);
      const len = (v) => Math.hypot(...v);
      const cos = (fwd[0] * to[0] + fwd[1] * to[1] + fwd[2] * to[2]) / (len(fwd) * len(to));
      if (cos < Math.cos(((c.within ?? 15) * Math.PI) / 180)) return `active camera looks ${fmt((Math.acos(Math.min(1, cos)) * 180) / Math.PI)} deg away from ${c.looks_at}`;
    }
    return null;
  },
  light(s, c) {
    const lights = s.objects.filter((o) => o.type === 'light').map((o) => s.lights.get(o.data)).filter(Boolean);
    const ok = lights.filter((l) => (!c.light_type || l.type === c.light_type) && (c.min_energy == null || l.energy >= c.min_energy) && (c.max_energy == null || l.energy <= c.max_energy));
    return ok.length >= (c.min ?? 1) ? null : `found ${ok.length} ${c.light_type ?? ''} light(s) matching, want ${c.min ?? 1}`;
  },
  collection(s, c) {
    const col = s.collections.find((x) => x.name.toLowerCase() === c.name.toLowerCase());
    if (!col) return `no collection ${c.name}`;
    const missing = (c.contains ?? []).filter((n) => !col.objects.some((o) => o.toLowerCase() === n.toLowerCase()));
    return missing.length ? `${c.name} lacks ${missing.join(', ')}` : null;
  },
  parent(s, c) {
    const o = s.object(c.child);
    if (!o) return `no object ${c.child}`;
    return o.parent?.toLowerCase() === c.parent.toLowerCase() ? null : `${c.child}'s parent is ${o.parent}, want ${c.parent}`;
  },
  hidden(s, c) {
    const o = s.object(c.name);
    if (!o) return null; // deleted counts as gone from renders too
    return o.props.hide_render ? null : `${c.name} still renders`;
  },
  absent(s, c) {
    return s.object(c.name) ? `${c.name} still exists` : null;
  },
  symmetric(s, c) {
    // Mirror symmetry of the world points across the plane through the
    // object's origin on an axis: every point has a partner.
    const o = s.object(c.name);
    if (!o?.points) return `no mesh object ${c.name}`;
    const k = 'xyz'.indexOf(c.axis ?? 'x');
    const origin = [o.world[12], o.world[13], o.world[14]][k];
    const key = (p) => p.map((x) => Math.round(x / (c.tol ?? 0.01))).join(',');
    const set = new Set(o.points.map(key));
    let miss = 0;
    for (const p of o.points) {
      const m = [...p];
      m[k] = 2 * origin - m[k];
      if (!set.has(key(m))) miss++;
    }
    return miss <= o.points.length * 0.02 ? null : `${miss} of ${o.points.length} points have no mirror partner`;
  },
  file(_s, c, dir) {
    const p = join(dir, c.path);
    if (!existsSync(p)) return `${c.path} was not written`;
    return statSync(p).size >= (c.min_bytes ?? 1) ? null : `${c.path} is too small`;
  },
};

/// Runs a task's checks on `dir/result.json`; returns the failures.
export function score(task, dir) {
  const path = join(dir, 'result.json');
  if (!existsSync(path)) return ['result.json was not exported'];
  let scene;
  try {
    scene = loadScene(path);
  } catch (e) {
    return [`result.json could not be read: ${e.message}`];
  }
  const fails = [];
  for (const c of task.checks) {
    const fn = checks[c.kind];
    if (!fn) {
      fails.push(`unknown check ${c.kind}`);
      continue;
    }
    const r = fn(scene, c, dir);
    if (r) fails.push(r);
  }
  return fails;
}
