// Proves the G1 task set is passable: replays each task's reference solution
// with `zender run`, exports result.json the way an agent is told to, and
// runs the task's checks on it. Offline and free; a failing task here is a
// bug in the task, not in an agent.
//
//   node eval/agent/selfcheck.mjs [path/to/zender] [task-id ...]
//
// Checks every set (G1's t001… and P1.5's p001…).

import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { tasks } from './tasks.mjs';
import { score } from './check.mjs';

const args = process.argv.slice(2);
const bin = resolve(args[0] && !/^[tp]\d{3}$/.test(args[0]) ? args.shift() : 'zig-out/bin/zender');
const only = new Set(args);
const base = process.env.ZENDER_EVAL_TMP ?? tmpdir();

let failed = 0;
const all = tasks('all').filter((t) => !only.size || only.has(t.id));
for (const t of all) {
  const dir = mkdtempSync(join(base, `g1-${t.id}-`));
  for (const [name, text] of Object.entries(t.files ?? {})) writeFileSync(join(dir, name), text);
  const log = [...t.solution, { tool: 'io.export', params: { path: 'result.json', format: 'json', geometry: 'full', overwrite: true } }];
  writeFileSync(join(dir, 'ops.jsonl'), log.map((o) => JSON.stringify(o)).join('\n') + '\n');
  const r = spawnSync(bin, ['run', 'ops.jsonl'], { cwd: dir, encoding: 'utf8' });
  const fails = r.status === 0 ? score(t, dir) : [`replay failed: ${(r.stderr || r.error?.message || '').trim()}`];
  if (fails.length) {
    failed++;
    console.log(`FAIL ${t.id} [${t.category}] ${t.prompt.slice(0, 70)}…\n  ${fails.join('\n  ')}`);
  }
  if (!fails.length || !process.env.ZENDER_EVAL_KEEP) rmSync(dir, { recursive: true, force: true });
}
console.log(`${all.length - failed}/${all.length} reference solutions pass`);

// The negative control: an agent that does nothing must fail every task.
const empty = mkdtempSync(join(base, 'g1-empty-'));
writeFileSync(join(empty, 'ops.jsonl'), JSON.stringify({ tool: 'scene.create', params: { name: 'Eval' } }) + '\n');
const e = spawnSync(bin, ['run', 'ops.jsonl', '-o', 'result.json'], { cwd: empty, encoding: 'utf8' });
if (e.status !== 0) throw new Error(`empty scene export failed: ${e.stderr}`);
const loose = all.filter((t) => score(t, empty).length === 0);
rmSync(empty, { recursive: true, force: true });
for (const t of loose) console.log(`LOOSE ${t.id}: an empty scene passes "${t.prompt.slice(0, 60)}…"`);
failed += loose.length;
process.exit(failed ? 1 : 0);
