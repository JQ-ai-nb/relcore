# Roadmap

目标是**在 2026-10-31 前交付一个可运行、可测试、可解释的执行内核**，而不是把 pandas 的全部功能塞进七天。下面的排序按“对通用性的贡献 / 风险”排列，时间不够时从后往前砍。

## 本期（10/24 – 10/31）

| 日期 | 交付 | 验收方式 |
|---|---|---|
| 10/24 | 数据模型、CSV/JSONL、9 个算子、4 类契约、节点契约、join 证据、计划对比、预算、CLI、28 项测试 | `moon test`、示例退出码、对比/预算示例 |
| 10/25 | 保守优化器（常量折叠、filter/limit 下推）、`explain()` 树形输出（已完成） | 4 项优化器测试 + CLI explain |
| 10/26 | 优化器：谓词下推、投影裁剪、limit 下推、常量折叠 | 优化前后结果逐字节一致 |
| 10/27 | 预算参数 `Budget { max_rows, max_memory }`；分块 `Batch` 读取 | 超预算行为测试（拒绝/降级） |
| 10/28 | Arrow IPC 只读适配（可选依赖）+ 浏览器工作台 | 用 PyArrow 生成的 `.arrow` 跑通同一计划 |
| 10/29 | DuckDB / Polars 差分 oracle（golden fixtures，不在 CI 里跑 Python） | 50 组固定输入的结果对照 |
| 10/30 | README / docs / CI / Mooncakes 发布 / 申报书 | 新环境 `moon add` 后跑通 demo |
| 10/31 | 提交与 buffer | 报名回执、群昵称 |

## 本期明确不做

- 完整 SQL 方言与优化器代价模型；
- 窗口函数、pivot、UDF；
- 分布式执行、spill、持久化；
- Parquet 写、Delta/Iceberg；
- 浏览器可视化编辑器。

## 验收之后（11 月+）

1. **`explain_violation`**：把前作 JoinWitness 的三行最小反例算法移植到任意计划节点。
2. **typed column buffers**：用 `Array[Int64]` / `Array[Double]` / `Bytes` 替代 `Array[Value]`，降低内存。
3. **Arrow / Parquet 双向适配**：让 Relcore 能接 pandas/Polars/DuckDB 的导出。
4. **SQL AST 前端**：消费 `moonbit-community/sqlparser`，把 `SELECT ... JOIN ... GROUP BY` 编译成 plan IR。
5. **预算与 spill**：外部排序、分区聚合、宿主 spill 回调。
6. **浏览器工作台**：WASM 版本 + 计划可视化 + 违规行高亮。

## 非目标

Relcore 不打算成为数据库、调度器或 BI 产品。它的长期定位是**可被其他 MoonBit 数据工具依赖的执行内核**：输入是计划，输出是结果 + 基数 + 契约 + 证据。
