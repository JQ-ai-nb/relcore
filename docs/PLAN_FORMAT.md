# Plan format (v1)

Relcore 的外部入口是一份 JSON 计划文档。库、CLI、JS 构建共用同一份格式，因此报告可以逐字节复现。

## 文档结构

```json
{
  "version": 1,
  "sources": {
    "orders": { "format": "csv", "data": "customer,qty\n7,1\n" },
    "events": { "format": "jsonl", "data": "{\"id\":1}\n" }
  },
  "plan": { "op": "scan", "source": "orders" },
  "contracts": [
    { "kind": "row_count", "min": 1, "max": 1000 }
  ]
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `version` | 否 | 目前只接受 `1`；缺省为 `1` |
| `sources` | 是 | 命名数据源；`format` 为 `csv` / `jsonl` / `ndjson`，`data` 为文本内容 |
| `plan` | 是 | 计划根节点 |
| `contracts` | 否 | 执行后检查的契约列表 |
| `budget` | 否 | `{ "max_rows": 1000, "max_join_rows": 5000 }`；`null` 或缺省表示不限 |

CLI 额外支持 `"path"` 代替 `"data"`：`bin/relcore.mjs` 会读取文件并注入 `data`，库本身不碰文件系统。

## 计划节点

### `scan`

```json
{ "op": "scan", "source": "orders" }
```

### `filter`

```json
{ "op": "filter", "predicate": { "op": ">", "left": { "col": "qty" }, "right": { "lit": 1 } }, "input": { ... } }
```

只保留谓词为 `true` 的行；`false` 与 `null` 都丢弃。

### `project`

```json
{ "op": "project", "columns": [{ "name": "id", "expr": { "col": "id" } }], "input": { ... } }
```

### `join`

```json
{
  "op": "join",
  "kind": "inner",
  "left": { ... },
  "right": { ... },
  "left_keys": ["customer", "tenant"],
  "right_keys": ["customer", "tenant"]
}
```

`kind`：`inner` / `left` / `right` / `full` / `semi` / `anti`。

- 组合键按位置配对，两侧键数量必须一致；
- 任一键值为 `null` 的行**不参与匹配**（SQL 等值关联语义）；
- 重名列自动加 `_right` 后缀；
- `semi` / `anti` 只输出左表列。

### `aggregate`

```json
{
  "op": "aggregate",
  "keys": ["segment"],
  "aggs": [
    { "func": "sum", "input": "amount", "as": "revenue" },
    { "func": "count", "input": "order_id", "as": "orders" }
  ],
  "input": { ... }
}
```

`func`：`count` / `sum` / `min` / `max` / `avg`。`count` 省略 `input` 时统计行数；其余聚合忽略 `null`。

### `sort`

```json
{ "op": "sort", "keys": [{ "column": "revenue", "desc": true }], "input": { ... } }
```

`null` 永远排在最后，`desc` 不改变这一规则。

### `limit`

```json
{ "op": "limit", "n": 10, "input": { ... } }
```

### `union`

```json
{ "op": "union", "left": { ... }, "right": { ... } }
```

要求两侧列名与类型完全一致，按行拼接，不去重。

### `distinct`

```json
{ "op": "distinct", "keys": ["customer"], "input": { ... } }
```

按键去重，保留第一次出现的行。

### `tag`

```json
{ "op": "tag", "name": "after_join", "input": { ... } }
```

给子计划打标签。标签会出现在 `stats`（`tag:after_join`）和 `frames` 里，契约可以用 `"at": "after_join"` 定向检查这个节点。`tag` 是“节点级契约”的挂载点，不是算子。

## 表达式

| 形式 | JSON | 说明 |
|---|---|---|
| 列引用 | `{ "col": "qty" }` | 未知列在执行期报错 |
| 字面量 | `{ "lit": 1 }` | 支持 null / bool / number / string |
| 二元运算 | `{ "op": "+", "left": ..., "right": ... }` | `+ - * / % = != < <= > >= and or` |
| 逻辑非 | `{ "op": "not", "arg": ... }` | |
| 空值判断 | `{ "op": "is_null", "arg": ... }` | |
| 类型转换 | `{ "op": "cast", "arg": ..., "dtype": "int64" }` | `null/bool/int64/float64/text` |
| 函数 | `{ "call": "lower", "args": [...] }` | `lower` / `upper` / `len` / `coalesce` |

NULL 语义：算术与比较遇到 `null` 返回 `null`；`and` / `or` 采用三值逻辑；`filter` 只接受 `true`。

## 预算

```json
{ "budget": { "max_rows": 1000, "max_join_rows": 5000 } }
```

- `max_rows`：每个算子输出行数上限；
- `max_join_rows`：join 输出行数上限，在构建输出列之前检查；
- 超限返回 `BUDGET_EXCEEDED`，退出码 2，不返回部分结果；
- 缺省或 `null` 表示不限，没有隐藏上限。

## 契约

| 契约 | JSON | 语义 |
|---|---|---|
| 行数 | `{ "kind": "row_count", "min": 1, "max": 10 }` | 最终结果行数在闭区间内 |
| 唯一 | `{ "kind": "unique", "columns": ["id"] }` | 指定列组合无重复（`null` 忽略） |
| 非空 | `{ "kind": "no_null", "columns": ["id"] }` | 指定列无 `null` |
| 关联基数 | `{ "kind": "join_cardinality", "allowed": ["one_to_one"] }` | 每个 join 节点形态在允许集合内 |

任意契约都可以加 `"at": "<tag 名>"`，把检查点从最终结果移到该 `tag` 节点：

```json
{ "kind": "row_count", "at": "after_join", "min": 1, "max": 3 }
```

找不到 tag 时返回 `UNKNOWN_NODE`，不会静默通过。

## 报告

```json
{
  "ok": true,
  "rows": 5,
  "columns": ["order_id:text", "customer:int64"],
  "stats": [
    { "op": "join:inner", "rows_in": 9, "rows_out": 7, "max_fanout": 2, "left_unique": false, "right_unique": false, "worst_key": "3:i:9|", "worst_count": 2, "evidence": { "key": "3:i:9|", "fanout": 2, "left_rows": [3, 4], "right_rows": [2, 3] } }
  ],
  "violations": []
}
```

违约时：

```json
{
  "ok": false,
  "violations": [
    {
      "code": "JOIN_CARDINALITY",
      "message": "join cardinality many_to_many is outside the allowed set",
      "witness": ["node=join:inner", "shape=many_to_many", "max_fanout=2", "worst_key=3:i:9|"]
    }
  ]
}
```

## 对比文档

`compare` 接收同一份 `sources` 和两条计划：

```json
{
  "version": 1,
  "sources": { "orders": { "format": "csv", "path": "orders.csv" } },
  "baseline": { "op": "scan", "source": "orders" },
  "candidate": { "op": "filter", "predicate": { ... }, "input": { "op": "scan", "source": "orders" } }
}
```

输出：

```json
{
  "ok": false,
  "schema_match": true,
  "comparable": true,
  "baseline_rows": 7,
  "candidate_rows": 5,
  "row_diff": { "retained": 5, "lost": 2, "gained": 0 },
  "first_divergence": {
    "index": 2,
    "baseline_op": "join:inner",
    "candidate_op": "join:inner",
    "baseline_rows": 7,
    "candidate_rows": 5
  },
  "baseline_stages": [ ... ],
  "candidate_stages": [ ... ]
}
```

`first_divergence` 按 `stats` 下标对齐，报告第一个 `rows_out` 不同的阶段；两条计划长度不同时，以较短的一条为基准，再报告长度差异。行对差异按整行多重集计算（`retained` = 两边计数的较小值之和）。

如果两条计划的 schema 不一致，`schema_match=false`、`comparable=false`，`row_diff` 为 `null`——不会拿两套不同的列硬算差异。

## 错误与退出码

| 退出码 | 含义 |
|---|---|
| `0` | 所有契约通过 |
| `1` | 执行成功，但存在契约违约 |
| `2` | 计划无效、源缺失、I/O 失败、预算超限 |

错误报告：

```json
{ "ok": false, "error": { "code": "INVALID_INPUT", "message": "unknown source: missing" } }
{ "ok": false, "error": { "code": "BUDGET_EXCEEDED", "message": "BUDGET_EXCEEDED: join produced 7 rows, limit 3" } }
```
