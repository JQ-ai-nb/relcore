# Response to the initial review

初审意见原文（JoinWitness，2026-10）：

> 本次申报暂不通过。项目具备一定实用价值，关联基数预检、来源行证据及候选键差分功能也较完整，但当前通用性受到明显限制。建议参考 pandas、Polars、……

这份文档逐条对照：**哪一条认了、改了什么、证据在哪、还有什么没做**。

## 1. “关联基数预检……较完整”

**认。** 这是 v0.1 的核心，v0.2 不砍，反而从“一次 join”提升为“每个 join 节点”。

| v0.1 | v0.2 |
|---|---|
| 一次等值关联的基数预检 | 每个 `join:*` 节点都产出 `NodeStat`：`rows_in/out`、`matched_left`、`unmatched_left/right`、`max_fanout`、`left_unique/right_unique` |
| 只有通过/不通过 | 额外给出基数形态：`one_to_one` / `one_to_many` / `many_to_one` / `many_to_many` |
| 需要单独调用预检 | 契约 `join_cardinality` 挂在执行结果上，和管道一起跑 |

证据：`examples/plan-tenant-fanout.json` 输出 `max_fanout=2`、`many_to_many`，退出码 1。

## 2. “来源行证据”

**认，并加了一层。** v0.2 的 witness 不再只有“最坏键”，而是带最小行指针：

```json
{
  "key": "3:i:9|",
  "fanout": 2,
  "left_rows": [3, 4],
  "right_rows": [2, 3]
}
```

这对应“2 条左行 × 2 条右行”的最小复现：去掉任意一条左行或右行，`many_to_many` 就不再成立。

另外新增 `tag` 计划节点 + `frames`：契约可以用 `"at": "after_join"` 定向检查中间结果，而不是只检查最终结果。找不到 tag 时返回 `UNKNOWN_NODE`，不会静默通过。

证据：`deliverables/02` 的 Markdown 报告里能看到 `left_rows=3,4` / `right_rows=2,3`。

## 3. “候选键差分”

**认，并升级为计划对比。** v0.1 只能比较两套候选键的行对集合；v0.2 的 `compare` 比较两条完整计划：

- `first_divergence`：第一个 `rows_out` 不同的阶段（index、op、两边行数）；
- `row_diff`：`retained` / `lost` / `gained`（整行多重集）；
- `schema_match`：schema 不一致时明确标 false。

证据：`examples/compare-tenant-keys.json` 输出

```json
{
  "baseline_rows": 7,
  "candidate_rows": 5,
  "row_diff": { "retained": 5, "lost": 2, "gained": 0 },
  "first_divergence": { "index": 2, "baseline_rows": 7, "candidate_rows": 5 }
}
```

## 4. “当前通用性受到明显限制”

**这是核心否决点，也是 v0.2 改动最大的地方。**

| 维度 | v0.1 | v0.2 |
|---|---|---|
| 输入 | 1 种私有 JSON | CSV / JSONL / 内存 `Batch` |
| 类型 | text/int32/bool/null | text/int64/float64/bool/null |
| 算子 | 1 个 equi-join | 9 个：scan/filter/project/join(6 种)/aggregate/sort/limit/union/distinct |
| 计划 | 无 | 逻辑计划 IR + JSON + `tag` |
| 契约作用域 | 仅 join | 任意 `tag` 节点 + 每个 join 节点 |
| 调用方式 | CLI | MoonBit 库 / JSON 计划 / CLI / JS |
| 规模 | 硬上限 1 万行/表写进产品身份 | 单进程内存；预算可配（`max_rows` / `max_join_rows`），超限返回 `BUDGET_EXCEEDED`，不再把上限当身份 |
| 对比 | 无 | 逐阶段分叉 + 行对差异 |

代码从 2,022 行增长到 3,000 行；公开 API 从 `inspect/counterexample` 扩展到 `execute/check_node_contracts/compare`。

## 5. “建议参考 pandas、Polars、……”

**认，但参考的是抽象层次，不是克隆。**

- pandas：`merge(validate=)` 的基数契约思路；
- Polars：表达式树 / 惰性计划 / 谓词下推的分层；
- DuckDB：逻辑计划 → 物理计划 → 执行的分层，以及 `EXPLAIN` 的可解释性；
- PostgreSQL：join 多重性与 NULL 比较语义。

没有复制任何一家的源码。与 MoonBit 生态内项目的逐项切割见 [OVERLAP_AUDIT.md](OVERLAP_AUDIT.md)。

## 6. 还没改完的部分（不装）

| 项 | 状态 | 说明 |
|---|---|---|
| 优化器（谓词/投影下推） | 未做 | 计划按书写顺序执行；路线图 10/25 |
| 分块执行 | 未做 | 预算参数已完成；当前仍是单批次物化，分块在路线图 10/26 |
| Arrow IPC / Parquet | 未做 | 只有 CSV / JSONL；路线图 10/27 |
| 跨节点最小反例搜索 | 未做 | 当前只对 `max_fanout > 1` 给最小行指针；更一般的 `explain_violation` 在路线图 |
| SQL AST 前端 | 未做 | plan IR 是数据，未来可由 `sqlparser` AST 生成 |
| 浏览器工作台 | 未做 | 当前只有 JS 构建与 CLI |

**申报书里不要把这些写成已完成。** 评审更愿意看到“边界清楚 + 有路线图”，而不是“什么都做了”。

## 7. 与前作 JoinWitness 的关系

- JoinWitness 是**原型**：单算子、私有 JSON、硬上限；
- Relcore 是**扩展**：9 算子、3 输入、节点契约、计划对比、最小行证据；
- 旧仓库保留为语义与测试来源；没有复制其业务实现；
- 同一作者，MIT；AI 辅助开发已披露。

## 8. 复现

```sh
moon check --target all --deny-warn
moon test --deny-warn                 # 28 项
node scripts/build.mjs
node --test tests/cli.test.mjs        # 6 项
node bin/relcore.mjs examples/plan-tenant-fanout.json --md   # 退出 1
node bin/relcore.mjs examples/compare-tenant-keys.json       # 退出 1
```
