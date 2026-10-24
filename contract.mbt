///|
/// A contract is attached to the result of a plan and is checked after
/// execution. Contracts are data, so they can be serialized or generated.
pub(all) enum Contract {
  RowCount(Int32, Int32)
  Unique(Array[String])
  NoNull(Array[String])
  JoinCardinality(Array[String])
} derive(Eq)

///|
pub(all) struct NodeContract {
  at : String?
  contract : Contract
} derive(Eq)

///|
pub(all) struct Violation {
  code : String
  message : String
  witness : Array[String]
} derive(Eq)

///|
fn witness_row(row : Int32, column : String, value : Value) -> String {
  "row=" + row.to_string() + " column=" + column + " value=" + value_text(value)
}

///|
fn check_unique(
  batch : Batch,
  columns : Array[String],
  out : Array[Violation],
) -> Unit {
  for column in columns {
    let index = match schema_index(batch.schema, column) {
      Some(i) => i
      None => {
        out.push({
          code: "UNKNOWN_COLUMN",
          message: "unique contract references an unknown column: " + column,
          witness: [],
        })
        continue
      }
    }
    let seen : Map[String, Array[Int32]] = Map([])
    let reported : Map[String, Bool] = Map([])
    for row in 0..<batch.columns[index].values.length() {
      let value = batch.columns[index].values[row]
      if value_is_null(value) {
        continue
      }
      let key = value_key(value)
      match seen.get(key) {
        Some(rows) => {
          rows.push(row)
          if !reported.contains(key) && reported.length() < 5 {
            reported[key] = true
            let witness = []
            for duplicate in rows {
              witness.push(witness_row(duplicate, column, value))
            }
            out.push({
              code: "DUPLICATE_KEY",
              message: "column " + column + " has a duplicate value",
              witness,
            })
          }
        }
        None => seen[key] = [row]
      }
    }
  }
}

///|
fn check_no_null(
  batch : Batch,
  columns : Array[String],
  out : Array[Violation],
) -> Unit {
  for column in columns {
    let index = match schema_index(batch.schema, column) {
      Some(i) => i
      None => {
        out.push({
          code: "UNKNOWN_COLUMN",
          message: "no_null contract references an unknown column: " + column,
          witness: [],
        })
        continue
      }
    }
    let witness = []
    for row in 0..<batch.columns[index].values.length() {
      if value_is_null(batch.columns[index].values[row]) && witness.length() < 5 {
        witness.push(witness_row(row, column, VNull))
      }
    }
    if witness.length() > 0 {
      out.push({
        code: "NULL_VALUE",
        message: "column " + column + " contains null values",
        witness,
      })
    }
  }
}

///|
pub fn cardinality_shape(stat : NodeStat) -> String {
  match (stat.left_unique, stat.right_unique) {
    (true, true) => "one_to_one"
    (true, false) => "one_to_many"
    (false, true) => "many_to_one"
    (false, false) => "many_to_many"
  }
}

///|
fn check_join_cardinality(
  stats : Array[NodeStat],
  allowed : Array[String],
  out : Array[Violation],
) -> Unit {
  let mut found = false
  for stat in stats {
    if stat.op.has_prefix("join:") {
      found = true
      let shape = cardinality_shape(stat)
      if !allowed.contains(shape) {
        let witness = [
          "node=" + stat.op,
          "shape=" + shape,
          "max_fanout=" + stat.max_fanout.to_string(),
          "unmatched_left=" + stat.unmatched_left.to_string(),
          "unmatched_right=" + stat.unmatched_right.to_string(),
        ]
        match stat.worst_key {
          Some(key) => witness.push("worst_key=" + key)
          None => ()
        }
        match stat.evidence {
          Some(evidence) => {
            let left = []
            for row in evidence.left_rows {
              left.push(row.to_string())
            }
            let right = []
            for row in evidence.right_rows {
              right.push(row.to_string())
            }
            witness.push("left_rows=" + left.join(","))
            witness.push("right_rows=" + right.join(","))
          }
          None => ()
        }
        out.push({
          code: "JOIN_CARDINALITY",
          message: "join cardinality " + shape + " is outside the allowed set",
          witness,
        })
      }
    }
  }
  if !found {
    out.push({
      code: "NO_JOIN",
      message: "join_cardinality contract requires at least one join in the plan",
      witness: [],
    })
  }
}

///|
fn check_one(
  batch : Batch,
  stats : Array[NodeStat],
  contract : Contract,
  out : Array[Violation],
) -> Unit {
  match contract {
    RowCount(min, max) => {
      let rows = batch_rows(batch)
      if rows < min || rows > max {
        out.push({
          code: "ROW_COUNT",
          message: "row count " +
          rows.to_string() +
          " is outside [" +
          min.to_string() +
          ", " +
          max.to_string() +
          "]",
          witness: ["rows=" + rows.to_string()],
        })
      }
    }
    Unique(columns) => check_unique(batch, columns, out)
    NoNull(columns) => check_no_null(batch, columns, out)
    JoinCardinality(allowed) => check_join_cardinality(stats, allowed, out)
  }
}

///|
pub fn check_contracts(
  batch : Batch,
  stats : Array[NodeStat],
  contracts : Array[Contract],
) -> Array[Violation] {
  let out = []
  for contract in contracts {
    check_one(batch, stats, contract, out)
  }
  out
}

///|
fn find_frame(frames : Array[Frame], label : String) -> Batch? {
  for frame in frames {
    if frame.label == label {
      return Some(frame.batch)
    }
  }
  None
}

///|
/// Contracts can target the final result (`at = None`) or a tagged plan node.
/// Tagged nodes are the general form: the same contract language works at any
/// stage, not only at the root.
pub fn check_node_contracts(
  result : ExecResult,
  contracts : Array[NodeContract],
) -> Array[Violation] {
  let out = []
  for item in contracts {
    match item.at {
      None => check_one(result.batch, result.stats, item.contract, out)
      Some(label) =>
        match find_frame(result.frames, label) {
          Some(batch) => check_one(batch, result.stats, item.contract, out)
          None =>
            out.push({
              code: "UNKNOWN_NODE",
              message: "contract references an unknown tagged node: " + label,
              witness: [],
            })
        }
    }
  }
  out
}
