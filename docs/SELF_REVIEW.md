# Self-review log（五轮自查）

> 每轮都做了“检查 → 发现问题 → 修改 → 复测”。这里记录每轮的实际发现和改动，作为可追溯的迭代证据。

## Round 1 — 重叠与定位（对照驳回与生态侧证）

**检查项**
- 用评审会用的关键词（check / audit / validate / dataframe / sql / join / contract）在 Mooncakes 上模拟搜索；
- 检查 README 首屏、`moon.mod` 的 `keywords` 与 `description`；
- 检查是否主动披露与 MoonFrame / moonsql / mbitsv / JoinWitness 的关系。

**发现的问题**
1. `moon.mod` 的 `keywords` 含 `dataframe`——会让评审搜 `dataframe` 时把 Relcore 和 MoonFrame 并列，放大“又一个 DataFrame”的印象。
2. `description` 写了 “budgeted execution”，但预算还没实现，属于过度承诺。
3. README 没有显式写“不是 DataFrame / 不是 SQL 引擎 / 不是单表校验器”。

**修改**
1. `keywords` 改为 `["relational", "query-engine", "plan-ir", "execution", "csv"]`。
2. `description` 去掉 “budgeted”。
3. README 新增“先看边界”一节，明确三个“不是”。
4. 新增 `docs/OVERLAP_AUDIT.md`：四道闸门 → 逐项切割 → 提交归属自查。

## Round 2 — 正确性与边界

**检查项**
- join 的 NULL 键语义、键数量不匹配、空输入；
- sort 的 NULL 排序；
- union 的列类型不一致；
- limit 的负数；
- CSV 引号闭合后的非法字符；
- JSONL 缺字段、未知 tag 契约、对比时 schema 不一致。

**发现的问题**
1. `limit` 负数会产出 0 行而不是报错；
2. CSV `"x"y` 这种闭合引号后跟文本的情况被静默接受（不严格）；
3. `union` 对 int 列和 float 列直接报错，无法合并（真实数据常见）；
4. `join` 左右键数量不一致没有显式校验。

**修改**
1. `limit` 加 `n < 0` 拒绝；
2. CSV 闭合引号后只允许逗号/换行/回车/结尾，否则报错；
3. `union` 增加类型提升（int + float → float；null + T → T），用 `cast_value` 统一；
4. `join` 校验左右键数量相等；
5. 新增 10 项边界测试（null join、sort nulls、空 CSV、union 提升、CSV 引号、负数 limit、键数量、JSONL 缺字段、schema 不一致、未知 tag）。

**复测**：`moon test` 从 15 项升到 25 项，全部通过。

## Round 3 — 质量门禁

**检查项**：格式化、全后端类型检查、全后端测试、CLI 集成测试、代码量。

**发现的问题**
- 无；本轮全部通过。

**结果**
- `moon fmt --check` 通过；
- `moon check --target all --deny-warn` 通过；
- `moon test --deny-warn` 25 项通过；`moon test --target js --deny-warn` 25 项通过；
- `node --test tests/cli.test.mjs` 6 项通过；
- 2,800 行 MoonBit（含测试）。

## Round 4 — 文档与事实一致性

**检查项**：README / CHANGELOG / docs 里的测试数、代码行数、能力声明是否与代码一致。

**发现的问题**
1. 多处仍写“12 项测试 / 15 项测试 / 2,324 行 / 2,300 行”的旧数字；
2. `ROADMAP` 的 10/24 行没写节点契约、计划对比；
3. 示例报告是旧版，没有 `left_rows` / `right_rows`。

**修改**
1. 统一为 25 项 MoonBit 测试 + 6 项 CLI 测试、2,800 行；
2. `ROADMAP`、`APPLICATION_NOTES`、`APPLICATION_TEMPLATE`、`OVERLAP_AUDIT`、复盘报告同步更新；
3. 重新生成 `deliverables/02` 示例报告，新增 `deliverables/03` 计划对比输出；
4. 复盘报告追加“本轮追加的四项”。

## Round 5 — 提交就绪

**检查项**：格式、许可证、第三方声明、CI、提交归属、README 首屏。

**发现的问题**
1. 申报书缺“固定标题 + 一页约束”的模板（已有项目因格式被拒）；
2. 提交归属没有书面化的检查清单。

**修改**
1. 新增 `work/relcore-prep/APPLICATION_TEMPLATE.md`（不随仓库发布）：六个小节、字数上限、格式自查清单；
2. `docs/OVERLAP_AUDIT.md` 增加“提交归属自查”一节；
3. `LICENSE`、`THIRD_PARTY_NOTICES.md`、`.github/workflows/ci.yml` 补齐。

---

## 复测命令（每次改动后都跑）

```sh
cd relcore
moon fmt --check
moon check --target all --deny-warn
moon test --deny-warn
moon test --target js --deny-warn
node scripts/build.mjs
node --test tests/cli.test.mjs
```

## Round 6 — 语义回归：全空组 `sum`

**检查**：构造全 null 列的聚合，确认 `sum` 的返回。
**发现**：`sum` 全空返回 `0`，与 `min/max/avg` 的 `null` 不一致。
**修改**：`sum` 增加 `seen` 标记，全空返回 `VNull`；新增测试。26 项测试通过。

## Round 7 — 库复用证明

**检查**：README 说“可被依赖”，但此前只有 CLI/JSON 入口被实际使用。
**发现**：缺少一个不经过 JSON/CLI 的消费者。
**修改**：新增 `examples/embed`，直接 `read_csv` / `execute` / `check_contracts`；CI 增加 `moon run examples/embed`，输出 `rows=3 violations=0`。

## Round 8 — 独立引擎对照

**检查**：所有断言都来自 Relcore 自己的测试，可能“自洽但错误”。
**发现**：没有独立 oracle。
**修改**：新增 `tests/oracle.py`，用 Python 标准库 `sqlite3` 独立计算 fanout、组合键、聚合、对比四组数字，并与 CLI 输出比对；CI 增加 `python tests/oracle.py`。

## Round 9 — 对比的 schema 边界

**检查**：两条计划 schema 不一致时，`compare` 仍然计算 `retained/lost/gained`。
**发现**：跨 schema 的行身份不可比，输出是“假 diff”。
**修改**：增加 `comparable` 字段；schema 不一致时 `row_diff=null`。新增断言。

## Round 10 — 发布与声明一致性

**检查**：README / ACCEPTANCE / CHANGELOG / 远端 tag 的版本与测试数。
**发现**：0.2.1 与 0.2.2 交替，部分文档仍写 25 项 / 2,800 行。
**修改**：统一为 26 项 MoonBit + 6 项 CLI + 4 组 SQLite 校验、2,900 行；发布 0.2.2；CI main #10 绿。

## Final sweep（10 轮之后）

- README 增加“60 秒评审路径”，评审不必先读完全文。
- PII 扫描：仓库内无姓名、邮箱、绝对路径、token；提交作者均为 `JQ-ai-nb`。
- `0.2.2` 已发布；CI main #11 与 tag #12 均为 success。
- 仓库外发现一个他人 Mooncakes 凭据备份文件（文件名含其他账号），未读取、未删除；已在交付说明中提示用户确认后清理。
