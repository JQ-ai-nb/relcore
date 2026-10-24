# Architecture

```text
frontends        MoonBit API        JSON plan        CLI (Node)        JS/WASM
                     │                  │               │                │
                     └──────────────────┴───────────────┴────────────────┘
                                        ↓
logical plan     Scan · Filter · Project · Join · Aggregate · Sort · Limit · Union · Distinct
                                        ↓
executor         column-major Batch → operator → Batch + NodeStat
                                        ↓
contracts        row_count · unique · no_null · join_cardinality
                                        ↓
evidence         violation.code · violation.witness[] · stage table
```

## 数据模型

`Batch` 是列式批次：

```moonbit
pub(all) struct Batch {
  schema : Schema
  columns : Array[Column]
}
```

不变式：

1. `columns.length() == schema.fields.length()`；
2. 所有列等长；
3. 列 `i` 的值类型与 `schema.fields[i].dtype` 兼容；
4. `null` 允许出现在任何列（当前版本没有 `non-nullable` 约束）。

`Value` 是封闭标量集合：`VNull / VBool / VInt(Int64) / VFloat(Double) / VText`。封闭集合让执行、比较、序列化都可判定，不需要运行时类型分发。

## 为什么是列式

- 算子按列处理，投影与聚合只触碰需要的列；
- 契约按列检查（唯一、非空）不需要重组整行；
- 后续接入 Arrow IPC / 分块执行时，列式布局是自然边界；
- 当前实现仍用 `Array[Value]` 存储，**不是**紧凑的 typed buffer；这是 v0.2 preview 的已知取舍，见路线图。

## 执行

`execute(plan)` 是递归下降：

- `Scan` 直接返回批次；
- `Filter` 逐行求值谓词，只保留 `true`；
- `Project` 逐列求值表达式，按首行推断输出类型；
- `Join` 构建右侧哈希桶，左表探测，输出 `(left_index, right_index)` 对；
- `Aggregate` 用规范化键分组，再对每组计算聚合；
- `Sort` 预取键列，按 `(column, desc)` 字典序排序索引，再 `take`；
- `Limit` 取前 n 个索引；
- `Union` 校验 schema 后按列拼接；
- `Distinct` 按规范化键保留首次出现。

每个节点返回一个 `NodeStat`：

```moonbit
pub(all) struct NodeStat {
  op : String
  rows_in : Int
  rows_out : Int
  matched_left : Int
  unmatched_left : Int
  unmatched_right : Int
  max_fanout : Int
  left_unique : Bool
  right_unique : Bool
  worst_key : String?
  worst_count : Int
}
```

`stats` 按后序追加，因此最后一个元素总是根节点。

## Join 语义

键编码是长度前缀的规范化值：

```text
3:i:9|6:t:acme|
```

- 类型标签避免 `"1"` 与 `1` 碰撞；
- 长度前缀避免分隔符注入；
- 任一键为 `null` 时整行不参与匹配（SQL 等值关联语义）；
- 右侧桶保存所有匹配行号，因此 `max_fanout` 是精确值，不是估计。

四种形态由两侧键唯一性推导：

| left_unique | right_unique | shape |
|---|---|---|
| true | true | `one_to_one` |
| true | false | `one_to_many` |
| false | true | `many_to_one` |
| false | false | `many_to_many` |

`left_unique` / `right_unique` 的统计范围是**参与本次 join 的键**，不是整表主键声明。

## 节点级契约（`tag` + `frames`）

根契约只能回答“最终结果对不对”。真实管道更常见的问题是“中间某一步已经错了，但最后又被过滤/聚合掩盖了”。因此执行结果额外携带 `frames`：

```moonbit
pub(all) struct Frame {
  label : String
  batch : Batch
}
```

`tag` 节点把当前批次挂到 `frames` 上，契约用 `at` 指向它：

```json
{ "op": "tag", "name": "after_join", "input": { ... } }
{ "kind": "row_count", "at": "after_join", "min": 1, "max": 3 }
```

`check_node_contracts` 先按 label 找批次，找不到就返回 `UNKNOWN_NODE`，不会静默通过。这样同一套契约语言可以挂在任意阶段，而不是为每个阶段写专用检查。

## 契约与证据

契约在执行后检查，输入是结果批次与完整 `stats`：

- `row_count`：直接比较结果行数；
- `unique`：按列规范化键分组，记录前 5 组重复行的行号；
- `no_null`：扫描列，记录前 5 个空值行号；
- `join_cardinality`：遍历所有 `join:*` 节点，比较形态；违约时带上 `worst_key`、`max_fanout`、未匹配计数。

证据是**数据级**的，不是日志级的：每条 witness 都能在输入里定位到具体行/键。

join 违约时，`NodeStat.evidence` 保存最小行指针：

```json
{
  "key": "3:i:9|",
  "fanout": 2,
  "left_rows": [3, 4],
  "right_rows": [2, 3]
}
```

这对应“2 条左行 × 2 条右行 = 4 个匹配对”的最小复现：去掉任意一条左行或右行，`many_to_many` 就不再成立。当前版本只对 `max_fanout > 1` 生成行指针；跨节点的最小反例搜索（`explain_violation`）在路线图里。

## 计划对比

`compare` 执行两条计划，按 `stats` 下标对齐：

1. 找第一个 `rows_out` 不同的阶段 → `first_divergence`；
2. 按整行多重集算 `retained` / `lost` / `gained`；
3. schema 不一致时 `schema_match=false`，不强行比较行。

它不是“结果 diff”，而是**逐阶段归因**：先定位分叉点，再量化分叉后的行变化。

## 复杂度

| 算子 | 时间 | 额外内存 |
|---|---|---|
| scan / filter / project | O(rows × cols) | O(rows) |
| join | O(n + m) 期望 | O(n + m) |
| aggregate | O(rows) 期望 | O(groups) |
| sort | O(rows log rows) | O(rows) |
| union / distinct | O(rows) | O(rows) |

所有算子都在内存内完成；当前版本没有 spill，也没有预算拒绝。`Budget` 参数与分块执行是下一步。

## 已知取舍

1. **`Array[Value]` 不是紧凑列存**：实现简单、跨后端一致，但内存开销高于 typed buffer。
2. **无优化器**：计划按书写顺序执行，谓词/投影下推尚未实现。
3. **无 chunk**：整个批次一次物化，大输入会受宿主内存限制。
4. **join 键编码是字符串**：正确性优先，后续可换成 typed hash。
5. **`count` / `sum` 在空组上的行为**：当前返回 0 或 `null`，与 SQL 的细节差异记录在测试里。
6. **`frames` 会保留中间批次**：节点级契约需要它，但会增加内存；后续用引用计数/裁剪控制。
7. **计划对比按阶段下标对齐**：两条计划结构不同（比如一边多一个 filter）时，下标会错位；后续按节点标签对齐。
