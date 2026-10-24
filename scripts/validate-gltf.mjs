// Validates glTF/GLB files with the Khronos glTF validator; exits 1 on any
// error or warning. Usage: node validate-gltf.mjs <node_modules dir> <file>...
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';

const [modules, ...files] = process.argv.slice(2);
const validator = createRequire(modules + '/')('gltf-validator');
let failed = false;
for (const file of files) {
  const report = await validator.validateBytes(new Uint8Array(readFileSync(file)), { uri: file });
  const { numErrors, numWarnings, messages } = report.issues;
  console.log(`${file}: ${numErrors} errors, ${numWarnings} warnings`);
  for (const m of messages) if (m.severity <= 1) console.log(`  ${m.code} ${m.pointer ?? ''}: ${m.message}`);
  if (numErrors > 0 || numWarnings > 0) failed = true;
}
process.exit(failed ? 1 : 0);
