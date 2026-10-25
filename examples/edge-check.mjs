// Scenario 3: local / edge validation.
//
// The same plan file that the CLI runs from a path is mounted here with inline
// CSV data, so nothing needs to be uploaded. The report contains aggregates and
// violations only; source rows are never echoed back.
//
//   node scripts/build.mjs && node examples/edge-check.mjs
//
// No network APIs are imported on purpose: `fetch`, `http`, `https` and `net`
// never appear in this file.
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {run} from '../dist/relcore.js';

const planUrl = new URL('./plan-edge-check.json', import.meta.url);
const sourceUrl = new URL('./orders.csv', import.meta.url);

const csv = await readFile(sourceUrl, 'utf8');
const document = JSON.parse(await readFile(planUrl, 'utf8'));

// Mount the local file as inline data instead of a path.
document.sources = {orders: {format: 'csv', data: csv}};

const report = JSON.parse(run(JSON.stringify(document)));
const payload = JSON.stringify(report);

// Every order id in the source; none of them may appear in the report.
const orderIds = csv
  .replace(/^\uFEFF/, '')
  .trim()
  .split('\n')
  .slice(1)
  .map((line) => line.split(',')[0]);

const leaked = orderIds.filter((id) => payload.includes(id));

const summary = {
  ok: report.ok,
  rows: report.rows,
  columns: report.columns,
  stages: report.stats.map((s) => `${s.op}:${s.rows_in}->${s.rows_out}`),
  violations: report.violations,
  source_sha256: createHash('sha256').update(csv).digest('hex'),
  source_rows_in_payload: leaked.length > 0,
};

console.log(JSON.stringify(summary, null, 2));
process.exitCode = report.ok && leaked.length === 0 ? 0 : 1;
