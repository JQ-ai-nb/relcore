// A tiny reproducible benchmark: join + aggregate over generated CSV data.
//
//   node scripts/build.mjs && node bench/bench.mjs [orders] [customers] [runs]
//
// Everything is generated in memory, so the numbers do not depend on disk or
// network. Each run includes JSON plan parsing, CSV parsing and execution.
import {run} from '../dist/relcore.js';

const orders = Number(process.argv[2] ?? 20000);
const customers = Number(process.argv[3] ?? 5000);
const runs = Number(process.argv[4] ?? 5);

const segments = ['enterprise', 'smb', 'consumer'];

const orderLines = ['order_id,customer,tenant,qty,amount'];
for (let i = 0; i < orders; i++) {
  const customer = i % customers;
  const tenant = `t${customer % 7}`;
  const amount = (10 + (i % 90) + (i % 100) / 100).toFixed(2);
  orderLines.push(`A-${i},${customer},${tenant},${1 + (i % 5)},${amount}`);
}

const customerLines = ['customer,tenant,name,segment'];
for (let i = 0; i < customers; i++) {
  const tenant = `t${i % 7}`;
  customerLines.push(`${i},${tenant},c${i},${segments[i % 3]}`);
}

const document = JSON.stringify({
  version: 1,
  sources: {
    orders: {format: 'csv', data: orderLines.join('\n') + '\n'},
    customers: {format: 'csv', data: customerLines.join('\n') + '\n'},
  },
  plan: {
    op: 'limit',
    n: 10,
    input: {
      op: 'sort',
      keys: [{column: 'revenue', desc: true}],
      input: {
        op: 'aggregate',
        keys: ['segment'],
        aggs: [
          {func: 'sum', input: 'amount', as: 'revenue'},
          {func: 'count', input: 'order_id', as: 'orders'},
        ],
        input: {
          op: 'join',
          kind: 'inner',
          left: {op: 'scan', source: 'orders'},
          right: {op: 'scan', source: 'customers'},
          left_keys: ['customer', 'tenant'],
          right_keys: ['customer', 'tenant'],
        },
      },
    },
  },
  contracts: [{kind: 'unique', columns: ['segment']}],
});

const samples = [];
for (let i = 0; i < runs; i++) {
  const start = process.hrtime.bigint();
  const report = JSON.parse(run(document));
  const end = process.hrtime.bigint();
  if (!report.ok) throw new Error(`benchmark plan failed: ${JSON.stringify(report)}`);
  samples.push(Number(end - start) / 1e6);
}
samples.sort((a, b) => a - b);
const median = samples[Math.floor(samples.length / 2)];
console.log(
  JSON.stringify(
    {
      orders,
      customers,
      runs,
      median_ms: Number(median.toFixed(1)),
      min_ms: Number(samples[0].toFixed(1)),
      max_ms: Number(samples.at(-1).toFixed(1)),
      rows: JSON.parse(run(document)).rows,
      join_rows: JSON.parse(run(document)).stats.find((s) => s.op.startsWith('join')).rows_out,
    },
    null,
    2,
  ),
);
