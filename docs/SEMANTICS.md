# Semantics

This page fixes the behaviour that the tests rely on. If a change makes one of
these statements false, it is a breaking change and needs a version bump.

## Values and types

- Closed scalar set: `null`, `bool`, `int64`, `float64`, `text`.
- `int64` and `float64` are distinct. A join key never matches across types.
- CSV inference: all-empty → null; all bool → bool; all integer → int64; all
  integer-or-float → float64; otherwise text.
- JSONL keeps the JSON number spelling: an integer token becomes `int64`, a
  fractional/exponent token becomes `float64`, a missing field becomes `null`.

## NULL

| Context | Behaviour |
|---|---|
| Arithmetic (`+ - * / %`) | Any `null` operand → `null` |
| Comparison (`= != < <= > >=`) | Any `null` operand → `null` |
| `and` / `or` | Three-valued: `false and null = false`, `true or null = true`, otherwise `null` |
| `filter` | Only `true` keeps a row; `false` and `null` are dropped |
| Join key | A row with any `null` key component never matches; it is counted as unmatched |
| `unique` / `no_null` | `unique` ignores `null`; `no_null` reports it |
| `count(col)` | Counts non-null values |
| `sum` / `min` / `max` / `avg` | Ignore `null`; all-null group → `null` |
| `sort` | `null` is always last, ascending or descending |

## Joins

- Kinds: `inner`, `left`, `right`, `full`, `semi`, `anti`.
- Keys are positional: `left_keys[i]` pairs with `right_keys[i]`; lengths must match.
- Duplicate column names from the right side get a `_right` suffix.
- `semi` / `anti` output only left-side columns.

## Cardinality shapes

`join_cardinality` is computed from the keys that actually participate in the
join, not from a declared primary key:

| `left_unique` | `right_unique` | Shape |
|---|---|---|
| true | true | `one_to_one` |
| true | false | `one_to_many` |
| false | true | `many_to_one` |
| false | false | `many_to_many` |

`max_fanout` is the maximum number of right rows matched by a single left row.
A violation with `max_fanout > 1` carries `left_rows` / `right_rows` — a minimal
2×2 (or 1×2) reproduction. Rows with `null` keys are excluded from uniqueness
counts, so they do not change the shape; they still appear in `unmatched_left`.

## Aggregate

- `count` without `input` counts rows; with `input` it counts non-null values.
- `sum` returns int64 when every non-null input is int64, float64 if any input is float64.
- `avg` always returns float64 (or `null` for an empty/all-null group).
- Output order for `aggregate` follows first appearance of the key.

## Union

- Column names must match positionally.
- Types are merged: `int64 + float64 → float64`; `null + T → T`; any other
  mismatch is an error. Values are cast to the merged type.

## Plan comparison

- `first_divergence` aligns stages by `stats` index. Plans with different shapes
  can misalign; the index is reported so the caller can inspect both stage lists.
- `row_diff` compares whole-row multisets: `retained` is the sum of the smaller
  count per row identity; `lost` / `gained` are the remainders.
- If the schemas differ, `schema_match=false`, `comparable=false`, and
  `row_diff=null`. No fake diff is produced.

## Known gaps (tracked)

- `null` keys are excluded from cardinality shapes; whether that is the right
  product decision is open (Issue #2).
- No budget parameter yet; a plan is executed in one in-memory batch (Issue #1).
- `compare` aligns by index, not by tagged node (documented above).
