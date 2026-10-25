// Measures NFR-5 on Linux: the idle RSS of `zender serve --stdio`, and what a
// loaded scene costs in RSS over its raw mesh bytes (targets: 30 MB, 2.5x).
// Also reports the cost of an empty scene, from 64 of them (NFR-7).
//
//   node scripts/measure-memory.mjs [path/to/zender] [--check]
//
// RSS is read from /proc/<pid>/status. The loaded scene is a smooth UV sphere
// of about 1 M triangles after one preview, so its evaluated normals are
// cached as they would be in a session. --check exits 1 when a target is
// missed.
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { createInterface } from 'node:readline';

const argv = process.argv.slice(2);
const check = argv.includes('--check');
const bin = argv.find((a) => !a.startsWith('--')) ?? 'zig-out/bin/zender';
const meta = { 'io.modelcontextprotocol/protocolVersion': '2026-07-28', 'io.modelcontextprotocol/clientCapabilities': {} };

const child = spawn(bin, ['serve', '--stdio', '--log-format', 'off'], { stdio: ['pipe', 'pipe', 'inherit'] });
const waiting = new Map();
createInterface({ input: child.stdout }).on('line', (line) => {
  const msg = JSON.parse(line);
  waiting.get(msg.id)?.(msg);
  waiting.delete(msg.id);
});
let nextId = 1;
function rpc(method, params = {}) {
  const id = nextId++;
  return new Promise((resolve) => {
    waiting.set(id, resolve);
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params: { ...params, _meta: meta } }) + '\n');
  });
}
async function tool(name, args) {
  const r = await rpc('tools/call', { name, arguments: args });
  if (r.error || r.result.isError) throw new Error(`${name} failed: ${JSON.stringify(r.error ?? r.result.structuredContent)}`);
  return r.result.structuredContent;
}
function rssKiB() {
  return Number(/VmRSS:\s+(\d+) kB/.exec(readFileSync(`/proc/${child.pid}/status`, 'utf8'))[1]);
}
const mb = (bytes) => (bytes / (1 << 20)).toFixed(1);

await rpc('server/discover');
const idle = rssKiB() * 1024;

const { scene_id } = await tool('scene.create', {});
await tool('object.add_primitive', { scene_id, kind: 'uv_sphere', segments: 1024, rings: 512, smooth: true });
await tool('render.preview', { scene_id, width: 256, height: 256 });
const loaded = rssKiB() * 1024;
const scenes = JSON.parse((await rpc('resources/read', { uri: 'zender://scenes' })).result.contents[0].text);
const meshBytes = scenes.find((s) => s.scene_id === scene_id).bytes;
const ratio = (loaded - idle) / meshBytes;

for (let i = 0; i < 64; i++) await tool('scene.create', {});
const perScene = (rssKiB() * 1024 - loaded) / 64;
child.stdin.end();

const idleOk = idle <= 30 * (1 << 20);
const ratioOk = ratio <= 2.5;
console.log(`idle RSS                 ${mb(idle)} MB (target <= 30 MB) ${idleOk ? 'ok' : 'MISSED'}`);
console.log(`1 M-triangle scene       ${mb(meshBytes)} MB of mesh buffers, RSS +${mb(loaded - idle)} MB = ${ratio.toFixed(2)}x (target <= 2.5x) ${ratioOk ? 'ok' : 'MISSED'}`);
console.log(`empty scene              ${(perScene / 1024).toFixed(1)} KB each, from 64`);
if (check && !(idleOk && ratioOk)) process.exit(1);
