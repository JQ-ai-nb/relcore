# Overlap audit：我们和谁像、哪里不像、为什么不是重复提交

> 写作原则：先承认重叠，再给出可核对的差异；不装作“没人做过”。

## 1. 初审在查的四道闸门（基于公开证据推断，非截图原文）

> 说明：申请人的驳回截图当前无法逐张读取（模型不支持图片输入）。下面的“四道闸门”是**根据可核对证据**（JoinWitness 的“通用性受限”驳回 + Mooncakes 上真实存在的 `WB-ai-nb/reviewproof-kit` 等“复审补证”工具）推断出来的，用于自检；拿到截图原文后校准。

| 闸门 | 自检要点 |
|---|---|
| 是否已有同类项目 | 先自己搜一遍，列出最近的 5 个项目并点名 |
| 是否披露重叠 | 在 README 和申报书里点名 + 说明扩展关系，不装作不存在 |
| 提交是否属于本人 | 所有 commit 用 JQ-ai-nb 身份；协作者单独说明；不导入他人历史 |
| 格式是否符合 | 严格按一页 Markdown 模板，固定小节标题 |

## 2. 关键词自查（评审会这样搜）

| 关键词 | Mooncakes 上会搜到什么 | 我们的关系 |
|---|---|---|
| `dataframe` | MoonFrame、pandas（早期） | **门面层**；我们不做门面 |
| `sql` | moonsql、sqlparser、sqlglot | **SQL 层**；我们不做方言，只做 plan IR |
| `join` | `cli/join`、`bobzhang/join`（coreutils 风格） | 它们是文本行 join；我们做类型化关系算子 |
| `validate` / `contract` | mbitsv、moon-data-contract、moon_schema_plan | 单表规则/契约；我们做执行期契约 + 基数 |
| `audit` / `check` | harborcheck、reviewproof-kit 等 | **我们不使用这些词做名字或首段** |
| `arrow` / `parquet` | shunge/arrow、mizchi/parquet | 存储格式；我们不实现格式 |
| `provenance` | medseal、moonflowgraph | 记录级来源；我们做 join 基数证据 |

**结论：`check`/`audit` 赛道已经非常拥挤，Relcore 的名字和首段都刻意避开这些词。**

## 3. 最近的五个项目：逐项切割

### 3.1 MoonFrame（`ihb2032/MoonFrame`，Apache-2.0）

- **它做什么**：Polars 风格的 DataFrame 门面；CSV/JSON/NDJSON；filter/select/sort/group_by/join；表达式引擎；lazy + 谓词下推；Markdown/HTML/Vega-Lite 导出。
- **重叠**：列式表、join、group_by、sort、CSV/JSONL。
- **它没有的**：
  - 没有公开的、可序列化的 plan IR（`Plan` 是构建器内部状态，不是数据）；
  - 没有计划节点级的契约（契约只能在结果上做断言）；
  - 没有 join 基数形态（`one_to_one` / `many_to_many`）和 `max_fanout` 精确统计；
  - 没有 witness（最坏键 + 左右行号）；
  - 没有两条计划的逐阶段对比。
- **我们的差异**：Relcore 不提供链式门面，只提供执行层；它的输出是“结果 + 每节点基数 + 契约 + 证据”。**如果 MoonFrame 愿意，Relcore 可以作为它的执行后端。**

### 3.2 moonsql（`uiwcvb/moonsql`）

- **它做什么**：纯 MoonBit 嵌入式关系 SQL 引擎。
- **重叠**：关系算子执行。
- **它没有的**：SQL 之外的 plan IR；执行契约；基数证据；跨计划对比。
- **我们的差异**：Relcore 不做 SQL 方言，不做解析器；plan IR 是数据，未来可由 SQL AST 生成。**两者是前后端关系，不是替代关系。**

### 3.3 mbitsv（`CJR-zhang/mbitsv`，MIT）

- **它做什么**：CSV/TSV 解析、schema 校验、profile、质量门禁、按 key 的两表 diff、Markdown 报告。
- **重叠**：CSV、校验、diff、报告。
- **它没有的**：关系算子执行；join 基数；plan IR；节点级契约；witness 行号。
- **我们的差异**：mbitsv 是**单表质量工具**；Relcore 是**执行引擎**，契约挂在计划结果与 join 节点上，证据是基数与行对。

### 3.4 moon-data-contract（`lyjttio/moon-data-contract`）

- **它做什么**：schema 治理、契约校验、演进审计、迁移规划。
- **重叠**：“contract”这个词。
- **它没有的**：执行计划；join；基数；运行时证据。
- **我们的差异**：它是**元数据层**，我们是**执行层**；两者的“契约”不是同一层的东西。

### 3.5 JoinWitness（`JQ-ai-nb/JoinWitness`，MIT，作者前作）

- **它做什么**：单次等值关联的有界预检；精确基数；三行反例；覆盖率契约；行对差分。
- **重叠**：join、基数、证据。这是**同源**，必须主动披露。
- **v0.2 的新增**：
  1. 从 1 个算子扩展到 9 个算子 + `tag`；
  2. 从私有 JSON 协议扩展到 CSV/JSONL/内存表 + 库 API；
  3. 从“只检查 join”扩展到“任意节点契约”（`tag` + `at`）；
  4. 新增逐阶段计划对比（`compare`）与最小行证据（`left_rows` / `right_rows`）。
- **我们的表述**：**“JoinWitness 是原型，Relcore 是扩展；旧仓库保留为测试与语义来源，不复制业务实现。”**

## 4. 为什么不会被判“拆分项目”

规则原文：“重复提交、拆分项目或仅做简单修改，不计入验收与奖励。”

我们的应对：

- **不是拆分**：v0.2 的能力面是 v0.1 的严格超集，且新增了 4 项结构性能力（plan IR、节点契约、计划对比、多格式）；
- **不是简单修改**：代码从 2,022 行增长到 3,300 行，新增 9 个算子、3 种输入、节点契约与计划对比两个新 API；
- **旧仓库不删除**：保留历史与测试，README 明确写“原型 → 扩展”；
- **申报书单列一段**：说明扩展关系、旧仓库地址、没有复制什么。

## 5. 提交归属自查

- [ ] 所有 commit 的 author/committer 都是 `JQ-ai-nb`；
- [ ] 没有把别人的 commit 历史导入新仓库；
- [ ] 如果与协作者共同开发，在 README 写清楚“谁做了什么”；
- [ ] AI 辅助开发已披露；
- [ ] 不使用他人的 GitHub 账号 push；
- [ ] 提交前 `git log --format='%an <%ae>' | sort -u` 检查。

## 6. 申报书里必须出现的一段（请用你自己的话改写）

> Relcore 与 MoonFrame、moonsql 不是替代关系。MoonFrame 提供 DataFrame 门面，moonsql 提供 SQL 前端，Relcore 提供两者都没有的执行层：可序列化的计划 IR、计划节点级契约、join 基数形态与最小行证据、两条计划的逐阶段对比。它也不是 mbitsv 那类单表质量工具：契约挂在执行结果和 join 节点上，证据是基数与行对。前作 JoinWitness 只覆盖单次等值关联；本期把它扩展为 9 个算子、3 种输入、节点级契约与计划对比，旧仓库保留为原型与测试来源。

## 7. 参考链接

- MoonFrame: https://github.com/ihb2032/MoonFrame
- moonsql: https://github.com/uiwcvb/moonsql
- mbitsv: https://github.com/CJR-zhang/mbitsv
- moon-data-contract: https://github.com/lyjttio/moon-data-contract
- JoinWitness: https://github.com/JQ-ai-nb/JoinWitness
- sqlparser: https://github.com/moonbit-community/sqlparser
- Arrow IPC: https://github.com/buildliming/MoonArrow
- Parquet: https://github.com/mizchi/parquet
