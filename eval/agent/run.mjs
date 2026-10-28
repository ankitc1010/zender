// Runs the G1 agent evaluation (TRD §15): each task goes to a fresh headless
// Claude Code session whose only tools are a Zender MCP server confined to a
// temporary directory; the scene the agent exports is then scored with the
// task's checks. Costs real money: every task × model is one paid session.
//
//   node eval/agent/run.mjs --models sonnet,opus [--tasks t001,t002 | --limit 10]
//        [--budget 1.0] [--jobs 2] [--out eval/agent/out] [--bin zig-out/bin/zender]
//
// Writes <out>/results.jsonl (one line per run, appended as runs finish, so a
// rerun skips what is done) and <out>/summary.md.

import { mkdirSync, mkdtempSync, writeFileSync, readFileSync, existsSync, appendFileSync, rmSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { spawn } from 'node:child_process';
import { tasks, instructions } from './tasks.mjs';
import { score } from './check.mjs';

const opt = { models: 'sonnet', budget: '1.0', jobs: '2', out: 'eval/agent/out', bin: 'zig-out/bin/zender' };
for (let a = process.argv.slice(2); a.length; ) {
  const k = a.shift().replace(/^--/, '');
  opt[k] = a.shift();
}
const bin = resolve(opt.bin);
const out = resolve(opt.out);
mkdirSync(out, { recursive: true });
const resultsPath = join(out, 'results.jsonl');

let list = tasks();
if (opt.tasks) list = list.filter((t) => opt.tasks.split(',').includes(t.id));
if (opt.limit) list = list.slice(0, +opt.limit);
const models = opt.models.split(',');

const done = new Set();
if (existsSync(resultsPath)) {
  for (const line of readFileSync(resultsPath, 'utf8').split('\n').filter(Boolean)) {
    const r = JSON.parse(line);
    done.add(`${r.model}/${r.id}`);
  }
}

function runOne(task, model) {
  const dir = mkdtempSync(join(out, `${task.id}-${model}-`));
  for (const [name, text] of Object.entries(task.files ?? {})) writeFileSync(join(dir, name), text);
  writeFileSync(join(dir, 'mcp.json'), JSON.stringify({ mcpServers: { zender: { command: bin, args: ['serve', '--stdio', '--allow-root', dir, '--log-format', 'off'] } } }));
  const args = [
    '-p', `${task.prompt}\n\n${instructions}`,
    '--model', model,
    '--mcp-config', join(dir, 'mcp.json'), '--strict-mcp-config',
    '--tools', '', '--allowedTools', 'mcp__zender',
    '--disable-slash-commands', '--no-session-persistence',
    '--max-budget-usd', opt.budget,
    '--output-format', 'json',
  ];
  const started = Date.now();
  return new Promise((done) => {
    const p = spawn('claude', args, { cwd: dir, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    p.stdout.on('data', (d) => (stdout += d));
    p.stderr.on('data', (d) => (stderr += d));
    p.on('close', (code) => {
      let meta = {};
      try {
        meta = JSON.parse(stdout);
      } catch {
        meta = { is_error: true, result: (stderr || stdout).slice(-500) };
      }
      const fails = score(task, dir);
      const rec = {
        id: task.id, category: task.category, model, pass: fails.length === 0, fails,
        turns: meta.num_turns ?? null, cost_usd: meta.total_cost_usd ?? null,
        seconds: Math.round((Date.now() - started) / 1000), exit: code,
        error: meta.is_error ? String(meta.subtype ?? meta.result ?? 'error').slice(0, 300) : null,
      };
      if (rec.pass) rmSync(dir, { recursive: true, force: true });
      else Object.assign(rec, { dir, answer: String(meta.result ?? '').slice(0, 600) });
      done(rec);
    });
  });
}

const queue = models.flatMap((m) => list.filter((t) => !done.has(`${m}/${t.id}`)).map((t) => [t, m]));
let next = 0;
async function worker() {
  while (next < queue.length) {
    const [t, m] = queue[next++];
    const r = await runOne(t, m);
    appendFileSync(resultsPath, JSON.stringify(r) + '\n');
    console.log(`${r.pass ? 'PASS' : 'FAIL'} ${m} ${t.id} [${t.category}] ${r.turns ?? '?'} turns $${r.cost_usd?.toFixed(3) ?? '?'} ${r.seconds}s${r.pass ? '' : `  ${r.error ?? r.fails.join('; ')}`}`);
  }
}
await Promise.all(Array.from({ length: Math.max(1, +opt.jobs) }, worker));

// ---- summary over everything recorded so far ----
const all = readFileSync(resultsPath, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
const pct = (rs) => (rs.length ? `${((100 * rs.filter((r) => r.pass).length) / rs.length).toFixed(0)}%` : '–');
const median = (xs) => {
  const s = xs.filter((x) => x != null).sort((a, b) => a - b);
  return s.length ? s[Math.floor(s.length / 2)] : null;
};
const lines = ['# G1 agent evaluation', '', '| model | tasks | pass | median turns | total cost |', '|---|---|---|---|---|'];
for (const m of [...new Set(all.map((r) => r.model))]) {
  const rs = all.filter((r) => r.model === m);
  lines.push(`| ${m} | ${rs.length} | ${pct(rs)} | ${median(rs.map((r) => r.turns)) ?? '–'} | $${rs.reduce((s, r) => s + (r.cost_usd ?? 0), 0).toFixed(2)} |`);
}
lines.push('', '| category | ' + [...new Set(all.map((r) => r.model))].join(' | ') + ' |', '|---|' + [...new Set(all.map((r) => r.model))].map(() => '---|').join(''));
for (const c of [...new Set(all.map((r) => r.category))]) {
  lines.push(`| ${c} | ` + [...new Set(all.map((r) => r.model))].map((m) => pct(all.filter((r) => r.model === m && r.category === c))).join(' | ') + ' |');
}
const failed = all.filter((r) => !r.pass);
if (failed.length) {
  lines.push('', '## Failures', '');
  for (const r of failed) lines.push(`- ${r.model} ${r.id} (${r.category}): ${r.error ?? r.fails.join('; ')}`);
}
writeFileSync(join(out, 'summary.md'), lines.join('\n') + '\n');
console.log('\n' + lines.slice(0, 2 + 2 + new Set(all.map((r) => r.model)).size).join('\n'));
