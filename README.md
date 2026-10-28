# Zender

A headless 3D scene engine in Zig that LLM agents drive through the Model Context Protocol. It builds, edits, renders and exports scenes with no GUI, and every operation is a typed, schema-checked MCP tool: there is no code-execution path.

Zender borrows Blender's concepts (datablocks, an RNA-style property registry, Blender's primitives and defaults) but is an independent implementation, not a fork. The design is in the [technical requirements document](https://claude.ai/artifact/6DEysg565wv9dJ7wv7XRQi).

**Status: P0 (Foundations) and P1 (Modeling) done apart from the paid agent-evaluation run; P1.5 (Materials and modelling) under way; version 0.1.0-dev.** Agents can build scenes from primitives, materials, cameras and lights, group them in collections, edit meshes element by element (select, extrude, inset, loop cut, bevel, triangulate, merge, transform, smooth, sculpt), combine them with booleans, stack non-destructive modifiers on them (array, mirror, solidify, subdivision, bevel, boolean, displace, decimate, triangulate), UV-unwrap them, look at them with a preview renderer, export glTF 2.0, OBJ, STL, PLY or a canonical `scene.json`, and import OBJ, STL and PLY. P1.5 adds organic modelling with blended implicit shapes (`mesh.from_sdf`), lathed profiles (`mesh.revolve`), meshes from raw data, curves swept into tubes, per-face material slots, shape colours that blend into a vertex colour attribute (glTF `COLOR_0`) for smooth colour borders, coat, sheen and specular, procedural textures that match Blender's Noise, Wave and Voronoi nodes, and baking them to images that glTF carries. `.blend` I/O comes next (see [Roadmap](#roadmap)).

## Build

Requires Zig 0.16.0. The first build fetches [Manifold](https://github.com/elalish/manifold) v3.5.4 (pinned by hash in `build.zig.zon`) and compiles it with `zig c++`; `-Dboolean=none` builds without it and without `mesh.boolean`, as wasm32 always does. Release builds use Zig's fast `smp_allocator`; `-Ddebug-allocator` switches back to its leak-checking one.

```sh
zig build            # zig-out/bin/zender (ReleaseSafe)
zig build test       # unit, integration and golden tests
zig build test -Dupdate-golden                       # rewrite tests/golden from current output; review the diff
zig build test -Dtarget=wasm32-wasi                  # engine, render and I/O tests on Node's WASI
zig build test-compile -Dtarget=x86_64-windows-gnu   # build tests for another target without running them
```

CI (`.github/workflows/ci.yml`) checks formatting and cross-compiles the CLI and tests for Linux (x86-64, arm64), macOS (arm64, x86-64), Windows (x86-64) and wasm32-wasi, and runs the WASI tests. It then runs the tests natively on Linux x86-64 and arm64, macOS and Windows, plus the x86-64 macOS tests under Rosetta 2. It replays `examples/dining.jsonl`, checks the MCP handshake over stdio, runs a scripted MCP Inspector session in both protocol eras, checks the memory targets, replays the reference solutions of the agent-evaluation tasks, and validates the exported glTF with the Khronos validator. A separate job measures line coverage with kcov.

## Use with an MCP client

```sh
zender serve --stdio --allow-root ~/scenes
```

For Claude Code:

```sh
claude mcp add zender -- /path/to/zender serve --stdio --allow-root ~/scenes
```

Zender speaks MCP 2026-07-28 (stateless: `server/discover`, per-request `_meta`) and also accepts the 2025-11-25 `initialize` handshake. Tools may read and write files only inside `--allow-root` directories (default: the current directory). Relative paths start at the first root.

Other commands:

```sh
zender run ops.jsonl -o out.glb   # replay a command log, write .glb, .gltf, .json (scene.json) or .png
zender tools [--json]             # list the tools and their input schemas
zender version
```

Exit codes: 0 success, 1 user error, 2 I/O error, 3 internal error.

The operator, not the agent, sets the per-call budgets (SEC-3): `--max-triangles` (default 20 M), `--max-scene-mb` (4096), `--max-wall-ms` (60000), `--max-render-edge` (8192), `--max-spp` (4096) and `--confirm-delete-over` (10). The wall-time limit stops a call part-way: parallel loops stop claiming work, `scene.apply` checks it between ops, and the call fails with `budget_exceeded` and changes nothing.

Observability: `serve` writes one JSON log line per tool call to stderr (`--log-format json|text|off`). `--trace-file <path>` appends one OpenTelemetry span per call as OTLP/JSON, the format the Collector's `otlpjsonfile` receiver reads. A span continues the caller's trace when the request's `_meta` carries `traceparent` and `tracestate`.

## Tools

| Group | Tools |
| --- | --- |
| Scene | `scene.create`, `scene.inspect`, `scene.validate`, `scene.undo`, `scene.redo`, `scene.apply`, `scene.close` |
| Object | `object.add_primitive`, `object.duplicate`, `object.delete`, `object.transform`, `object.set_parent`, `object.set_properties` |
| Create | `mesh.from_data`, `mesh.revolve`, `mesh.from_sdf`, `curve.add`, `curve.to_mesh` |
| Mesh | `mesh.select_preview`, `mesh.transform_elements`, `mesh.extrude`, `mesh.inset`, `mesh.triangulate`, `mesh.merge`, `mesh.loop_cut`, `mesh.bevel`, `mesh.uv_unwrap`, `mesh.boolean`, `mesh.smooth`, `mesh.sculpt` |
| Modifier | `modifier.add`, `modifier.update`, `modifier.remove`, `modifier.apply` |
| Collection | `collection.create`, `collection.update`, `collection.delete` |
| Shading | `material.create`, `material.update`, `material.assign`, `material.bake`, `world.set` |
| Camera and light | `camera.add`, `camera.look_at`, `camera.frame_objects`, `light.add` |
| Render | `render.preview` |
| I/O | `io.export`, `io.import` |
| Introspection | `schema.describe`, `ops.list` |

Conventions: right-handed, Z up, metres, angles in degrees at the tool boundary (radians inside), colours scene-linear Rec.709 in 0..1.

Every call names its scene with the `scene_id` that `scene.create` returns. Mutating tools accept `if_rev` for optimistic concurrency and return `scene_rev`, `changed`, `created` and `warnings`. Errors return `isError` with `{code, message, path, hint, valid_values}`, so a model can correct itself. `scene.apply` runs up to 256 ops as one all-or-nothing transaction and one undo step. Destructive calls ask for confirmation through MRTR when the client supports elicitation; otherwise they need `confirm: true`.

Mesh tools take a **selector** instead of a stored selection, since an agent cannot click. A selector is one JSON object whose keys must all hold: `domain` (face, edge or vert), `index` (indices and `[first, last]` ranges), `where` (`"z > 0.5"`, `"abs(x) < 0.1"`, `"material_index == 1"`), `box`, `sphere`, `normal` with `within` degrees, `direction` (edges running along an axis, either way, with the same `within`), and `union` / `intersect` / `subtract` of nested selectors. Positions and normals are in world space unless `space` is `local`. Each tool returns a `result` selector for the elements it leaves selected (the extruded caps, the inset faces), so the next call can use it as is. Offsets and distances are world metres, as `scene.inspect` reports bounds. Every result is validated (FR-GEO-3); new winding conflicts or zero-area faces come back as warnings. Long operators stop at the call's wall-time budget and change nothing.

Modifiers change what previews (viewport settings) and exports (render settings) see, not the mesh, until `modifier.apply`. A depsgraph evaluates objects that other objects' modifiers read (boolean operands, mirror centres, array offsets) first, caches each result under a hash of its inputs, and refuses targets that would make a cycle, naming the path. `mesh.transform_elements` takes a soft-selection `falloff` (radius, curve, straight or along edges), `mesh.smooth` relaxes vertices without shrinking them (Taubin), and `mesh.sculpt` brushes strokes (draw, inflate, flatten, pinch, crease, smooth, grab) with radius, strength, falloff and mirror symmetry, for organic shapes such as faces. `mesh.boolean` unions, subtracts or intersects two closed meshes through [Manifold](https://github.com/elalish/manifold) (Apache-2.0), keeping UVs, smooth shading and material slots; the operand is hidden, deleted or kept. `mesh.uv_unwrap` splits faces into charts (smart: by seams and normal angle; conformal: by seams only), flattens each with least-squares conformal maps, scales them to one texel density and packs them into 0..1. `io.export` writes OBJ (+ MTL), STL and PLY as Blender's exporters do by default (OBJ Y-up, world transforms applied); `io.import` reads them back, keeping n-gons, UVs, material slots and smooth shading, and lists whatever it could not carry.

`render.preview` returns the image inline (long edge ≤ 1024 px), a `zender://scene/{id}/render/{job}` link to the full-size PNG, and which objects are visible and how many pixels each covers.

Resources: `zender://scenes`, `zender://scene/{id}/outline`, `zender://scene/{id}/object/{name}`, `zender://scene/{id}/render/{job}`, `zender://scene/{id}/log`, `zender://scene/{id}/scene.json`, `zender://docs/{topic}`. Prompts: `build_scene_from_description`, `product_shot`.

## Design

Five layers; `build.zig` gives each module imports only from lower layers, so an upward import fails to compile.

| Layer | Modules | Role |
| --- | --- | --- |
| Front ends | `src/mcp`, `src/cli` | Wire formats only, no scene logic |
| Command core | `src/cmd` | Dispatcher, schema validation, budgets, transactions, command log, tool handlers |
| Engine | `src/core`, `src/geom`, `src/eval` | Database, property registry, undo, geometry (EditMesh, selectors, operators), evaluation |
| Render and I/O | `src/render`, `src/io` | Preview rasteriser, PNG, glTF/GLB |
| Interchange and platform | `src/ir`, `src/math` | Flat evaluated-scene snapshot; math and the thread pool |

- **Data model:** datablocks live in generational pools addressed by `{type, index, generation}` handles, so a stale handle is detected, never dereferenced. Names follow Blender's rules (≤ 255 bytes, `.001` suffixes). Mesh data is structure-of-arrays with copy-on-write buffers, so snapshots for transactions and undo copy no vertex data.
- **Property registry:** each datablock type declares its properties once. That table drives validation, unit conversion at the boundary, JSON Schema for the tools, `schema.describe`, and the `.blend` member names for P2.
- **Determinism:** the same command log and seed give byte-identical glTF and PNG output, independent of thread count. All parallel work runs through one `parallelFor` on the shared `std.Io` pool. Chunks write disjoint outputs and merge in fixed order.
- **EditMesh:** topology-changing operators work on a half-edge structure with disk cycles around vertices and radial cycles around edges, so n-gons, non-manifold edges, loose geometry and holes all work (FR-GEO-2). Conversion from and to the stored mesh is O(n), and a round trip without edits returns identical arrays. Attributes (UVs, flat shading, material indices, any generic layer) are copied or interpolated onto new elements.
- **Evaluation cache:** evaluated normals are cached per scene, keyed by buffer serials that are never reused and change on every write.
- **Collections:** a tree under the scene's master collection, one parent each. An object is hidden from render or preview only if every collection path to it hides it, as in Blender.
- **scene.json (FR-DM-8):** a canonical dump for diffs and tests: datablocks sorted by name and linked by name, stored units (metres, radians), mesh arrays as XxHash64 digests or in full. Equal scenes give byte-identical files.

## Testing

`zig build test` runs 142 tests: math, data model, collections, undo, scene.json, primitives, normals, EditMesh, selectors, the mesh operators and UV unwrapping, OBJ/STL/PLY reading and writing, the rasteriser (including near-plane clipping and 1/4/16-thread determinism), PNG encode and decode, glTF export, path confinement, budgets and tracing, the command core end to end, command-log replay, the MCP protocol, and two golden suites:

- **Golden geometry** (`tests/golden/geometry.json`, `tests/golden/mesh_ops.json`): 12 primitive cases and 31 mesh-operator, modifier and sculpt cases, each a short `scene.apply` op list. Counts and a digest of the connectivity must match exactly. Bounds, area, volume and UV sums must match within a tolerance, because trigonometry may differ in the last bit between platforms' libm.
- **Golden render** (`tests/golden/render/`): 5 previews replayed from command logs, compared by PSNR (≥ 40 dB) and the share of pixels off by more than 8 levels (≤ 0.2%).

The official MCP conformance suite tests servers over HTTP only, so it joins CI with Streamable HTTP in P3. Until then `scripts/inspector-session.sh` drives the server with MCP Inspector over stdio in both protocol eras, with `--strict` schema checks. Still to come: FLIP for renders, Blender parity, fuzzing and benchmark gates.

**Agent evaluation (G1 and G1.5, `eval/agent/`).** 100 G1 tasks across ten categories (primitives, arrangement, materials, cameras and lights, mesh editing, booleans, modifiers, UVs and files, organic shapes, small scenes), each a request in plain words, checks on the scene the agent exports (sizes, bounds, volumes, face counts, materials, modifiers, camera aim, symmetry, files) and a reference solution, plus 15 P1.5 tasks (`--set p15`: blended shapes, rounded and dented solids, pipes and rope rims, textured and baked materials, two-material meshes, a lathed vase) scored with ray probes, watertightness, texture recipes and per-face materials, so any route to the right shape passes. `node eval/agent/selfcheck.mjs` replays every reference solution and checks that an empty scene fails every task; it runs in CI. `node eval/agent/run.mjs --models sonnet,opus [--set p15]` gives each task to a fresh headless Claude Code session whose only tools are a Zender server confined to a temporary directory, scores the result and writes `results.jsonl` and `summary.md`. Each run is a paid session (Sonnet about $0.03–0.13 a task, Opus about $0.3).

**Blender parity for P1.5 (G1.5, `examples/bust/`).** `bust_spec.py` describes a sculpted bust once; `gen_zender.py` turns it into `examples/bust.jsonl` (62 calls, 3.15 M triangles, replayed in CI and checked with the Khronos validator), and two Blender scripts build the same bust with Blender's own tools and compare. `blender_parity.py` checks every part (symmetric Hausdorff distance within one voxel, volume within 1%; `ONLY=Head,Hair` runs a few parts per process where memory is short): all 21 parts pass, most at 0 mm. `blender_materials.py` checks every material value against a Blender node tree built from the spec, and Zender's bakes against Cycles' bakes of the same recipes and UVs (RMSE at most 1/255).

Checks run by hand during P0:

- glTF output passes the [Khronos glTF validator](https://github.com/KhronosGroup/glTF-Validator) with 0 errors and 0 warnings.
- A real Claude agent (Sonnet, headless Claude Code with only the zender tools) built a table scene from a one-line request. It took 9 turns and about $0.15. It checked the scene with two previews, fixed the framing, and exported a valid GLB.
- In P1 the same setup modelled a house by mesh editing (extruded roof merged into a ridge, recessed door): 16 turns, $0.18, one self-corrected selector error.
- Blender 4.3 imports Zender's OBJ, STL and PLY files with the same counts, bounds, UVs and materials, and Zender imports Blender's.

Measured on a phone (MediaTek Dimensity 9400, 8 cores, ReleaseSafe). The TRD's targets are for an 8-core x86-64 machine.

| Measure | Result | Target |
| --- | --- | --- |
| Cold start to first `server/discover` response | 16 ms median | ≤ 50 ms |
| Non-geometry tool on a 1.3 M-triangle scene | 2–5 ms | ≤ 20 ms p95 |
| `render.preview` 512×512, 1.3 M triangles | 140 ms first, ~84 ms after | ≤ 150 ms for 1 M |
| Mesh operator on a 100,489-face grid (whole call) | extrude 105 ms, inset 110 ms, triangulate 119 ms, merge by distance 144 ms, flat UV unwrap 149 ms; individual-face extrude or inset 285 ms (5× the output), loop cut through every column 327 ms | ≤ 200 ms for a 100 k-face selection |
| Bevel on a 50,176-face sphere | 139 ms (half the edges), 379 ms (all 100 k edges) | ≤ 200 ms |
| UV unwrap of a 100,489-face sphere | 4.6–4.8 s (conjugate gradients with an incomplete-Cholesky preconditioner; was 12.7 s unpreconditioned; a sparse direct solver is next) | ≤ 200 ms |
| Binary size (ReleaseSafe, not stripped; Manifold and libc++ linked, Manifold without debug info) | 15.3 MB | ≤ 30 MB |
| `tools/list` payload (MCP response, 45 tools) | 58.0 KB | ≤ 40 KB (hard cap raised to 60 KB) |
| Idle RSS (`scripts/measure-memory.mjs`) | 1.5 MB | ≤ 30 MB |
| RSS over mesh bytes, 1 M-triangle scene after a preview | 1.55× | ≤ 2.5× |

## Roadmap

| Phase | Scope | Gate |
| --- | --- | --- |
| P0 Foundations (this release) | Data model, registry, collections, command core, log, MCP stdio, primitives, cameras, preview render, glTF, scene.json | An agent builds a scene and exports glTF |
| P1 Modeling | EditMesh, selectors, 10 mesh operators, modifier stack, depsgraph, OBJ/STL/PLY | Golden and determinism suites green; agent eval ≥ 50% |
| P1.5 Materials and modelling | Implicit shapes, curves, revolve, raw meshes, per-face slots, Principled layers, procedural textures, bake | The bust rebuilt in Zender matches Blender part by part |
| P2 Blender interop | `.blend` read and write, images, keyframes, parity harness, loss reports | Round-trip parity on the `.blend` corpus |
| P3 Production | CPU path tracer, MCP tasks, Streamable HTTP and auth, C ABI, fuzzing, benchmarks | All NFRs met, agent eval ≥ 80%, 24 h fuzz clean |

Where P0 departs from the TRD:

- The MCP layer is written in-house rather than with `mcp.zig` (open question Q1), because Zender needs both protocol eras.
- Tool definitions live in `src/cmd/tools`, not `src/mcp/tools`, so the CLI and the future C ABI share them.
- An interchange layer (`src/ir`) sits between the engine and render/I/O, so those layers never read the database.

## Licence

Apache-2.0; see [LICENSE](LICENSE) and [NOTICE](NOTICE). Contributions must not copy, translate or closely paraphrase code from Blender's GPL sources. Outputs (renders, glTF files) carry no licence obligation from Zender.
