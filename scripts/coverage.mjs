// Line coverage of src/core, src/geom and src/io (TRD §15 targets 85%),
// measured with kcov over every Debug test binary, unit and golden alike.
// Linux only; needs kcov on PATH.
//
//   node scripts/coverage.mjs [--min <percent>]
//
// Prints a table per directory and appends it to $GITHUB_STEP_SUMMARY when
// set. With --min, exits 1 if any directory is below that percentage.
import { execFileSync } from 'node:child_process';
import { appendFileSync, mkdirSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { join, resolve, sep } from 'node:path';

const argv = process.argv.slice(2);
const minAt = argv.indexOf('--min');
const min = minAt >= 0 ? Number(argv[minAt + 1]) : null;

const root = resolve('.');
const prefix = join(root, 'zig-out', 'coverage');
const out = join(root, 'coverage');
const dirs = ['core', 'geom', 'io'];
const dirPaths = dirs.map((d) => join(root, 'src', d) + sep);

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true }); // kcov creates only the last directory
execFileSync('zig', ['build', 'test-compile', '-Doptimize=Debug', '--prefix', prefix], { stdio: 'inherit' });
const bins = readdirSync(join(prefix, 'bin')).filter((f) => f.startsWith('test-')).sort();
for (const b of bins) {
  execFileSync('kcov', [`--include-path=${dirPaths.join(',')}`, join(out, b), join(prefix, 'bin', b)], { stdio: 'inherit' });
}
execFileSync('kcov', ['--merge', join(out, 'merged'), ...bins.map((b) => join(out, b))], { stdio: 'inherit' });

function summarize(report) {
  const rows = dirs.map((d, i) => {
    const files = report.files.filter((f) => f.file.startsWith(dirPaths[i]));
    const covered = files.reduce((n, f) => n + Number(f.covered_lines), 0);
    const total = files.reduce((n, f) => n + Number(f.total_lines), 0);
    return { dir: `src/${d}`, files: files.length, covered, total, percent: total ? (100 * covered) / total : 0 };
  });
  const covered = rows.reduce((n, r) => n + r.covered, 0);
  const total = rows.reduce((n, r) => n + r.total, 0);
  rows.push({ dir: 'all three', files: rows.reduce((n, r) => n + r.files, 0), covered, total, percent: total ? (100 * covered) / total : 0 });
  return rows;
}

const rows = summarize(JSON.parse(readFileSync(join(out, 'merged', 'kcov-merged', 'coverage.json'), 'utf8')));
const lines = ['| Directory | Files | Lines covered | Coverage |', '| --- | ---: | ---: | ---: |'];
for (const r of rows) lines.push(`| ${r.dir} | ${r.files} | ${r.covered} / ${r.total} | ${r.percent.toFixed(1)}% |`);
const table = `### Line coverage (target 85%)\n\n${lines.join('\n')}\n`;
console.log(table);
if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, table);

const low = rows.slice(0, dirs.length).filter((r) => r.percent < (min ?? 0));
if (min !== null && low.length > 0) {
  console.error(`below ${min}%: ${low.map((r) => r.dir).join(', ')}`);
  process.exit(1);
}
