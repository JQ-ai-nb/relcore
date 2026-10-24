# Changelog

## 0.2.0-preview — 2026-10-24

从 `JoinWitness` 的单点等值关联预检，重构为通用关系执行内核。

### Added

- 列式 `Batch` / `Schema` / `Field` / `DataType` / `Value` 数据模型。
- CSV（RFC-4180 风格，含 BOM 处理与类型推断）与 JSONL 读取。
- 逻辑计划：`scan` / `filter` / `project` / `join` / `aggregate` / `sort` / `limit` / `union` / `distinct`。
- 六种 join：`inner` / `left` / `right` / `full` / `semi` / `anti`，支持组合键与 SQL NULL 语义。
- 表达式树：列引用、字面量、算术、比较、三值逻辑、`is_null`、`cast`、`lower` / `upper` / `len` / `coalesce`。
- 每节点 `NodeStat`：`rows_in` / `rows_out` / `matched_left` / `unmatched_left` / `unmatched_right` / `max_fanout` / `left_unique` / `right_unique` / `worst_key`。
- 四类契约：`row_count` / `unique` / `no_null` / `join_cardinality`；可挂在根或 `tag` 节点。
- 节点级契约：`tag` + `frames`，支持在任意阶段检查。
- join 证据：最坏键、左右行号、fanout；`left_rows` / `right_rows` 是最小复现的行指针。
- 计划对比：`compare` 报出第一个分叉阶段与 retained/lost/gained。
- 违约 witness：节点、形态、最坏键、行号。
- JSON 计划格式与 JSON / Markdown 报告；CLI 退出码 0/1/2。
- JS 导出层与 Node CLI；25 项 MoonBit 测试 + 6 项 CLI 测试。

### Changed

- 输入从私有 JSON 协议扩展为 CSV / JSONL / 内存 `Batch`。
- 契约作用域从“一次 join”扩展为“任意计划结果 + 每个 join 节点”。
- 类型从 `text/int32/bool/null` 扩展为 `text/int64/float64/bool/null`。

### Known limitations

- 无优化器；计划按书写顺序执行。
- 无分块与 spill；受宿主内存限制。
- 无 Arrow / Parquet 适配（路线图）。
- 无最小反例搜索（路线图）。
