// Runs a wasm32-wasi binary (a unit-test runner, in practice) under Node's
// built-in WASI, so the Tier 2 WASI tests need no extra runtime (TRD §14).
//
//   node --no-warnings scripts/run-wasi.mjs zig-out/bin/test-engine.wasm
//
// The working directory is preopened as '.', as wasmtime --dir . would do.
import { readFile } from 'node:fs/promises';
import { argv, exit } from 'node:process';
import { WASI } from 'node:wasi';

const [file, ...args] = argv.slice(2);
if (!file) {
  console.error('usage: node scripts/run-wasi.mjs <file.wasm> [args...]');
  exit(2);
}
const wasi = new WASI({ version: 'preview1', args: [file, ...args], env: {}, preopens: { '.': '.' }, returnOnExit: true });
const module = await WebAssembly.compile(await readFile(file));
const instance = await WebAssembly.instantiate(module, wasi.getImportObject());
exit(wasi.start(instance));
