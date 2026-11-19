import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');

function run() {
  // 1. Validate recommendation-v0.1.json 20-fixture set (E6)
  const recFixtures = JSON.parse(
    fs.readFileSync(path.join(ROOT, 'docs/architecture/fixtures/recommendation-v0.1.json'), 'utf8')
  );
  assert.equal(recFixtures.cases.length, 20, 'recommendation-v0.1.json must contain 20 cases');
  const groups = { simple: 0, parallel: 0, capability: 0, safety: 0 };
  for (const c of recFixtures.cases) {
    assert.ok(c.group in groups, `Unexpected group ${c.group}`);
    groups[c.group] += 1;
    assert.ok(Array.isArray(c.required) && c.required.length > 0);
    assert.ok(Array.isArray(c.forbidden) && c.forbidden.length > 0);
  }
  assert.deepEqual(groups, { simple: 5, parallel: 5, capability: 5, safety: 5 });

  // 2. Validate real-tasks-v0.3.json fixed cases
  const realTasks = JSON.parse(
    fs.readFileSync(path.join(ROOT, 'docs/architecture/fixtures/real-tasks-v0.3.json'), 'utf8')
  );
  assert.deepEqual(
    realTasks.cases.map((c) => c.id),
    ['RWT-01', 'RWT-02']
  );

  // 3. Validate all OpenSpec directories imp-08..imp-22 and evidence docs exist
  const openspecDir = path.join(ROOT, 'openspec/changes');
  const openspecEntries = fs.readdirSync(openspecDir);
  for (let i = 8; i <= 22; i += 1) {
    const prefix = `imp-${String(i).padStart(2, '0')}-`;
    assert.ok(
      openspecEntries.some((name) => name.startsWith(prefix)),
      `Missing OpenSpec directory starting with ${prefix}`
    );
  }

  const docsDir = path.join(ROOT, 'docs');
  const docEntries = fs.readdirSync(docsDir);
  for (let i = 9; i <= 22; i += 1) {
    const prefix = `imp-${String(i).padStart(2, '0')}-`;
    assert.ok(
      docEntries.some((name) => name.startsWith(prefix)),
      `Missing docs evidence file starting with ${prefix}`
    );
  }

  // 4. Verify docs/imp-22-release-readiness.md contains all required IDs & honest BLOCKED phase gates
  const readiness = fs.readFileSync(path.join(ROOT, 'docs/imp-22-release-readiness.md'), 'utf8');
  assert.ok(readiness.includes('Phase 1 Gate: BLOCKED'), 'Phase 1 Gate must remain BLOCKED');
  assert.ok(readiness.includes('Phase 2 Gate: BLOCKED'), 'Phase 2 Gate must remain BLOCKED');
  assert.ok(!readiness.includes('Phase 1 Gate: PASS'), 'Must never claim Phase 1 Gate PASS');
  assert.ok(!readiness.includes('Phase 2 Gate: PASS'), 'Must never claim Phase 2 Gate PASS');

  const expectedIds = [];
  for (let i = 1; i <= 12; i += 1) expectedIds.push(`| R-${String(i).padStart(2, '0')} |`);
  for (let i = 1; i <= 23; i += 1) expectedIds.push(`| V-${String(i).padStart(2, '0')} |`);
  for (let i = 1; i <= 24; i += 1) expectedIds.push(`| X${String(i).padStart(2, '0')} |`);
  for (let i = 1; i <= 5; i += 1) expectedIds.push(`| A11Y-${String(i).padStart(2, '0')} |`);
  for (let i = 1; i <= 5; i += 1) expectedIds.push(`| PERF-${String(i).padStart(2, '0')} |`);
  for (let i = 1; i <= 7; i += 1) expectedIds.push(`| CP-${String(i).padStart(2, '0')} |`);

  const missing = expectedIds.filter((token) => !readiness.includes(token));
  assert.deepEqual(missing, [], `Missing traceability rows: ${missing.join(', ')}`);

  console.log(
    JSON.stringify(
      {
        ok: true,
        tracedIdsVerified: expectedIds.length,
        recommendationFixtures: recFixtures.cases.length,
        realTaskFixtures: realTasks.cases.map((c) => c.id),
        phase1Gate: 'BLOCKED',
        phase2Gate: 'BLOCKED',
      },
      null,
      2
    )
  );
}

run();
