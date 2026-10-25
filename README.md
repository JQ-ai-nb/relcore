# Relcore

[![CI](https://github.com/JQ-ai-nb/relcore/actions/workflows/ci.yml/badge.svg)](https://github.com/JQ-ai-nb/relcore/actions/workflows/ci.yml)
[![Mooncakes](https://img.shields.io/badge/mooncakes-0.2.4-blue)](https://mooncakes.io/docs/JQ-ai-nb/relcore)

**把任意表管道编译成可解释、可预算、可验证的执行计划。**

Relcore 是 MoonBit 的**通用关系执行内核**：CSV / JSONL 进来，用同一套 plan IR 表达 `scan → filter → join → aggregate → sort → limit`，执行后每个节点都有精确基数；契约违约时给出可复核的最小行证据。

> **v0.2.4 preview**：从 `JoinWitness`（单点等值关联预检）扩展而来。v0.1 只回答“这一对表 join 会不会扇出”；v0.2 回答“这条管道在哪一步、因为哪个键、扇出了多少行”。  
> 对初审意见的逐条回应（改了什么、证据在哪、什么还没做）见 [docs/REJECTION_RESPONSE.md](docs/REJECTION_RESPONSE.md)。

---

## 60 秒评审路径

1. 读下面三行边界：**不是 DataFrame 门面、不是 SQL 引擎、不是单表校验器**。
2. 跑 `node bin/relcore.mjs examples/plan-tenant-fanout.json --md`，看到 `max_fanout=2` 和 `left_rows` / `right_rows`；再跑 `node bin/relcore.mjs examples/plan-budget.json`，看到结构化 `BUDGET_EXCEEDED`。
3. 跑 `node bin/relcore.mjs examples/compare-tenant-keys.json`，看到 `first_divergence` 与 `retained/lost/gained`。
4. 想看优化后的计划：`node bin/relcore.mjs examples/plan-revenue-by-segment.json --explain`。
5. 想看实现分层：`docs/ARCHITECTURE.md`；想看与现有项目的关系：`docs/OVERLAP_AUDIT.md`；想看逐条回应：`docs/REJECTION_RESPONSE.md`。

---

## 先看边界：它不是另外三个东西

| 它不是 | 为什么 |
|---|---|
| **不是 DataFrame 门面** | 不提供链式 `df.filter().group_by()` API；门面可以建在 Relcore 之上，Relcore 只做执行层 |
| **不是 SQL 引擎** | 不实现 SQL 方言、不做解析器；入口是 plan IR，未来可由 SQL AST 生成 |
| **不是单表校验器** | 不做规则市场、不做 schema 迁移；契约挂在执行计划的结果与 join 节点上 |

这三句话很重要：MoonBit 生态里已经有 MoonFrame（DataFrame）、moonsql（SQL）、mbitsv（单表质量）、moon-data-contract（schema 治理）。**Relcore 的差异在“执行层 + 契约/证据”，不在“再做一个门面”。**

---

## 为什么需要执行层

真实的数据事故通常不是“算不出来”，而是“算出来了但不对”：

- join 键漏了 `tenant`，行数从 5 悄悄变成 7；
- 管道重构后总行数没变，但实际匹配的行已经换了一批；
- 聚合前多了一层 join，金额翻倍，但报表只显示“总数”。

pandas/Polars 的 `validate=` 只在调用点报错；DuckDB 的 `EXPLAIN` 给的是估计值；单表校验器看不到 join 之后的事。Relcore 把这三件事放到同一层：

1. **计划**：管道长什么样；
2. **基数**：每一步实际多少行；
3. **证据**：错了在哪、因为哪个键、哪几行。

---

## 10 秒示例

### 作为库

```moonbit
let orders = @relcore.read_csv(orders_text, "orders")
let customers = @relcore.read_csv(customers_text, "customers")

let result = @relcore.execute(
  @relcore.Join(
    @relcore.Scan(orders),
    @relcore.Scan(customers),
    ["customer", "tenant"],
    ["customer", "tenant"],
    @relcore.Inner,
  ),
)

let violations = @relcore.check_contracts(result.batch, result.stats, [
  @relcore.JoinCardinality(["many_to_one"]),
])
```

`result.stats` 按执行顺序记录每个节点的 `rows_in / rows_out / max_fanout / cardinality / evidence`。

### 作为 CLI

```sh
node bin/relcore.mjs examples/plan-tenant-fanout.json --md
```

```text
# Relcore report

- rows: 7
- contracts: **fail**

## Plan stages

| stage | rows in | rows out | fanout | cardinality |
| --- | --- | --- | --- | --- |
| scan | 5 | 5 | 0 | - |
| scan | 4 | 4 | 0 | - |
| join:inner | 9 | 7 | 2 | many_to_many |

## Violations

- **JOIN_CARDINALITY**: join cardinality many_to_many is outside the allowed set
  - `worst_key=3:i:9|`
  - `left_rows=3,4`
  - `right_rows=2,3`
```

同一份数据，把关联键换成 `customer + tenant`，`fanout` 降为 1，契约通过。

### 计划对比：从哪一步开始不一样

```sh
node bin/relcore.mjs examples/compare-tenant-keys.json
```

```json
{
  "ok": false,
  "baseline_rows": 7,
  "candidate_rows": 5,
  "row_diff": { "retained": 5, "lost": 2, "gained": 0 },
  "first_divergence": {
    "index": 2,
    "baseline_op": "join:inner",
    "candidate_op": "join:inner",
    "baseline_rows": 7,
    "candidate_rows": 5
  }
}
```

这不是“结果 diff”，是**逐阶段归因**：先告诉你第 2 步 join 分叉，再告诉你分叉后保留/丢失/新增了多少行。

---

## 能力面

| 层 | 已实现（v0.2 preview） | 计划中 |
|---|---|---|
| 数据模型 | `Schema` / `Field` / `DataType` / `Column` / `Batch`（列式） | 分块（chunk）与字典编码 |
| 类型 | `null` / `bool` / `int64` / `float64` / `text` | decimal / date / time |
| 输入 | CSV、JSONL、内存 `Batch` | Arrow IPC、Parquet |
| 算子 | `scan` `filter` `project` `join`(inner/left/right/full/semi/anti) `aggregate` `sort` `limit` `union` `distinct` | `with_columns`、窗口、explode |
| 计划 | 逻辑计划 IR、JSON 序列化、`tag` 节点、`explain()` 树形输出 | join 谓词拆分、投影裁剪 |
| 优化 | 常量折叠、filter 下推 project/sort、limit 下推 project | join 谓词拆分、投影裁剪、代价模型 |
| 契约 | `row_count` / `unique` / `no_null` / `join_cardinality`；可挂在根或 `tag` 节点 | `foreign_key` / `accepted_values` |
| 证据 | 最坏键、左右行号、fanout、未匹配数 | 自动最小化到最小行集 |
| 对比 | 两条计划逐阶段对比 + retained/lost/gained | 多候选对比、回归基线库 |
| 接口 | MoonBit 库、JSON 计划、Node CLI、JS 构建 | 浏览器工作台、SQL AST 适配 |

---

## 契约语义

| 契约 | 参数 | 检查位置 | 违约证据 |
|---|---|---|---|
| `row_count` | `min`, `max` | 根或 `tag` 节点 | 实际行数 |
| `unique` | `columns` | 根或 `tag` 节点 | 重复键 + 前 5 组行号 |
| `no_null` | `columns` | 根或 `tag` 节点 | 列名 + 前 5 个空值行号 |
| `join_cardinality` | `allowed` | 每个 join 节点 | 节点、形态、最坏键、fanout、左右行号 |

`join_cardinality` 的形态由两侧键的唯一性推导：

| 左键唯一 | 右键唯一 | 形态 |
|---|---|---|
| 是 | 是 | `one_to_one` |
| 是 | 否 | `one_to_many` |
| 否 | 是 | `many_to_one` |
| 否 | 否 | `many_to_many` |

形态描述的是**键的基数关系**，不是业务语义。`orders → customers` 通常是 `many_to_one`，即使 `max_fanout = 1`。完整的 NULL、join、聚合、union、compare 语义见 [docs/SEMANTICS.md](docs/SEMANTICS.md)。

---

## 通用性矩阵

| 维度 | JoinWitness v0.1 | Relcore v0.2 |
|---|---|---|
| 输入格式 | 1（私有 JSON） | 3（CSV / JSONL / 内存） |
| 类型 | 4（text/int32/bool/null） | 5（+ int64/float64） |
| 算子 | 1（equi-join） | 9，可任意组合 |
| 计划 | 无 | 逻辑计划 IR + JSON + `tag` |
| 契约作用域 | 仅 join | 任意 `tag` 节点 + 每个 join 节点 |
| 规模 | 硬上限 1 万行/表 | 单进程内存；`max_rows` / `max_join_rows` 可配，超限 `BUDGET_EXCEEDED` |
| 调用方式 | CLI | 库 / CLI / JS |
| 生态对接 | 无 | CSV / JSONL（Arrow 在路线图） |
| 计划对比 | 无 | 逐阶段分叉 + 行对差异 |

---

## 与现有项目的关系（主动披露）

| 项目 | 它做什么 | 重叠 | Relcore 的差异 |
|---|---|---|---|
| [MoonFrame](https://github.com/ihb2032/MoonFrame) | Polars 风格 DataFrame 门面 | 列式表、join、group_by、sort | 不提供门面；提供 plan IR、节点契约、基数形态、witness、计划对比 |
| [moonsql](https://github.com/uiwcvb/moonsql) | 嵌入式关系 SQL 引擎 | 关系算子执行 | 不做 SQL 方言；plan IR 是数据，可被 SQL 前端消费 |
| [mbitsv](https://github.com/CJR-zhang/mbitsv) | CSV/TSV 校验、profile、单表 diff | CSV、校验、diff | 契约挂在执行计划与 join 节点上；证据是基数与行对 |
| [moon-data-contract](https://github.com/lyjttio/moon-data-contract) | schema 治理、迁移规划 | “contract” 一词 | 元数据层 vs 执行层，不是同一层的东西 |
| [JoinWitness](https://github.com/JQ-ai-nb/JoinWitness) | 单算子预检（作者前作） | join、基数、证据 | **本期扩展**：9 算子、3 输入、节点契约、计划对比；旧仓库保留为原型 |

完整的逐项切割、关键词自查、提交归属检查见 [docs/OVERLAP_AUDIT.md](docs/OVERLAP_AUDIT.md)。

**一句话：别人做“表怎么存、怎么读、怎么写”，Relcore 做“表怎么算、算得对不对、错了在哪”。**

---

## 项目结构

```
relcore/
├── types.mbt        # DataType / Value / Schema / Batch
├── csv.mbt          # RFC-4180 风格 CSV 读取与类型推断
├── expr.mbt         # 表达式树与三值逻辑
├── exec.mbt         # 逻辑计划 + 算子执行 + 节点统计 + 证据
├── contract.mbt     # 契约检查、节点契约、witness
├── wire.mbt         # JSON 计划/对比解析、JSONL 读取
├── api.mbt          # run / run_markdown / compare
├── api/             # JS 导出层
├── bin/relcore.mjs  # Node CLI
└── examples/        # 可复现计划与对比
```

---

## 质量

```sh
moon check --target all --deny-warn
moon test --deny-warn                 # 32 项
moon test --target js --deny-warn     # 32 项
moon fmt --check
moon run examples/embed --deny-warn   # 库 API 消费者
node scripts/build.mjs
node --test tests/cli.test.mjs        # 8 项
python tests/oracle.py                # 4 组 SQLite 差分校验
```

- 32 项 MoonBit 测试：CSV 推断、filter/project、inner/left join、aggregate、union/distinct、JSON 计划、节点契约、join 证据、计划对比、错误路径；
- 8 项 CLI 测试：示例退出码、Markdown、缺失文件、计划对比、预算错误、explain；
- 4 组 SQLite 差分校验：fanout、组合键、按 segment 聚合、计划对比；
- `examples/embed` 用公开 MoonBit API（不经过 JSON/CLI）跑同一管道，输出 `rows=3 violations=0`；
- 所有后端 `moon check --deny-warn` 通过；`moon test` 在 wasm-gc 与 js 上通过；
- 确定性输出：同一输入产生逐字节相同的 JSON。

---

## 边界（明确不做）

- **不是数据库**：不做存储、事务、索引、恢复、权限。
- **不是分布式引擎**：单进程、内存内执行；跨机调度不在范围内。
- **不是完整 SQL**：当前入口是 plan IR；SQL 方言适配是后续工作。
- **不验证业务语义**：契约只检查结构、基数、唯一性、空值；键是否“有意义”由使用者判断。
- **当前规模**：预算通过 `max_rows` / `max_join_rows` 显式配置；受宿主内存限制，尚未实现 spill。

---

## 路线图（十月）

| 日期 | 目标 |
|---|---|
| 10/24 | 内核骨架、CSV/JSONL、9 算子、4 契约、节点契约、计划对比、CLI（已完成） |
| 10/25 | 表达式补全、保守优化器（常量折叠/filter/limit 下推）、`explain()`（已完成） |
| 10/26 | 分块执行；预算参数已完成（`BUDGET_EXCEEDED`） |
| 10/27 | Arrow IPC 只读适配、浏览器工作台 |
| 10/28 | DuckDB/Polars 差分 oracle、基准 |
| 10/29 | CI 矩阵、API 文档、发布 Mooncakes |
| 10/30 | 申报书与提交 |
| 10/31 | buffer |

---

## 许可证

MIT。原创实现；概念参考 PostgreSQL、Polars、pandas、DuckDB 的公开语义。AI 辅助开发已披露，维护者理解并对最终质量负责。见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
