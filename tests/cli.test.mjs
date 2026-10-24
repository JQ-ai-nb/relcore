import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {resolve} from 'node:path';

const root=resolve(import.meta.dirname,'..');
const cli=resolve(root,'bin/relcore.mjs');

function run(plan,extra=[]){
  return spawnSync(process.execPath,[cli,resolve(root,'examples',plan),...extra],{encoding:'utf8'});
}

test('tenant fanout fails with a join cardinality witness',()=>{
  const result=run('plan-tenant-fanout.json');
  assert.equal(result.status,1);
  const report=JSON.parse(result.stdout);
  assert.equal(report.ok,false);
  const violation=report.violations.find(v=>v.code==='JOIN_CARDINALITY');
  assert.ok(violation);
  assert.equal(report.stats.at(-1).max_fanout,2);
});

test('composite key removes the fanout',()=>{
  const result=run('plan-tenant-safe.json');
  assert.equal(result.status,0);
  const report=JSON.parse(result.stdout);
  assert.equal(report.ok,true);
  assert.equal(report.rows,5);
});

test('aggregate pipeline passes row count and uniqueness contracts',()=>{
  const result=run('plan-revenue-by-segment.json');
  assert.equal(result.status,0);
  const report=JSON.parse(result.stdout);
  assert.equal(report.rows,2);
  assert.equal(report.columns[0],'segment:text');
});

test('markdown report includes stages and violations',()=>{
  const result=run('plan-tenant-fanout.json',['--md']);
  assert.equal(result.status,1);
  assert.match(result.stdout,/# Relcore report/);
  assert.match(result.stdout,/JOIN_CARDINALITY/);
});

test('missing plan is an IO error',()=>{
  const result=spawnSync(process.execPath,[cli,resolve(root,'examples','does-not-exist.json')],{encoding:'utf8'});
  assert.equal(result.status,2);
});


test('plan comparison reports the first diverging stage and row diff',()=>{
  const result=run('compare-tenant-keys.json');
  assert.equal(result.status,1);
  const report=JSON.parse(result.stdout);
  assert.equal(report.ok,false);
  assert.equal(report.row_diff.retained,5);
  assert.equal(report.row_diff.lost,2);
  assert.equal(report.first_divergence.index,2);
  assert.equal(report.first_divergence.baseline_rows,7);
  assert.equal(report.first_divergence.candidate_rows,5);
});
