# Acceptance: how to verify Relcore 0.2.2

This page is the shortest reproducible path from a clean clone to the same numbers claimed in the README.

## Requirements

- MoonBit CLI `0.1.20261021` or a compatible newer build
- Node.js 22+
- Windows native builds need MSVC Build Tools; the CI matrix installs it. wasm-gc / js do not.

## 1. Static checks

```sh
moon check --target all --deny-warn
moon fmt --check
```

Expected: both finish with no warnings. `--deny-warn` is deliberate; a warning is a failure.

## 2. Unit tests

```sh
moon test --deny-warn
moon test --target js --deny-warn
```

Expected: `Total tests: 25, passed: 25, failed: 0` on both backends.

Coverage includes: CSV inference/BOM/quotes, null keys, sort null placement, empty input, union type widening, join key mismatch, aggregate, distinct, JSON plan, tagged-node contracts, join evidence, plan comparison, error paths.

## 3. CLI integration

```sh
node scripts/build.mjs
node --test tests/cli.test.mjs
python tests/oracle.py
```

Expected: `# pass 6`, `# fail 0`, and `oracle: 4 checks passed (fanout, composite-key, revenue, compare)`.

The SQLite oracle is an independent engine check: it computes the same fanout,
composite-key, aggregation and comparison numbers with `sqlite3`, then compares
them to the CLI output.

## 4. Library consumer (no JSON, no CLI)

```sh
moon run examples/embed --deny-warn
```

Expected: `embed rows=3 violations=0`. This package imports `JQ-ai-nb/relcore`
and calls `read_csv` / `execute` / `check_contracts` directly.

## 5. Three end-to-end examples

```sh
node bin/relcore.mjs examples/plan-tenant-fanout.json --md   # exit 1
node bin/relcore.mjs examples/plan-tenant-safe.json          # exit 0
node bin/relcore.mjs examples/plan-revenue-by-segment.json   # exit 0
node bin/relcore.mjs examples/compare-tenant-keys.json       # exit 1
```

Expected:

| Example | Exit | Key output |
|---|---|---|
| tenant-fanout | 1 | `max_fanout=2`, `many_to_many`, `left_rows=3,4`, `right_rows=2,3` |
| tenant-safe | 0 | `rows=5`, `max_fanout=1` |
| revenue-by-segment | 0 | `rows=2`, columns `segment/revenue/orders` |
| compare-tenant-keys | 1 | `retained=5`, `lost=2`, `gained=0`, first divergence at index 2 |

Exit codes: `0` contracts pass, `1` contract violation, `2` invalid input / I/O.

## 6. Published package smoke test

In a clean directory with a clean `MOON_HOME` (no cached `JQ-ai-nb/relcore`):

```sh
moon new relcore-smoke
cd relcore-smoke
moon add JQ-ai-nb/relcore@0.2.2
```

`moon.pkg`:

```text
import {
  "JQ-ai-nb/relcore" @relcore,
}
```

`main.mbt`:

```moonbit
fn main {
  let batch = @relcore.read_csv("id,v\n1,2\n2,3\n", "t") catch {
    _ => abort("parse failed")
  }
  println(@relcore.batch_rows(batch))
}
```

```sh
moon run . --target wasm-gc
```

Expected: `2`.

## 7. CI matrix

`.github/workflows/ci.yml` runs on Ubuntu, macOS and Windows:

- `moon check --target all --deny-warn`
- `moon test --target all --deny-warn`
- `moon build --target all --deny-warn`
- `moon fmt --check`
- `moon run examples/embed --deny-warn`
- `node scripts/build.mjs`
- `node --test tests/cli.test.mjs`
- `python tests/oracle.py`

## 8. What is not covered yet

- Optimizer (predicate/projection pushdown): plans execute as written.
- Budget / chunked execution: whole batch is materialized.
- Arrow IPC / Parquet: only CSV / JSONL.
- Cross-node minimal witness search: join evidence covers `max_fanout > 1`.
- Browser workbench: only the JS build + CLI today.

These are tracked in Issues #1–#3 and `docs/ROADMAP.md`; they are not claimed as done.
