// The agent-evaluation task sets: G1 (TRD §15), 100 tasks across the tool
// surface, and P1.5's 15 (G1.5: blended shapes, tubes, rope rims, textures).
// Each is a request in plain words, machine checks on the scene the agent
// exports, and a reference solution (a command log) that proves the checks
// can pass. Names in prompts are fixed so checks can find objects; sizes
// and placements vary between variants.

const op = (tool, params) => ({ tool, params });
const prim = (kind, name, extra = {}) => op('object.add_primitive', { kind, name, ...extra });
const mat = (name, color, extra = {}) => op('material.create', { name, properties: { base_color: [...color, 1], ...extra } });

const templates = [
  // ---- primitives and placement ----
  {
    category: 'primitives',
    variants: [[2, 1, 0.5, [0, 0, 0.25]], [1, 1, 3, [2, -1, 1.5]], [4, 0.2, 2, [-1, 3, 1]]],
    make: ([x, y, z, at]) => ({
      prompt: `Make a box named Block that is ${x} m long (X), ${y} m deep (Y) and ${z} m tall (Z), centred at [${at}].`,
      checks: [{ kind: 'size', name: 'Block', size: [x, y, z] }, { kind: 'center', name: 'Block', at }],
      solution: [prim('cube', 'Block', { size: 1, scale: [x, y, z], location: at })],
    }),
  },
  {
    category: 'primitives',
    variants: [[0.5, 2], [1, 0.3], [0.2, 4]],
    make: ([r, h]) => ({
      prompt: `Add a cylinder named Pillar with radius ${r} m and height ${h} m standing on the ground (its base at z = 0).`,
      checks: [{ kind: 'size', name: 'Pillar', size: [2 * r, 2 * r, h], tol: 0.06 }, { kind: 'bound', name: 'Pillar', axis: 'z', side: 'min', eq: 0 }],
      solution: [prim('cylinder', 'Pillar', { radius: r, depth: h, location: [0, 0, h / 2] })],
    }),
  },
  {
    category: 'primitives',
    variants: [['uv_sphere', 1.5], ['ico_sphere', 0.7], ['uv_sphere', 0.25]],
    make: ([kind, r]) => ({
      prompt: `Create a ball named Ball of radius ${r} m resting on the ground at the origin (touching z = 0 from above).`,
      checks: [{ kind: 'size', name: 'Ball', size: [2 * r, 2 * r, 2 * r], tol: 0.08 * r + 0.02 }, { kind: 'bound', name: 'Ball', axis: 'z', side: 'min', eq: 0, tol: 0.03 }],
      solution: [prim(kind, 'Ball', { radius: r, location: [0, 0, r] })],
    }),
  },
  {
    category: 'primitives',
    variants: [[45], [90], [30]],
    make: ([deg]) => ({
      prompt: `Add a 2 m wide flat plane named Ramp, then tilt it ${deg} degrees about the X axis so it is no longer horizontal.`,
      checks: [{ kind: 'object', name: 'Ramp', type: 'mesh' }, { kind: 'size', name: 'Ramp', size: [2, 2 * Math.cos((deg * Math.PI) / 180), 2 * Math.sin((deg * Math.PI) / 180)], tol: 0.08 }],
      solution: [prim('plane', 'Ramp', { rotation: [deg, 0, 0] })],
    }),
  },
  // ---- arrangement ----
  {
    category: 'arrangement',
    variants: [[5, 1.5], [3, 2], [7, 1]],
    make: ([n, gap]) => ({
      prompt: `Make a row of ${n} cubes of 0.5 m along the X axis, ${gap} m apart (centre to centre), all named starting with "Crate".`,
      checks: [{ kind: 'count', type: 'mesh', prefix: 'Crate', min: n, max: n }],
      solution: Array.from({ length: n }, (_, i) => prim('cube', `Crate ${i + 1}`, { size: 0.5, location: [i * gap, 0, 0.25] })),
    }),
  },
  {
    category: 'arrangement',
    variants: [[6, 3], [8, 2], [4, 1.5]],
    make: ([n, radius]) => ({
      prompt: `Place ${n} thin cylinders (radius 0.1 m, height 2 m) evenly in a circle of radius ${radius} m around the origin, standing on the ground, named starting with "Post".`,
      checks: [{ kind: 'count', type: 'mesh', prefix: 'Post', min: n, max: n }],
      solution: Array.from({ length: n }, (_, i) => prim('cylinder', `Post ${i + 1}`, { radius: 0.1, depth: 2, location: [radius * Math.cos((2 * Math.PI * i) / n), radius * Math.sin((2 * Math.PI * i) / n), 1] })),
    }),
  },
  {
    category: 'arrangement',
    variants: [['Lamp', 'Desk'], ['Wheel', 'Cart'], ['Hat', 'Head']],
    make: ([child, parent]) => ({
      prompt: `Add a cube named ${parent} and a small sphere named ${child} sitting on top of it, and make ${child} a child of ${parent}.`,
      checks: [{ kind: 'parent', child, parent }],
      solution: [prim('cube', parent), prim('uv_sphere', child, { radius: 0.3, location: [0, 0, 1.3] }), op('object.set_parent', { object: child, parent })],
    }),
  },
  {
    category: 'arrangement',
    variants: [['Furniture', ['Table', 'Chair']], ['Rocks', ['Rock A', 'Rock B', 'Rock C']], ['Walls', ['North Wall', 'South Wall']]],
    make: ([coll, names]) => ({
      prompt: `Create cubes named ${names.join(', ')} (spread apart so they do not overlap) and put them all in a collection called ${coll}.`,
      checks: [{ kind: 'collection', name: coll, contains: names }],
      solution: [...names.map((n, i) => prim('cube', n, { location: [i * 3, 0, 1] })), op('collection.create', { name: coll, objects: names })],
    }),
  },
  // ---- materials ----
  {
    category: 'materials',
    variants: [['red', [0.8, 0.05, 0.05]], ['blue', [0.05, 0.1, 0.8]], ['green', [0.05, 0.6, 0.1]]],
    make: ([word, color]) => ({
      prompt: `Add a sphere named Orb and give it a plain ${word} material (scene-linear colour roughly [${color}]).`,
      checks: [{ kind: 'material', name: 'Orb', color, tol: 0.25 }],
      solution: [mat('Paint', color), prim('uv_sphere', 'Orb', { material: 'Paint' })],
    }),
  },
  {
    category: 'materials',
    variants: [['gold', [1, 0.77, 0.34]], ['steel', [0.56, 0.57, 0.58]], ['copper', [0.95, 0.64, 0.54]]],
    make: ([word, color]) => ({
      prompt: `Make a torus named Ring with a shiny ${word} metal material (fully metallic, low roughness).`,
      checks: [{ kind: 'material', name: 'Ring', metallic: 1 }],
      solution: [mat('Metal', color, { metallic: 1, roughness: 0.2 }), prim('torus', 'Ring', { material: 'Metal' })],
    }),
  },
  {
    category: 'materials',
    variants: [['warm', [1, 0.8, 0.4]], ['cool blue', [0.4, 0.8, 1]]],
    make: ([word, color]) => ({
      prompt: `Add a small sphere named Bulb that glows with a ${word} light (an emissive material) like a light bulb.`,
      checks: [{ kind: 'material', name: 'Bulb', emissive: true }],
      solution: [mat('Glow', color, { emission_color: color, emission_strength: 5 }), prim('uv_sphere', 'Bulb', { radius: 0.2, material: 'Glow' })],
    }),
  },
  {
    category: 'materials',
    variants: [[['Left', 'Right']], [['Top', 'Middle', 'Bottom']]],
    make: ([names]) => ({
      prompt: `Make cubes named ${names.join(', ')} (not overlapping) that all share one wooden-brown material named Wood.`,
      checks: names.map((n) => ({ kind: 'material', name: n, material: 'Wood' })),
      solution: [mat('Wood', [0.3, 0.15, 0.06]), ...names.map((n, i) => prim('cube', n, { location: [i * 3, 0, 1], material: 'Wood' }))],
    }),
  },
  // ---- cameras and lights ----
  {
    category: 'camera_light',
    variants: [[[6, -6, 4]], [[0, -8, 2]], [[-5, 5, 6]]],
    make: ([loc]) => ({
      prompt: `Add a cube named Subject at the origin and a camera at [${loc}] that looks straight at it; make it the active camera.`,
      checks: [{ kind: 'camera', looks_at: 'Subject', within: 8 }],
      solution: [prim('cube', 'Subject'), op('camera.add', { location: loc, look_at: [0, 0, 0] })],
    }),
  },
  {
    category: 'camera_light',
    variants: [[85], [24], [35]],
    make: ([lens]) => ({
      prompt: `Add a camera with a ${lens} mm lens, make it the active camera, and aim it at a sphere named Target placed at the origin.`,
      checks: [{ kind: 'camera', lens, looks_at: 'Target', within: 10 }],
      solution: [prim('uv_sphere', 'Target'), op('camera.add', { location: [4, -4, 3], look_at: [0, 0, 0], lens })],
    }),
  },
  {
    category: 'camera_light',
    variants: [['sun', 4], ['point', 800], ['area', 300]],
    make: ([type, energy]) => ({
      prompt: `Light the scene with a single ${type} light of strength ${energy} ${type === 'sun' ? 'W/m²' : 'W'}.`,
      checks: [{ kind: 'light', light_type: type, min_energy: energy * 0.9, max_energy: energy * 1.1 }],
      solution: [op('light.add', { type, energy, location: [2, -2, 4], look_at: [0, 0, 0] })],
    }),
  },
  {
    category: 'camera_light',
    variants: [[]],
    make: () => ({
      prompt: 'Set up classic three-point lighting (a key, a fill and a back light, three lights in all) around a sphere named Model at the origin, and add a camera looking at it.',
      checks: [{ kind: 'light', min: 3 }, { kind: 'camera', looks_at: 'Model', within: 12 }],
      solution: [prim('uv_sphere', 'Model'), op('light.add', { type: 'area', name: 'Key', location: [3, -3, 3], look_at: [0, 0, 0], energy: 400 }), op('light.add', { type: 'area', name: 'Fill', location: [-3, -2, 2], look_at: [0, 0, 0], energy: 150 }), op('light.add', { type: 'point', name: 'Back', location: [0, 3, 3], energy: 300 }), op('camera.add', { location: [0, -6, 1.5], look_at: [0, 0, 0] })],
    }),
  },
  // ---- mesh editing ----
  {
    category: 'mesh_edit',
    variants: [[0.5], [1.5], [0.25]],
    make: ([d]) => ({
      prompt: `Add a 2 m cube named Tower at the origin and extrude its top face upward by ${d} m (edit the mesh, do not scale the object).`,
      checks: [{ kind: 'bound', name: 'Tower', axis: 'z', side: 'max', eq: 1 + d }, { kind: 'faces', name: 'Tower', min: 10 }],
      solution: [prim('cube', 'Tower'), op('mesh.extrude', { object: 'Tower', selector: { normal: [0, 0, 1] }, distance: d })],
    }),
  },
  {
    category: 'mesh_edit',
    variants: [[0.1, 0.5], [0.2, 0.8]],
    make: ([wall, depth]) => ({
      prompt: `Make an open-topped planter named Planter from a 2 m cube: inset its top face by ${wall} m and push the inset face ${depth} m down into the box.`,
      // An inset with depth makes the cavity in one step (10 faces, sloped
      // walls); inset then extrude makes it in two (14 faces). Both count.
      checks: [{ kind: 'faces', name: 'Planter', min: 10 }, { kind: 'size', name: 'Planter', size: [2, 2, 2], tol: 0.02 }, { kind: 'volume', name: 'Planter', lt: 8 - (2 - 2 * wall) ** 2 * depth * 0.5 }],
      solution: [prim('cube', 'Planter'), op('mesh.inset', { object: 'Planter', selector: { normal: [0, 0, 1] }, thickness: wall }), op('mesh.extrude', { object: 'Planter', selector: { normal: [0, 0, 1], where: ['abs(x) < 0.95', 'abs(y) < 0.95'] }, distance: -depth })],
    }),
  },
  {
    category: 'mesh_edit',
    variants: [[1], [3]],
    make: ([cuts]) => ({
      prompt: `Add a cube named Column and add ${cuts} horizontal edge loop${cuts > 1 ? 's' : ''} around it (loop cuts across the vertical edges).`,
      checks: [{ kind: 'faces', name: 'Column', min: 6 + 4 * cuts, max: 6 + 4 * cuts }],
      solution: [prim('cube', 'Column'), op('mesh.loop_cut', { object: 'Column', selector: { domain: 'edge', direction: [0, 0, 1], within: 5 }, cuts })],
    }),
  },
  {
    category: 'mesh_edit',
    variants: [[0.2, 4], [0.1, 1]],
    make: ([w, seg]) => ({
      prompt: `Make a 2 m cube named Soap and bevel all its edges by ${w} m with ${seg} segment${seg > 1 ? 's' : ''} so it has ${seg > 1 ? 'rounded' : 'chamfered'} edges.`,
      checks: [{ kind: 'faces', name: 'Soap', min: seg > 1 ? 50 : 26 }, { kind: 'size', name: 'Soap', size: [2, 2, 2], tol: 0.02 }, { kind: 'volume', name: 'Soap', lt: 7.99 }],
      solution: [prim('cube', 'Soap'), op('mesh.bevel', { object: 'Soap', selector: {}, width: w, segments: seg })],
    }),
  },
  {
    category: 'mesh_edit',
    variants: [[1.5]],
    make: ([h]) => ({
      prompt: `Turn a 2 m cube named Spire into a pyramid of height ${h + 1} m above its base by extruding the top face up ${h} m and merging the top vertices into one point.`,
      checks: [{ kind: 'bound', name: 'Spire', axis: 'z', side: 'max', eq: 1 + h }, { kind: 'volume', name: 'Spire', lt: 8 + 4 * h * 0.5 }],
      solution: [prim('cube', 'Spire'), op('mesh.extrude', { object: 'Spire', selector: { normal: [0, 0, 1] }, distance: h }), op('mesh.merge', { object: 'Spire', selector: { domain: 'vert', where: `z > ${h + 0.9}` } })],
    }),
  },
  {
    category: 'mesh_edit',
    variants: [[0.5], [0.3]],
    make: ([s]) => ({
      prompt: `Add a 2 m cube named Wedge and shrink only its top face to ${s * 100}% of its size (scale the top vertices about their centre), making a tapered block.`,
      checks: [{ kind: 'faces', name: 'Wedge', min: 6, max: 6 }, { kind: 'volume', name: 'Wedge', lt: 7.5, gt: 2 }],
      solution: [prim('cube', 'Wedge'), op('mesh.transform_elements', { object: 'Wedge', selector: { domain: 'vert', where: 'z > 0.5' }, scale: [s, s, 1] })],
    }),
  },
  {
    category: 'mesh_edit',
    variants: [[0.6]],
    make: ([h]) => ({
      prompt: `Make a flat grid named Hill (20 subdivisions) and raise a smooth round hill ${h} m high in its middle using soft selection (falloff), not a single spike.`,
      checks: [{ kind: 'bound', name: 'Hill', axis: 'z', side: 'max', eq: h, tol: 0.1 }, { kind: 'count', type: 'mesh', min: 1 }],
      solution: [prim('grid', 'Hill', { grid_subdivisions: 20 }), op('mesh.transform_elements', { object: 'Hill', selector: { domain: 'vert', sphere: { center: [0, 0, 0], radius: 0.06 } }, translate: [0, 0, h], falloff: 0.7 })],
    }),
  },
  {
    category: 'mesh_edit',
    variants: [[]],
    make: () => ({
      prompt: 'Add a cylinder named Prism and triangulate all its faces.',
      checks: [{ kind: 'faces', name: 'Prism', min: 120, max: 128 }],
      solution: [prim('cylinder', 'Prism'), op('mesh.triangulate', { object: 'Prism' })],
    }),
  },
  // ---- booleans ----
  {
    category: 'boolean',
    variants: [[1, 1.2], [0.8, 0.8], [1.5, 1]],
    make: ([w, h]) => ({
      prompt: `Make a wall named Wall 4 m long (X), 0.3 m thick (Y) and 2.5 m high standing on the ground, and cut a ${w} m wide, ${h} m high window right through it, centred 1.4 m above the ground. Nothing else should remain visible.`,
      checks: [{ kind: 'volume', name: 'Wall', value: 4 * 0.3 * 2.5 - w * h * 0.3, rel: 0.03 }, { kind: 'count', type: 'mesh', max: 1 }],
      solution: [prim('cube', 'Wall', { size: 1, scale: [4, 0.3, 2.5], location: [0, 0, 1.25] }), prim('cube', 'Cut', { size: 1, scale: [w, 1, h], location: [0, 0, 1.4] }), op('mesh.boolean', { object: 'Wall', operand: 'Cut', operand_action: 'delete' })],
    }),
  },
  {
    category: 'boolean',
    variants: [[0.4], [0.6]],
    make: ([r]) => ({
      prompt: `Make a pipe named Pipe: a cylinder of radius 1 m and height 2 m with a ${r} m radius hole through its length.`,
      checks: [{ kind: 'volume', name: 'Pipe', value: Math.PI * (1 - r * r) * 2, rel: 0.06 }],
      solution: [prim('cylinder', 'Pipe', { radius: 1, depth: 2 }), prim('cylinder', 'Bore', { radius: r, depth: 3 }), op('mesh.boolean', { object: 'Pipe', operand: 'Bore', operand_action: 'delete' })],
    }),
  },
  {
    category: 'boolean',
    variants: [[1.3], [1.45]],
    make: ([r]) => ({
      prompt: `Make a rounded die body named Die: the intersection of a 2 m cube and a sphere of radius ${r} m, both at the origin.`,
      checks: [{ kind: 'size', name: 'Die', size: [2, 2, 2], tol: 0.03 }, { kind: 'volume', name: 'Die', lt: 7.95, gt: 6 }],
      solution: [prim('cube', 'Die'), prim('uv_sphere', 'Round', { radius: r, segments: 48, rings: 24 }), op('mesh.boolean', { object: 'Die', operand: 'Round', operation: 'intersect', operand_action: 'delete' })],
    }),
  },
  {
    category: 'boolean',
    variants: [[]],
    make: () => ({
      prompt: 'Join a 2 m cube named Base and a sphere of radius 1 m centred on its top face into one single object named Base (a union), removing the sphere object.',
      checks: [{ kind: 'count', type: 'mesh', max: 1 }, { kind: 'bound', name: 'Base', axis: 'z', side: 'max', eq: 2, tol: 0.05 }],
      solution: [prim('cube', 'Base'), prim('uv_sphere', 'Dome', { location: [0, 0, 1] }), op('mesh.boolean', { object: 'Base', operand: 'Dome', operation: 'union', operand_action: 'delete' })],
    }),
  },
  // ---- modifiers ----
  {
    category: 'modifier',
    variants: [[2], [3], [1]],
    make: ([lv]) => ({
      prompt: `Add a cube named Pebble and give it a subdivision surface modifier with ${lv} level${lv > 1 ? 's' : ''} for renders (keep it as a modifier, do not apply it).`,
      checks: [{ kind: 'modifier', name: 'Pebble', type: 'subdivision', props: { render_levels: lv } }, { kind: 'faces', name: 'Pebble', max: 6 }],
      solution: [prim('cube', 'Pebble'), op('modifier.add', { object: 'Pebble', type: 'subdivision', properties: { render_levels: lv } })],
    }),
  },
  {
    category: 'modifier',
    variants: [[5, 2.5], [10, 1.2]],
    make: ([n, step]) => ({
      prompt: `Add a cube named Step and an array modifier that repeats it ${n} times, ${step} m apart along X.`,
      checks: [{ kind: 'modifier', name: 'Step', type: 'array', props: { count: n } }],
      solution: [prim('cube', 'Step'), op('modifier.add', { object: 'Step', type: 'array', properties: { count: n, relative_offset: [0, 0, 0], constant_offset: [step, 0, 0] } })],
    }),
  },
  {
    category: 'modifier',
    variants: [['x'], ['y']],
    make: ([axis]) => ({
      prompt: `Add a cube named Half moved 1.5 m along +${axis.toUpperCase()}, and a mirror modifier on it that mirrors across the ${axis.toUpperCase()} axis.`,
      checks: [{ kind: 'modifier', name: 'Half', type: 'mirror', props: { [`axis_${axis}`]: true } }],
      solution: [prim('cube', 'Half', { location: axis === 'x' ? [1.5, 0, 0] : [0, 1.5, 0] }), op('modifier.add', { object: 'Half', type: 'mirror', properties: { axis_x: axis === 'x', axis_y: axis === 'y' } })],
    }),
  },
  {
    category: 'modifier',
    variants: [[0.05], [0.2]],
    make: ([t]) => ({
      prompt: `Add a plane named Panel and give it thickness ${t} m with a solidify modifier.`,
      checks: [{ kind: 'modifier', name: 'Panel', type: 'solidify', props: { thickness: t } }],
      solution: [prim('plane', 'Panel'), op('modifier.add', { object: 'Panel', type: 'solidify', properties: { thickness: t } })],
    }),
  },
  {
    category: 'modifier',
    variants: [[0.3]],
    make: ([ratio]) => ({
      prompt: `Add a detailed sphere named Lowpoly (64 segments, 32 rings) and reduce it to about ${ratio * 100}% of its triangles with a decimate modifier, then apply the modifier.`,
      checks: [{ kind: 'faces', name: 'Lowpoly', max: Math.ceil(64 * 32 * 2 * ratio * 1.1) }, { kind: 'no_modifiers', name: 'Lowpoly' }],
      solution: [prim('uv_sphere', 'Lowpoly', { segments: 64, rings: 32 }), op('modifier.add', { object: 'Lowpoly', type: 'decimate', properties: { ratio } }), op('modifier.apply', { object: 'Lowpoly' })],
    }),
  },
  {
    category: 'modifier',
    variants: [[]],
    make: () => ({
      prompt: 'Make a lumpy rock named Rock: an ico sphere with a displace modifier using noise, then apply all its modifiers.',
      checks: [{ kind: 'no_modifiers', name: 'Rock' }, { kind: 'object', name: 'Rock', type: 'mesh' }],
      solution: [prim('ico_sphere', 'Rock', { subdivisions: 4 }), op('modifier.add', { object: 'Rock', type: 'displace', properties: { texture: 'noise', strength: 0.3, noise_scale: 0.5 } }), op('modifier.apply', { object: 'Rock' })],
    }),
  },
  {
    category: 'modifier',
    variants: [[]],
    make: () => ({
      prompt: 'Add a cube named Keeper and a cylinder named Drill crossing it, then add a boolean modifier on Keeper that subtracts Drill (keep Drill as an object).',
      checks: [{ kind: 'modifier', name: 'Keeper', type: 'boolean', target: 'Drill' }, { kind: 'object', name: 'Drill' }],
      solution: [prim('cube', 'Keeper'), prim('cylinder', 'Drill', { radius: 0.4, depth: 3 }), op('modifier.add', { object: 'Keeper', type: 'boolean', target: 'Drill' })],
    }),
  },
  // ---- UVs and files ----
  {
    category: 'uv_io',
    variants: [['smart'], ['conformal']],
    make: ([method]) => ({
      prompt: `Add a torus named Donut and UV-unwrap it (${method} method).`,
      checks: [{ kind: 'uv', name: 'Donut' }],
      solution: [prim('torus', 'Donut'), op('mesh.uv_unwrap', { object: 'Donut', method })],
    }),
  },
  {
    category: 'uv_io',
    variants: [['glb'], ['obj'], ['stl'], ['ply']],
    make: ([ext]) => ({
      prompt: `Add a cone named Cone and export the scene to cone.${ext}.`,
      checks: [{ kind: 'object', name: 'Cone' }, { kind: 'file', path: `cone.${ext}`, min_bytes: 100 }],
      solution: [prim('cone', 'Cone'), op('io.export', { path: `cone.${ext}` })],
    }),
  },
  {
    category: 'uv_io',
    variants: [[1], [0.01]],
    make: ([scale]) => ({
      prompt: `Import the file tetra.obj${scale !== 1 ? ` (its units are centimetres; bring it in at the right size in metres)` : ''} and move the imported object so it sits at x = 3.`,
      files: { 'tetra.obj': 'o Tetra\nv 0 0 0\nv 100 0 0\nv 0 100 0\nv 0 0 100\nf 1 3 2\nf 1 2 4\nf 1 4 3\nf 2 3 4\n'.replace(/100/g, scale === 1 ? '1' : '100') },
      checks: [{ kind: 'object', name: 'Tetra' }, { kind: 'size', name: 'Tetra', size: [1, 1, 1], tol: 0.05 }, { kind: 'bound', name: 'Tetra', axis: 'x', side: 'min', eq: 3, tol: 0.6 }],
      solution: [op('io.import', { path: 'tetra.obj', scale, location: [3, 0, 0] })],
    }),
  },
  // ---- organic: soft edits and sculpting ----
  {
    category: 'organic',
    variants: [[0.3], [0.15]],
    make: ([h]) => ({
      prompt: `Add a sphere named Blob (48 segments, 24 rings) and sculpt a smooth bump about ${h} m high on its top (+Z side).`,
      checks: [{ kind: 'bound', name: 'Blob', axis: 'z', side: 'max', gt: 1 + h * 0.4 }, { kind: 'bound', name: 'Blob', axis: 'z', side: 'min', eq: -1, tol: 0.05 }],
      solution: [prim('uv_sphere', 'Blob', { segments: 48, rings: 24 }), op('mesh.sculpt', { object: 'Blob', brush: 'grab', stroke: [[0, 0, 1], [0, 0, 1 + h]], radius: 0.4, strength: 1 })],
    }),
  },
  {
    category: 'organic',
    variants: [[]],
    make: () => ({
      prompt: 'Add a sphere named Mask (48 segments, 24 rings) and sculpt two symmetric dents for eye sockets on its front (-Y side), using mirror symmetry across X.',
      checks: [{ kind: 'symmetric', name: 'Mask', axis: 'x', tol: 0.01 }, { kind: 'volume', name: 'Mask', lt: 4.156 }],
      solution: [prim('uv_sphere', 'Mask', { segments: 48, rings: 24 }), op('mesh.sculpt', { object: 'Mask', stroke: [[0.35, -0.9, 0.3]], radius: 0.25, strength: 1, subtract: true, symmetry: 'x' })],
    }),
  },
  {
    category: 'organic',
    variants: [[]],
    make: () => ({
      prompt: 'Add a cube named Lump and a sphere joined onto one of its faces (one object named Lump), then smooth the joint so it blends in.',
      checks: [{ kind: 'count', type: 'mesh', max: 1 }, { kind: 'faces', name: 'Lump', min: 20 }],
      solution: [prim('cube', 'Lump'), prim('uv_sphere', 'Bit', { radius: 0.7, location: [0, 0, 1] }), op('mesh.boolean', { object: 'Lump', operand: 'Bit', operation: 'union', operand_action: 'delete' }), op('mesh.smooth', { object: 'Lump', selector: { domain: 'vert', sphere: { center: [0, 0, 1], radius: 0.9 } }, iterations: 5 })],
    }),
  },
  {
    category: 'organic',
    variants: [[1], [0.6]],
    make: ([r]) => ({
      prompt: `Add a sphere named Boulder of radius ${r} m (48 segments, 24 rings) at the origin and flatten its underside so it could sit flat on the ground, keeping the top round.`,
      checks: [{ kind: 'bound', name: 'Boulder', axis: 'z', side: 'min', gt: -r * 0.97 }, { kind: 'bound', name: 'Boulder', axis: 'z', side: 'max', eq: r, tol: 0.03 * r }],
      solution: [prim('uv_sphere', 'Boulder', { radius: r, segments: 48, rings: 24 }), op('mesh.sculpt', { object: 'Boulder', brush: 'flatten', stroke: [[0, 0, -r]], radius: r * 0.7, strength: 1 })],
    }),
  },
  {
    category: 'organic',
    variants: [[0.3], [0.5]],
    make: ([d]) => ({
      prompt: `Add a sphere named Face (radius 1 m, 48 segments, 24 rings) and pull a smooth, rounded nose about ${d} m out of its front (-Y side) without tearing the surface.`,
      checks: [{ kind: 'bound', name: 'Face', axis: 'y', side: 'min', lt: -1 - d * 0.5 }, { kind: 'bound', name: 'Face', axis: 'y', side: 'max', eq: 1, tol: 0.03 }],
      solution: [prim('uv_sphere', 'Face', { segments: 48, rings: 24 }), op('mesh.transform_elements', { object: 'Face', selector: { domain: 'vert', sphere: { center: [0, -1, 0], radius: 0.08 } }, translate: [0, -d, 0], falloff: 0.4 })],
    }),
  },
  // ---- small scenes ----
  {
    category: 'scene',
    variants: [[1.6, 0.9, 0.75], [1.2, 1.2, 0.72]],
    make: ([w, d, h]) => ({
      prompt: `Build a table: a top named Top ${w} x ${d} m and 0.05 m thick whose upper surface is ${h} m above the ground, and four legs named starting with "Leg" reaching the ground under its corners.`,
      checks: [{ kind: 'bound', name: 'Top', axis: 'z', side: 'max', eq: h, tol: 0.03 }, { kind: 'size', name: 'Top', size: [w, d, 0.05], tol: 0.05 }, { kind: 'count', type: 'mesh', prefix: 'Leg', min: 4, max: 4 }],
      solution: [prim('cube', 'Top', { size: 1, scale: [w, d, 0.05], location: [0, 0, h - 0.025] }), ...[[1, 1], [1, -1], [-1, 1], [-1, -1]].map(([sx, sy], i) => prim('cube', `Leg ${i + 1}`, { size: 1, scale: [0.06, 0.06, h - 0.05], location: [sx * (w / 2 - 0.08), sy * (d / 2 - 0.08), (h - 0.05) / 2] }))],
    }),
  },
  {
    category: 'scene',
    variants: [[3]],
    make: ([n]) => ({
      prompt: `Build a snowman named starting with "Snow": ${n} spheres stacked on the ground, each smaller than the one below, plus a carrot nose (an orange cone named Nose) on the top sphere.`,
      checks: [{ kind: 'count', type: 'mesh', prefix: 'Snow', min: n }, { kind: 'object', name: 'Nose' }, { kind: 'material', name: 'Nose', color: [0.9, 0.35, 0.05], tol: 0.35 }],
      solution: [prim('uv_sphere', 'Snow 1', { radius: 0.6, location: [0, 0, 0.6] }), prim('uv_sphere', 'Snow 2', { radius: 0.45, location: [0, 0, 1.6] }), prim('uv_sphere', 'Snow 3', { radius: 0.3, location: [0, 0, 2.3] }), mat('Carrot', [0.9, 0.35, 0.05]), prim('cone', 'Nose', { radius: 0.06, depth: 0.3, rotation: [90, 0, 0], location: [0, -0.4, 2.3], material: 'Carrot' })],
    }),
  },
  {
    category: 'scene',
    variants: [[4, 3, 2.5]],
    make: ([w, d, h]) => ({
      prompt: `Model a house named House: a ${w} x ${d} m body ${h} m tall on the ground with a pitched roof built by editing the same mesh (the ridge higher than ${h + 0.5} m), and a door recess on the front (-Y) face.`,
      checks: [{ kind: 'bound', name: 'House', axis: 'z', side: 'max', gt: h + 0.5 }, { kind: 'bound', name: 'House', axis: 'z', side: 'min', eq: 0, tol: 0.05 }, { kind: 'faces', name: 'House', min: 10 }],
      solution: [prim('cube', 'House', { size: 1, scale: [w, d, h], location: [0, 0, h / 2] }), op('mesh.extrude', { object: 'House', selector: { normal: [0, 0, 1] }, distance: 1.2 }), op('mesh.merge', { object: 'House', selector: { domain: 'vert', where: [`z > ${h + 1}`, 'x < 0'] } }), op('mesh.merge', { object: 'House', selector: { domain: 'vert', where: [`z > ${h + 1}`, 'x > 0'] } }), op('mesh.inset', { object: 'House', selector: { normal: [0, -1, 0], within: 5, where: `z < ${h}` }, thickness: 0.6, depth: -0.1 })],
    }),
  },
  {
    category: 'scene',
    variants: [[6]],
    make: ([n]) => ({
      prompt: `Build a staircase of ${n} steps named starting with "Step", each 1 m wide, 0.3 m deep and 0.2 m higher than the last, the first resting on the ground.`,
      checks: [{ kind: 'count', type: 'mesh', prefix: 'Step', min: n, max: n }],
      solution: Array.from({ length: n }, (_, i) => prim('cube', `Step ${i + 1}`, { size: 1, scale: [1, 0.3, 0.2 * (i + 1)], location: [0, 0.3 * i, 0.1 * (i + 1)] })),
    }),
  },
  {
    category: 'scene',
    variants: [[]],
    make: () => ({
      prompt: 'Model a mug named Mug: a cylinder about 0.08 m in radius and 0.1 m tall, hollowed out from the top (inset the top and push it down), with a torus handle named Handle on its side. Give the mug a material.',
      checks: [{ kind: 'object', name: 'Handle' }, { kind: 'faces', name: 'Mug', min: 40 }, { kind: 'material', name: 'Mug' }],
      solution: [mat('Glaze', [0.8, 0.8, 0.75]), prim('cylinder', 'Mug', { radius: 0.08, depth: 0.1, location: [0, 0, 0.05], material: 'Glaze' }), op('mesh.inset', { object: 'Mug', selector: { normal: [0, 0, 1] }, thickness: 0.008 }), op('mesh.extrude', { object: 'Mug', selector: { normal: [0, 0, 1], where: 'area > 0.01' }, distance: -0.09 }), prim('torus', 'Handle', { major_radius: 0.03, minor_radius: 0.008, rotation: [90, 0, 0], location: [0.09, 0, 0.05] })],
    }),
  },
  {
    category: 'scene',
    variants: [[]],
    make: () => ({
      prompt: 'Build a simple car named starting with "Car": a body (a box with bevelled, rounded edges) and four wheels (cylinders turned on their side) named starting with "Wheel", with a red paint material on the body.',
      checks: [{ kind: 'count', type: 'mesh', prefix: 'Wheel', min: 4 }, { kind: 'count', type: 'mesh', prefix: 'Car', min: 1 }],
      solution: [mat('Paint', [0.8, 0.05, 0.05]), prim('cube', 'Car Body', { size: 1, scale: [3.6, 1.6, 0.6], location: [0, 0, 0.7], material: 'Paint' }), op('mesh.bevel', { object: 'Car Body', selector: {}, width: 0.15, segments: 3 }), ...[[-1.1, 0.85], [1.1, 0.85], [-1.1, -0.85], [1.1, -0.85]].map(([x, y], i) => prim('cylinder', `Wheel ${i + 1}`, { radius: 0.38, depth: 0.25, rotation: [90, 0, 0], location: [x, y, 0.38] }))],
    }),
  },
];

// ---- P1.5: one task per variant ----
const ring = (r, z, a0, a1, n) => Array.from({ length: n + 1 }, (_, j) => {
  const a = ((a0 + ((a1 - a0) * j) / n) * Math.PI) / 180;
  return [+(r * Math.cos(a)).toFixed(5), +(r * Math.sin(a)).toFixed(5), z];
});

const p15Templates = [
  {
    category: 'blend',
    variants: [[0.5, 0.7, 0.2], [0.3, 0.4, 0.16], [0.8, 1, 0.3]],
    make: ([r, d, k]) => {
      // Waist half-height at x = 0: a plain union's, and with the blend's
      // k / 4 bulge; the rays want at least halfway between.
      const hu = Math.sqrt(r * r - (d / 2) ** 2), hb = Math.sqrt((r + k / 4) ** 2 - (d / 2) ** 2), mid = (hu + hb) / 2;
      return {
        prompt: `Model a peanut named Peanut: two spheres of radius ${r} m whose centres are ${d} m apart along X, centred on the origin in X and Y and resting on the ground, joined by a smooth blend of about ${k} m so the waist between them is filled in instead of creased.`,
        checks: [
          { kind: 'size', name: 'Peanut', size: [d + 2 * r, 2 * r, 2 * r], tol: 0.02 + 0.04 * r },
          { kind: 'bound', name: 'Peanut', axis: 'z', side: 'min', eq: 0, tol: 0.03 },
          { kind: 'ray', name: 'Peanut', from: [0, 0, 10], dir: [0, 0, -1], axis: 'z', gt: r + mid },
          { kind: 'ray', name: 'Peanut', from: [0, 0, -10], dir: [0, 0, 1], axis: 'z', lt: r - mid },
        ],
        solution: [op('mesh.from_sdf', { name: 'Peanut', voxel_size: r / 25, steps: [{ shape: { type: 'sphere', radius: r, location: [-d / 2, 0, r] } }, { blend: k, shape: { type: 'sphere', radius: r, location: [d / 2, 0, r] } }] })],
      };
    },
  },
  {
    category: 'blend',
    variants: [[0.4, 0.25, 0.12, 0.03, 0.02], [0.6, 0.35, 0.15, 0.04, 0.03]],
    make: ([x, y, z, r, dent]) => {
      const rho = 4 * dent + y / 4;
      return {
        prompt: `Model a bar of soap named Soap: a box ${x} m long (X), ${y} m deep (Y) and ${z} m tall (Z) with every edge rounded to a radius of about ${r} m, lying on the ground centred at the origin, with a smooth dent about ${dent} m deep pressed into the middle of its top.`,
        checks: [
          { kind: 'size', name: 'Soap', size: [x, y, z], tol: 0.015 },
          { kind: 'bound', name: 'Soap', axis: 'z', side: 'min', eq: 0, tol: 0.01 },
          { kind: 'ray', name: 'Soap', from: [0, 0, 10], dir: [0, 0, -1], axis: 'z', lt: z - dent / 2, gt: z - 2 * dent },
          // A tenth of the radius in from an edge, a round edge has fallen 0.56 r.
          { kind: 'ray', name: 'Soap', from: [x / 2 - r / 10, 0, 10], dir: [0, 0, -1], axis: 'z', lt: z - r / 4 },
          { kind: 'ray', name: 'Soap', from: [x / 2 - r / 10, 10, z / 2], dir: [0, -1, 0], axis: 'y', lt: y / 2 - r / 4 },
        ],
        solution: [op('mesh.from_sdf', { name: 'Soap', voxel_size: r / 6, steps: [{ shape: { type: 'box', size: [x, y, z], round: r, location: [0, 0, z / 2] } }, { op: 'subtract', blend: dent / 2, shape: { type: 'sphere', radius: rho, location: [0, 0, z + rho - dent] } }] })],
      };
    },
  },
  {
    category: 'tube',
    variants: [[0.1, [[0, 0, 0.1], [2, 0, 0.1], [2, 0, 1.5]]], [0.05, [[0, 0, 0.5], [1, 1, 0.5], [1, 2, 1.5], [0, 3, 1.5]]], [0.15, [[-1, 0, 0.15], [1, 0, 0.15], [1, 0, 1], [-1, 0, 1]]]],
    make: ([r, pts]) => {
      // Bounds as round ends give them; flat caps fall short by at most r.
      const lo = [0, 1, 2].map((k) => Math.min(...pts.map((p) => p[k])) - r);
      const hi = [0, 1, 2].map((k) => Math.max(...pts.map((p) => p[k])) + r);
      return {
        prompt: `Run a pipe named Pipe, a round tube of radius ${r} m, through the points ${pts.map((p) => `[${p}]`).join(', ')} in that order with straight runs between them, and close both ends.`,
        checks: [
          { kind: 'size', name: 'Pipe', size: hi.map((h, k) => h - lo[k]), tol: r + 0.02 },
          { kind: 'center', name: 'Pipe', at: hi.map((h, k) => (h + lo[k]) / 2), tol: r / 2 + 0.02 },
          { kind: 'passes', name: 'Pipe', points: pts, radius: r, tol: 0.02 + r / 2 },
          { kind: 'closed', name: 'Pipe' },
        ],
        solution: [op('curve.add', { name: 'Pipe', bevel_depth: r, fill_caps: true, splines: [{ points: pts }] })],
      };
    },
  },
  {
    category: 'tube',
    variants: [['full', 1, 0.6, 0.05], ['half', 0.8, 0.75, 0.04]],
    make: ([kind, R, H, r]) => kind === 'full'
      ? {
        prompt: `Model a drum named Drum: a cylinder of radius ${R} m and height ${H} m standing on the ground at the origin, with a rope named Rope, a round tube of radius ${r} m, running all the way around its top rim, centred on the rim edge.`,
        checks: [
          { kind: 'size', name: 'Drum', size: [2 * R, 2 * R, H], tol: 0.05 },
          { kind: 'size', name: 'Rope', size: [2 * (R + r), 2 * (R + r), 2 * r], tol: 0.03 },
          { kind: 'center', name: 'Rope', at: [0, 0, H], tol: 0.03 },
          { kind: 'passes', name: 'Rope', points: ring(R, H, 0, 360, 4).slice(0, 4), radius: r, tol: 0.03 },
        ],
        solution: [prim('cylinder', 'Drum', { radius: R, depth: H, location: [0, 0, H / 2] }), op('curve.add', { name: 'Rope', bevel_depth: r, splines: [{ points: ring(R, H, 0, 360, 48) }] })],
      }
      : {
        prompt: `Model a round table top named Top: a cylinder of radius ${R} m, 0.05 m thick, centred on the Z axis with its top face at z = ${H} m. Lay a rope named Rope, a round tube of radius ${r} m, along the half of its top rim edge that faces -Y, from the +X side round to the -X side.`,
        checks: [
          { kind: 'size', name: 'Top', size: [2 * R, 2 * R, 0.05], tol: 0.03 },
          { kind: 'bound', name: 'Top', axis: 'z', side: 'max', eq: H, tol: 0.01 },
          { kind: 'size', name: 'Rope', size: [2 * (R + r), R + 2 * r, 2 * r], tol: r + 0.02 },
          { kind: 'center', name: 'Rope', at: [0, -R / 2, H], tol: r / 2 + 0.02 },
          { kind: 'passes', name: 'Rope', points: ring(R, H, 0, -180, 4), radius: r, tol: 0.03 },
        ],
        solution: [prim('cylinder', 'Top', { radius: R, depth: 0.05, location: [0, 0, H - 0.025] }), op('curve.add', { name: 'Rope', bevel_depth: r, fill_caps: true, splines: [{ points: ring(R, H, 0, -180, 24) }] })],
      },
  },
  {
    category: 'texture',
    variants: [['camo'], ['stripes'], ['spots']],
    make: ([kind]) => ({
      camo: {
        prompt: 'Make a camouflage material named Camo: a noise texture on the base colour, mapped through a colour ramp with constant (hard-edged) steps between at least three colours (dark green, brown and khaki), and put it on a cube named Crate.',
        checks: [{ kind: 'texture', name: 'Crate', texture: 'noise', ramp_mode: 'constant', min_stops: 3 }, { kind: 'material', name: 'Crate', material: 'Camo' }],
        solution: [op('material.create', { name: 'Camo', properties: { roughness: 0.85, base_color: { texture: 'noise', scale: 2.6, distortion: 0.6, ramp: { mode: 'constant', stops: [[0, [0.04, 0.08, 0.02]], [0.45, [0.12, 0.06, 0.02]], [0.64, [0.42, 0.37, 0.22]]] } } } }), prim('cube', 'Crate', { material: 'Camo' })],
      },
      stripes: {
        prompt: 'Make a material named Stripes whose base colour is a wave texture of bands, mapped through a colour ramp from black to white, and put it on a UV sphere named Ball.',
        checks: [{ kind: 'texture', name: 'Ball', texture: 'wave', min_stops: 2 }, { kind: 'material', name: 'Ball', material: 'Stripes' }],
        solution: [op('material.create', { name: 'Stripes', properties: { base_color: { texture: 'wave', wave_type: 'bands', scale: 3, ramp: { mode: 'linear', stops: [[0, [0, 0, 0]], [1, [1, 1, 1]]] } } } }), prim('uv_sphere', 'Ball', { material: 'Stripes' })],
      },
      spots: {
        prompt: 'Make a giraffe-spot material named Spots, a Voronoi texture driving the base colour, put it on a cube named Box, then bake that texture to a 256 x 256 px image so a glTF export can carry it.',
        checks: [{ kind: 'texture', name: 'Box', texture: 'voronoi', baked: true, size: 256 }, { kind: 'material', name: 'Box', material: 'Spots' }],
        solution: [op('material.create', { name: 'Spots', properties: { base_color: { texture: 'voronoi', scale: 5, ramp: { mode: 'constant', stops: [[0, [0.35, 0.18, 0.05]], [0.3, [0.8, 0.6, 0.3]]] } } } }), prim('cube', 'Box', { material: 'Spots' }), op('material.bake', { object: 'Box', size: 256 })],
      },
    })[kind],
  },
  {
    category: 'slots',
    variants: [[]],
    make: () => ({
      prompt: 'Model a crown band named Band: one cylinder mesh of radius 0.5 m and height 0.4 m standing on the ground at the origin, gold on every face of its top half (above z = 0.2) and red on every face of its bottom half; cut it at mid-height first so no face spans both halves.',
      checks: [{ kind: 'size', name: 'Band', size: [1, 1, 0.4], tol: 0.03 }, { kind: 'face_material', name: 'Band', axis: 'z', at: 0.2, above: [1, 0.77, 0.34], below: [0.8, 0.05, 0.05], tol: 0.3 }],
      solution: [mat('Gold', [1, 0.766, 0.336], { metallic: 1 }), mat('Red', [0.8, 0.05, 0.05]), prim('cylinder', 'Band', { radius: 0.5, depth: 0.4, location: [0, 0, 0.2], material: 'Red' }), op('mesh.loop_cut', { object: 'Band', selector: { domain: 'edge', direction: [0, 0, 1], within: 5 }, cuts: 1 }), op('material.assign', { objects: ['Band'], material: 'Gold', slot: 1, selector: { where: 'z > 0.2' } })],
    }),
  },
  {
    category: 'revolve',
    variants: [[]],
    make: () => ({
      prompt: 'Model a vase named Vase as a surface of revolution around the Z axis, standing on the ground at the origin: radius 0.1 m at the base (z = 0), widening to 0.18 m at z = 0.15, narrowing to a 0.06 m neck at z = 0.35 and flaring to 0.09 m at the lip at z = 0.42. Close the bottom.',
      checks: [
        { kind: 'size', name: 'Vase', size: [0.36, 0.36, 0.42], tol: 0.02 },
        { kind: 'bound', name: 'Vase', axis: 'z', side: 'min', eq: 0, tol: 0.01 },
        { kind: 'ray', name: 'Vase', from: [10, 0, 0.15], dir: [-1, 0, 0], axis: 'x', gt: 0.16, lt: 0.195 },
        { kind: 'ray', name: 'Vase', from: [10, 0, 0.35], dir: [-1, 0, 0], axis: 'x', gt: 0.045, lt: 0.08 },
        { kind: 'ray', name: 'Vase', from: [0, 0, -10], dir: [0, 0, 1], axis: 'z', lt: 0.02 },
      ],
      solution: [op('mesh.revolve', { name: 'Vase', profile: [[0, 0], [0, 0.1], [0.15, 0.18], [0.35, 0.06], [0.42, 0.09]], segments: 64 })],
    }),
  },
];

/// A task set: g1 (100 tasks t001…, variants cycling when a template has
/// fewer than its share), p15 (one per variant, p001…) or all.
export function tasks(set = 'g1') {
  if (set === 'all') return [...tasks('g1'), ...tasks('p15')];
  const withScene = (t, id) => ({ id, ...t, solution: [op('scene.create', { name: 'Eval' }), ...t.solution] });
  const expand = (ts) => ts.flatMap((t) => t.variants.map((v) => ({ category: t.category, ...t.make(v) })));
  if (set === 'p15') return expand(p15Templates).map((t, i) => withScene(t, `p${String(i + 1).padStart(3, '0')}`));
  if (set !== 'g1') throw new Error(`unknown task set ${set} (g1, p15 or all)`);
  const base = expand(templates);
  const out = [];
  for (let i = 0; out.length < 100; i++) out.push(withScene(base[i % base.length], `t${String(out.length + 1).padStart(3, '0')}`));
  return out;
}

export const instructions = 'Use only the zender tools. Units are metres, Z is up, angles in degrees. Use the exact object names given. When you are done, export the scene with io.export to result.json (format json, geometry full, overwrite true).';
