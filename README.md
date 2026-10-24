# Zender

A headless 3D scene engine in Zig that LLM agents drive through the Model Context Protocol. It builds, edits, renders and exports scenes with no GUI, and every operation is a typed, schema-checked MCP tool: there is no code-execution path.

Zender borrows Blender's concepts (datablocks, an RNA-style property registry, Blender's primitives and defaults) but is an independent implementation, not a fork. The design is in the [technical requirements document](https://claude.ai/artifact/6DEysg565wv9dJ7wv7XRQi).

**Status: P0 (Foundations), version 0.1.0-dev.** Agents can build scenes from primitives, materials, cameras and lights, look at them with a preview renderer, and export glTF 2.0. Mesh editing, modifiers and `.blend` I/O come in P1 and P2 (see [Roadmap](#roadmap)).

## Build

Requires Zig 0.16.0.

```sh
zig build            # zig-out/bin/zender (ReleaseSafe)
zig build test       # unit and integration tests
zig build test-compile -Dtarget=x86_64-windows-gnu   # build tests for another target without running them
```

CI (`.github/workflows/ci.yml`) checks formatting and cross-compiles the CLI and tests for Linux (x86-64, arm64), macOS (arm64, x86-64) and Windows (x86-64). It then runs the tests natively on Linux x86-64 and arm64, macOS and Windows, replays `examples/dining.jsonl`, checks the MCP handshake over stdio, and validates the exported glTF with the Khronos validator.

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
zender run ops.jsonl -o out.glb   # replay a command log, write .glb, .gltf or .png
zender tools [--json]             # list the tools and their input schemas
zender version
```

Exit codes: 0 success, 1 user error, 2 I/O error, 3 internal error.

## Tools

| Group | Tools |
| --- | --- |
| Scene | `scene.create`, `scene.inspect`, `scene.validate`, `scene.undo`, `scene.redo`, `scene.apply`, `scene.close` |
| Object | `object.add_primitive`, `object.duplicate`, `object.delete`, `object.transform`, `object.set_parent`, `object.set_properties` |
| Shading | `material.create`, `material.update`, `material.assign`, `world.set` |
| Camera and light | `camera.add`, `camera.look_at`, `camera.frame_objects`, `light.add` |
| Render | `render.preview` |
| I/O | `io.export` |
| Introspection | `schema.describe`, `ops.list` |

Conventions: right-handed, Z up, metres, angles in degrees at the tool boundary (radians inside), colours scene-linear Rec.709 in 0..1.

Every call names its scene with the `scene_id` that `scene.create` returns. Mutating tools accept `if_rev` for optimistic concurrency and return `scene_rev`, `changed`, `created` and `warnings`. Errors return `isError` with `{code, message, path, hint, valid_values}`, so a model can correct itself. `scene.apply` runs up to 256 ops as one all-or-nothing transaction and one undo step. Destructive calls ask for confirmation through MRTR when the client supports elicitation; otherwise they need `confirm: true`.

`render.preview` returns the image inline (long edge ≤ 1024 px), a `zender://scene/{id}/render/{job}` link to the full-size PNG, and which objects are visible and how many pixels each covers.

Resources: `zender://scenes`, `zender://scene/{id}/outline`, `zender://scene/{id}/object/{name}`, `zender://scene/{id}/render/{job}`, `zender://scene/{id}/log`, `zender://docs/{topic}`. Prompts: `build_scene_from_description`, `product_shot`.

## Design

Five layers; `build.zig` gives each module imports only from lower layers, so an upward import fails to compile.

| Layer | Modules | Role |
| --- | --- | --- |
| Front ends | `src/mcp`, `src/cli` | Wire formats only, no scene logic |
| Command core | `src/cmd` | Dispatcher, schema validation, budgets, transactions, command log, tool handlers |
| Engine | `src/core`, `src/geom`, `src/eval` | Database, property registry, undo, geometry, evaluation |
| Render and I/O | `src/render`, `src/io` | Preview rasteriser, PNG, glTF/GLB |
| Interchange and platform | `src/ir`, `src/math` | Flat evaluated-scene snapshot; math and the thread pool |

- **Data model:** datablocks live in generational pools addressed by `{type, index, generation}` handles, so a stale handle is detected, never dereferenced. Names follow Blender's rules (≤ 255 bytes, `.001` suffixes). Mesh data is structure-of-arrays with copy-on-write buffers, so snapshots for transactions and undo copy no vertex data.
- **Property registry:** each datablock type declares its properties once. That table drives validation, unit conversion at the boundary, JSON Schema for the tools, `schema.describe`, and the `.blend` member names for P2.
- **Determinism:** the same command log and seed give byte-identical glTF and PNG output, independent of thread count. All parallel work runs through one `parallelFor` on the shared `std.Io` pool. Chunks write disjoint outputs and merge in fixed order.
- **Evaluation cache:** evaluated normals are cached per scene, keyed by buffer serials that are never reused and change on every write.

## Testing

`zig build test` runs 49 tests: math, data model, undo, primitives (counts and volumes), normals, the rasteriser (including near-plane clipping and 1/4/16-thread determinism), PNG, glTF export, path confinement, the command core end to end, command-log replay, and the MCP protocol. These suites in the TRD's plan aren't automated yet: MCP conformance, Blender parity, fuzzing, benchmark gates and agent evaluation.

Checks run by hand during P0:

- glTF output passes the [Khronos glTF validator](https://github.com/KhronosGroup/glTF-Validator) with 0 errors and 0 warnings.
- A real Claude agent (Sonnet, headless Claude Code with only the zender tools) built a table scene from a one-line request. It took 9 turns and about $0.15. It checked the scene with two previews, fixed the framing, and exported a valid GLB.

Measured on a phone (MediaTek Dimensity 9400, 8 cores, ReleaseSafe). The TRD's targets are for an 8-core x86-64 machine.

| Measure | Result | Target |
| --- | --- | --- |
| Cold start to first `server/discover` response | 16 ms median | ≤ 50 ms |
| Non-geometry tool on a 1.3 M-triangle scene | 2–5 ms | ≤ 20 ms p95 |
| `render.preview` 512×512, 1.3 M triangles | 140 ms first, ~84 ms after | ≤ 150 ms for 1 M |
| Binary size (ReleaseSafe, not stripped) | 6.5 MB | ≤ 30 MB |
| `tools/list` payload | 32.7 KB | ≤ 40 KB |

## Roadmap

| Phase | Scope | Gate |
| --- | --- | --- |
| P0 Foundations (this release) | Data model, registry, command core, log, MCP stdio, primitives, cameras, preview render, glTF | An agent builds a scene and exports glTF |
| P1 Modeling | EditMesh, selectors, 10 mesh operators, modifier stack, depsgraph, OBJ/STL/PLY | Golden and determinism suites green; agent eval ≥ 50% |
| P2 Blender interop | `.blend` read and write, images, keyframes, parity harness, loss reports | Round-trip parity on the `.blend` corpus |
| P3 Production | CPU path tracer, MCP tasks, Streamable HTTP and auth, C ABI, fuzzing, benchmarks | All NFRs met, agent eval ≥ 80%, 24 h fuzz clean |

Where P0 departs from the TRD:

- The MCP layer is written in-house rather than with `mcp.zig` (open question Q1), because Zender needs both protocol eras.
- Tool definitions live in `src/cmd/tools`, not `src/mcp/tools`, so the CLI and the future C ABI share them.
- An interchange layer (`src/ir`) sits between the engine and render/I/O, so those layers never read the database.

## Licence

Apache-2.0; see [LICENSE](LICENSE) and [NOTICE](NOTICE). Contributions must not copy, translate or closely paraphrase code from Blender's GPL sources. Outputs (renders, glTF files) carry no licence obligation from Zender.
