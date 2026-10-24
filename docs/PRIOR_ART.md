# Prior art and originality

初审意见要求“提升通用性，参考 pandas、Polars 等成熟数据工具”。这份文档把“参考什么、不重复什么、我们新增什么”写清楚，避免把 Relcore 误判为又一个 DataFrame 克隆。

## 参考的是抽象层次，不是代码

| 参考对象 | 我们借鉴的 | 我们没有做的 |
|---|---|---|
| pandas | `DataFrame` 的表抽象、`merge(validate=)` 的基数契约思路 | 不实现 Python 式链式 API，不做索引对齐 |
| Polars | 表达式树、惰性计划、谓词/投影下推的分层 | 不做完整 DataFrame 门面，不移植 Rust 代码 |
| DuckDB | 逻辑计划 → 物理计划 → 向量化执行的分层；`EXPLAIN` 的可解释性 | 不做 SQL 数据库、不做存储/事务 |
| PostgreSQL | 等值关联、外连接、NULL 比较语义 | 不做 SQL 方言、不做优化器代价模型 |
| dbt tests | 把“数据契约”放进 CI 的产品形态 | 不做单表规则市场，不做调度 |

## MoonBit 生态里的相邻项目

| 项目 | 定位 | 与 Relcore 的边界 |
|---|---|---|
| `ihb2032/MoonFrame` | Polars 风格 DataFrame：CSV/JSON/NDJSON、表达式、lazy、group_by、join | 门面层。Relcore 是执行层 + 契约层；门面可以复用执行层 |
| `uiwcvb/moonsql` | 纯 MoonBit 嵌入式关系 SQL 引擎 | SQL 前端。Relcore 先做 plan IR，SQL AST 适配在路线图 |
| `moonbit-community/sqlparser` | 多方言 SQL lexer/parser/AST | 语法层。Relcore 消费 AST，不重复解析 |
| `bobzhang/sqlglot` | SQL 解析、转译、优化 | 语法/转译层。Relcore 不做方言转译 |
| `shunge/arrow` | Arrow IPC stream/file 读写，PyArrow 互操作 | 存储格式。Relcore 计划只读适配，不做格式实现 |
| `mizchi/parquet` | Parquet 读写 | 存储格式。不在本期范围 |
| `CJR-zhang/mbitsv` | CSV/TSV 解析、校验、profile、按 key diff | 单表质量工具。Relcore 做跨算子的执行契约与 join 基数 |
| `lyjttio/moon-data-contract` | schema 治理、契约、迁移规划 | 元数据层。Relcore 不做 schema 迁移 |
| `LuoYunxin1/moonnormal` | 关系模式规范化、分解验证 | 模式设计层。Relcore 不做范式判定 |
| `JQ-ai-nb/JoinWitness` | 单算子等值关联预检、最小反例（作者前作） | 单点工具。Relcore 把证据能力提升为引擎级横切能力 |

## 我们的新增点

1. **计划 IR 是公开数据**：`Plan` 可构造、可序列化、可被其他前端（JSON、未来的 SQL AST）生成。
2. **契约挂在执行结果上，而不是调用点上**：`row_count` / `unique` / `no_null` 检查最终结果，`join_cardinality` 检查每个 join 节点。
3. **精确基数而不是估计**：`max_fanout`、`matched_left`、`unmatched_left/right` 来自真实数据，不是统计推断。
4. **证据可复核**：违约 witness 带节点、形态、最坏键、行号；不是一句异常消息。
5. **列式 + 算子组合**：同一套 `Batch` 上组合 9 个算子，而不是为每个检查写一条专用路径。

## 原创性与许可证

- Relcore 的 MoonBit 实现为原创，MIT；没有复制 MoonFrame、moonsql、Polars、DuckDB 的源码。
- 概念上继承作者前作 `JoinWitness` 的关联基数、证据与预算门控思路；前作同样为 MIT，且未在本仓库中复制其业务实现。
- AI 辅助开发已披露；维护者负责目标、路径与最终质量。
- 所有示例数据为合成数据，不包含真实客户或个人信息。

## 外部参考

- PostgreSQL: [Table expressions](https://www.postgresql.org/docs/current/queries-table-expressions.html), [Comparison functions](https://www.postgresql.org/docs/current/functions-comparison.html)
- Polars: [Expressions](https://docs.pola.rs/user-guide/expressions/), [Lazy API](https://docs.pola.rs/user-guide/lazy/)
- pandas: [`merge` validation](https://pandas.pydata.org/docs/reference/api/pandas.DataFrame.merge.html)
- DuckDB: [`EXPLAIN`](https://duckdb.org/docs/sql/statements/explain)
