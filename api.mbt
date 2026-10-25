///|
fn stat_json(stat : NodeStat) -> Json {
  let fields : Map[String, Json] = Map([])
  fields["op"] = Json::string(stat.op)
  fields["rows_in"] = Json::number(stat.rows_in.to_double())
  fields["rows_out"] = Json::number(stat.rows_out.to_double())
  fields["matched_left"] = Json::number(stat.matched_left.to_double())
  fields["unmatched_left"] = Json::number(stat.unmatched_left.to_double())
  fields["unmatched_right"] = Json::number(stat.unmatched_right.to_double())
  fields["max_fanout"] = Json::number(stat.max_fanout.to_double())
  fields["left_unique"] = Json::boolean(stat.left_unique)
  fields["right_unique"] = Json::boolean(stat.right_unique)
  fields["worst_key"] = match stat.worst_key {
    Some(key) => Json::string(key)
    None => Json::null()
  }
  fields["worst_count"] = Json::number(stat.worst_count.to_double())
  fields["evidence"] = match stat.evidence {
    Some(evidence) => {
      let rows = []
      for row in evidence.left_rows {
        rows.push(Json::number(row.to_double()))
      }
      let right = []
      for row in evidence.right_rows {
        right.push(Json::number(row.to_double()))
      }
      let item : Map[String, Json] = Map([])
      item["key"] = Json::string(evidence.key)
      item["fanout"] = Json::number(evidence.fanout.to_double())
      item["left_rows"] = @json.to_json(rows)
      item["right_rows"] = @json.to_json(right)
      Json::object(item)
    }
    None => Json::null()
  }
  Json::object(fields)
}

///|
fn violation_json(violation : Violation) -> Json {
  let fields : Map[String, Json] = Map([])
  fields["code"] = Json::string(violation.code)
  fields["message"] = Json::string(violation.message)
  let witness = []
  for line in violation.witness {
    witness.push(Json::string(line))
  }
  fields["witness"] = @json.to_json(witness)
  Json::object(fields)
}

///|
fn report_json(
  batch : Batch,
  stats : Array[NodeStat],
  violations : Array[Violation],
) -> String {
  let rows = batch_rows(batch)
  let fields : Map[String, Json] = Map([])
  fields["ok"] = Json::boolean(violations.length() == 0)
  fields["rows"] = Json::number(rows.to_double())
  let columns = []
  for field in batch.schema.fields {
    columns.push(Json::string(field.name + ":" + dtype_name(field.dtype)))
  }
  fields["columns"] = @json.to_json(columns)
  fields["stats"] = @json.to_json(stats.map(stat_json))
  fields["violations"] = @json.to_json(violations.map(violation_json))
  Json::object(fields).stringify()
}

///|
fn error_json(message : String) -> String {
  let error : Map[String, Json] = Map([])
  error["code"] = Json::string(
    if message.has_prefix("BUDGET_EXCEEDED:") {
      "BUDGET_EXCEEDED"
    } else {
      "INVALID_INPUT"
    },
  )
  error["message"] = Json::string(message)
  let fields : Map[String, Json] = Map([])
  fields["ok"] = Json::boolean(false)
  fields["error"] = Json::object(error)
  Json::object(fields).stringify()
}

///|
fn optional_int(
  fields : Map[String, Json],
  name : String,
) -> Int32? raise EngineError {
  match fields.get(name) {
    Some(Null) | None => None
    Some(value) => Some(j_int(value, name))
  }
}

///|
fn read_budget(fields : Map[String, Json]) -> Budget raise EngineError {
  match fields.get("budget") {
    Some(value) => {
      let budget = j_obj(value, "budget")
      {
        max_rows: optional_int(budget, "max_rows"),
        max_join_rows: optional_int(budget, "max_join_rows"),
      }
    }
    None => unlimited_budget()
  }
}

///|
fn should_optimize(fields : Map[String, Json]) -> Bool raise EngineError {
  match fields.get("optimize") {
    Some(value) => j_bool(value, "optimize")
    None => true
  }
}

///|
fn read_sources(value : Json) -> Map[String, Batch] raise EngineError {
  let fields = j_obj(value, "sources")
  let out : Map[String, Batch] = Map([])
  for name, spec in fields {
    let source = j_obj(spec, "source " + name)
    let format = j_str(required(source, "format"), "source format")
    let data = j_str(required(source, "data"), "source data")
    let batch = match format {
      "csv" =>
        read_csv(data, name) catch {
          EngineError(message) => fail("source " + name + ": " + message)
        }
      "jsonl" | "ndjson" => read_jsonl(data, name)
      _ => fail("unsupported source format: " + format)
    }
    out[name] = batch
  }
  out
}

///|
fn evaluate(
  source : String,
) -> (Batch, Array[NodeStat], Array[Violation]) raise EngineError {
  let document = @json.parse(
    source,
    max_nesting_depth=64,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    _ => fail("plan document is not valid JSON")
  }
  let fields = j_obj(document, "plan document")
  let version = match fields.get("version") {
    Some(value) => j_int(value, "version")
    None => 1
  }
  if version != 1 {
    fail("unsupported plan version: " + version.to_string())
  }
  let sources = read_sources(required(fields, "sources"))
  let plan = read_plan(required(fields, "plan"), sources)
  let plan = if should_optimize(fields) { optimize(plan) } else { plan }
  let budget = read_budget(fields)
  let contracts = match fields.get("contracts") {
    Some(value) => j_array(value, "contracts").map(read_node_contract)
    None => []
  }
  let result = execute_with_budget(plan, budget)
  let violations = check_node_contracts(result, contracts)
  (result.batch, result.stats, violations)
}

///|
fn run_inner(source : String) -> String raise EngineError {
  let (batch, stats, violations) = evaluate(source)
  report_json(batch, stats, violations)
}

///|
fn row_identity(batch : Batch, row : Int32) -> String {
  let mut out = ""
  for i, _field in batch.schema.fields {
    let key = value_key(batch.columns[i].values[row])
    out = out + key.length().to_string() + ":" + key + "|"
  }
  out
}

///|
fn row_counts(batch : Batch) -> Map[String, Int32] {
  let counts : Map[String, Int32] = Map([])
  for row in 0..<batch_rows(batch) {
    let key = row_identity(batch, row)
    counts[key] = match counts.get(key) {
      Some(n) => n + 1
      None => 1
    }
  }
  counts
}

///|
fn schema_names(batch : Batch) -> Array[String] {
  let names = []
  for field in batch.schema.fields {
    names.push(field.name + ":" + dtype_name(field.dtype))
  }
  names
}

///|
fn stage_json(stat : NodeStat) -> Json {
  let fields : Map[String, Json] = Map([])
  fields["op"] = Json::string(stat.op)
  fields["rows_in"] = Json::number(stat.rows_in.to_double())
  fields["rows_out"] = Json::number(stat.rows_out.to_double())
  fields["max_fanout"] = Json::number(stat.max_fanout.to_double())
  Json::object(fields)
}

///|
fn compare_inner(source : String) -> String raise EngineError {
  let document = @json.parse(
    source,
    max_nesting_depth=64,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    _ => fail("plan document is not valid JSON")
  }
  let fields = j_obj(document, "compare document")
  let sources = read_sources(required(fields, "sources"))
  let budget = read_budget(fields)
  let optimize_enabled = should_optimize(fields)
  let baseline_plan = read_plan(required(fields, "baseline"), sources)
  let candidate_plan = read_plan(required(fields, "candidate"), sources)
  let baseline_plan = if optimize_enabled {
    optimize(baseline_plan)
  } else {
    baseline_plan
  }
  let candidate_plan = if optimize_enabled {
    optimize(candidate_plan)
  } else {
    candidate_plan
  }
  let baseline = execute_with_budget(baseline_plan, budget)
  let candidate = execute_with_budget(candidate_plan, budget)
  let base_names = schema_names(baseline.batch)
  let cand_names = schema_names(candidate.batch)
  let schema_match = base_names == cand_names
  let base_rows = batch_rows(baseline.batch)
  let cand_rows = batch_rows(candidate.batch)
  let base_counts = row_counts(baseline.batch)
  let cand_counts = row_counts(candidate.batch)
  let mut retained = 0
  for key, count in base_counts {
    let other = match cand_counts.get(key) {
      Some(n) => n
      None => 0
    }
    retained = retained + (if count < other { count } else { other })
  }
  let lost = base_rows - retained
  let gained = cand_rows - retained
  let mut first : Json? = None
  let limit = if baseline.stats.length() < candidate.stats.length() {
    baseline.stats.length()
  } else {
    candidate.stats.length()
  }
  for i in 0..<limit {
    let b = baseline.stats[i]
    let c = candidate.stats[i]
    if first is None && b.rows_out != c.rows_out {
      let item : Map[String, Json] = Map([])
      item["index"] = Json::number(i.to_double())
      item["baseline_op"] = Json::string(b.op)
      item["candidate_op"] = Json::string(c.op)
      item["baseline_rows"] = Json::number(b.rows_out.to_double())
      item["candidate_rows"] = Json::number(c.rows_out.to_double())
      first = Some(Json::object(item))
    }
  }
  if first is None && baseline.stats.length() != candidate.stats.length() {
    let item : Map[String, Json] = Map([])
    item["index"] = Json::number(limit.to_double())
    item["baseline_op"] = Json::string("end")
    item["candidate_op"] = Json::string("end")
    item["baseline_rows"] = Json::number(baseline.stats.length().to_double())
    item["candidate_rows"] = Json::number(candidate.stats.length().to_double())
    first = Some(Json::object(item))
  }
  let out : Map[String, Json] = Map([])
  out["ok"] = Json::boolean(schema_match && lost == 0 && gained == 0)
  out["schema_match"] = Json::boolean(schema_match)
  out["comparable"] = Json::boolean(schema_match)
  out["baseline_rows"] = Json::number(base_rows.to_double())
  out["candidate_rows"] = Json::number(cand_rows.to_double())
  out["row_diff"] = if schema_match {
    let row_diff : Map[String, Json] = Map([])
    row_diff["retained"] = Json::number(retained.to_double())
    row_diff["lost"] = Json::number(lost.to_double())
    row_diff["gained"] = Json::number(gained.to_double())
    Json::object(row_diff)
  } else {
    // Row identity is not comparable across schemas; do not report a fake diff.
    Json::null()
  }
  out["first_divergence"] = match first {
    Some(value) => value
    None => Json::null()
  }
  out["baseline_stages"] = @json.to_json(baseline.stats.map(stage_json))
  out["candidate_stages"] = @json.to_json(candidate.stats.map(stage_json))
  Json::object(out).stringify()
}

///|
/// Compare two plans over the same sources. Reports the first stage where row
/// counts diverge and the retained/lost/gained final rows.
pub fn compare(source : String) -> String {
  compare_inner(source) catch {
    EngineError(message) => error_json(message)
  }
}

///|
fn explain_inner(source : String) -> String raise EngineError {
  let document = @json.parse(
    source,
    max_nesting_depth=64,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    _ => fail("plan document is not valid JSON")
  }
  let fields = j_obj(document, "plan document")
  let sources = read_sources(required(fields, "sources"))
  let plan = read_plan(required(fields, "plan"), sources)
  let plan = if should_optimize(fields) { optimize(plan) } else { plan }
  plan_to_string(plan)
}

///|
/// Show the optimized logical plan without executing it.
pub fn explain(source : String) -> String {
  explain_inner(source) catch {
    EngineError(message) => "error: " + message
  }
}

///|
/// Execute a JSON plan document and return a JSON report. This is the stable
/// text boundary used by the CLI, the browser workbench and integration tests.
pub fn run(source : String) -> String {
  run_inner(source) catch {
    EngineError(message) => error_json(message)
  }
}

///|
fn cell_markdown(value : Value) -> String {
  match value {
    VNull => "NULL"
    _ => value_text(value)
  }
}

///|
fn render_markdown(
  batch : Batch,
  stats : Array[NodeStat],
  violations : Array[Violation],
) -> String {
  let mut out = "# Relcore report\n\n"
  out = out + "- rows: " + batch_rows(batch).to_string() + "\n"
  out = out +
    "- contracts: **" +
    (if violations.length() == 0 { "pass" } else { "fail" }) +
    "**\n\n"
  out = out + "## Plan stages\n\n"
  out = out +
    "| stage | rows in | rows out | fanout | cardinality |\n| --- | --- | --- | --- | --- |\n"
  for stat in stats {
    let cardinality = if stat.op.has_prefix("join:") {
      cardinality_shape(stat)
    } else {
      "-"
    }
    out = out +
      "| " +
      stat.op +
      " | " +
      stat.rows_in.to_string() +
      " | " +
      stat.rows_out.to_string() +
      " | " +
      stat.max_fanout.to_string() +
      " | " +
      cardinality +
      " |\n"
  }
  if violations.length() > 0 {
    out = out + "\n## Violations\n\n"
    for violation in violations {
      out = out + "- **" + violation.code + "**: " + violation.message + "\n"
      for line in violation.witness {
        out = out + "  - `" + line + "`\n"
      }
    }
  }
  out = out + "\n## Result (first 10 rows)\n\n"
  out = out +
    "| " +
    batch.schema.fields.map(fn(field) { field.name }).join(" | ") +
    " |\n"
  out = out +
    "| " +
    batch.schema.fields.map(fn(_field) { "---" }).join(" | ") +
    " |\n"
  let rows = batch_rows(batch)
  let limit = if rows < 10 { rows } else { 10 }
  for row in 0..<limit {
    let cells = []
    for i, _field in batch.schema.fields {
      cells.push(cell_markdown(batch.columns[i].values[row]))
    }
    out = out + "| " + cells.join(" | ") + " |\n"
  }
  out
}

///|
/// Markdown view used by the CLI demo and by pull-request comments.
pub fn run_markdown(source : String) -> String {
  let (batch, stats, violations) = evaluate(source) catch {
    EngineError(message) => return "# Relcore error\n\n" + message + "\n"
  }
  render_markdown(batch, stats, violations)
}
