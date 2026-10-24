///|
pub(all) enum JoinKind {
  Inner
  Left
  Right
  Full
  Semi
  Anti
} derive(Eq)

///|
pub fn join_kind_name(kind : JoinKind) -> String {
  match kind {
    Inner => "inner"
    Left => "left"
    Right => "right"
    Full => "full"
    Semi => "semi"
    Anti => "anti"
  }
}

///|
pub(all) struct AggSpec {
  func : String
  input : String?
  out_name : String
} derive(Eq)

///|
pub(all) enum Plan {
  Scan(Batch)
  Filter(Expr, Plan)
  Project(Array[(String, Expr)], Plan)
  Join(Plan, Plan, Array[String], Array[String], JoinKind)
  Aggregate(Array[String], Array[AggSpec], Plan)
  Sort(Array[(String, Bool)], Plan)
  Limit(Int32, Plan)
  Union(Plan, Plan)
  Distinct(Array[String], Plan)
  Tag(String, Plan)
}

///|
pub(all) struct JoinEvidence {
  key : String
  fanout : Int32
  left_rows : Array[Int32]
  right_rows : Array[Int32]
} derive(Eq)

///|
pub(all) struct NodeStat {
  op : String
  rows_in : Int32
  rows_out : Int32
  matched_left : Int32
  unmatched_left : Int32
  unmatched_right : Int32
  max_fanout : Int32
  left_unique : Bool
  right_unique : Bool
  worst_key : String?
  worst_count : Int32
  evidence : JoinEvidence?
} derive(Eq)

///|
fn plain_stat(op : String, rows_in : Int32, rows_out : Int32) -> NodeStat {
  {
    op,
    rows_in,
    rows_out,
    matched_left: 0,
    unmatched_left: 0,
    unmatched_right: 0,
    max_fanout: 0,
    left_unique: true,
    right_unique: true,
    worst_key: None,
    worst_count: 0,
    evidence: None,
  }
}

///|
pub(all) struct Frame {
  label : String
  batch : Batch
} derive(Eq)

///|
pub(all) struct ExecResult {
  batch : Batch
  stats : Array[NodeStat]
  frames : Array[Frame]
} derive(Eq)

///|

///|
fn key_of(
  batch : Batch,
  row : Int32,
  columns : Array[String],
) -> String? raise EngineError {
  let mut out = ""
  for name in columns {
    let value = eval_expr(Col(name), batch, row)
    if value_is_null(value) {
      return None
    }
    let key = value_key(value)
    out = out + key.length().to_string() + ":" + key + "|"
  }
  Some(out)
}

///|
fn schema_has(schema : Schema, name : String) -> Bool {
  match schema_index(schema, name) {
    Some(_) => true
    None => false
  }
}

///|
fn join_schema(left : Batch, right : Batch) -> (Schema, Array[String]) {
  let fields = left.schema.fields.copy()
  let names = []
  for field in right.schema.fields {
    let mut name = field.name
    while schema_has(Schema::{ fields, }, name) {
      name = name + "_right"
    }
    fields.push(Field::{ name, dtype: field.dtype, nullable: true, })
    names.push(name)
  }
  (Schema::{ fields, }, names)
}

///|
fn join_batches(
  left : Batch,
  right : Batch,
  left_keys : Array[String],
  right_keys : Array[String],
  kind : JoinKind,
) -> (Batch, NodeStat) raise EngineError {
  if left_keys.length() != right_keys.length() {
    fail("join requires equal numbers of left and right keys")
  }
  let left_rows = batch_rows(left)
  let right_rows = batch_rows(right)
  let right_map : Map[String, Array[Int32]] = Map([])
  for r in 0..<right_rows {
    match key_of(right, r, right_keys) {
      Some(key) =>
        match right_map.get(key) {
          Some(bucket) => bucket.push(r)
          None => right_map[key] = [r]
        }
      None => ()
    }
  }
  let left_idx = []
  let right_idx = []
  let matched_right = []
  for _ in 0..<right_rows {
    matched_right.push(false)
  }
  let mut matched_left = 0
  let mut unmatched_left = 0
  let mut max_fanout = 0
  let mut worst_key = None
  let mut worst_count = 0
  let mut worst_left : Array[Int32] = []
  let mut worst_right : Array[Int32] = []
  let mut right_unique = true
  for _key, bucket in right_map {
    if bucket.length() > 1 {
      right_unique = false
    }
  }
  let left_counts : Map[String, Int32] = Map([])
  for l in 0..<left_rows {
    let key = key_of(left, l, left_keys)
    let bucket = match key {
      Some(k) => right_map.get(k)
      None => None
    }
    let matches = match bucket {
      Some(b) => b
      None => []
    }
    match key {
      Some(k) => {
        let count = match left_counts.get(k) {
          Some(n) => n + 1
          None => 1
        }
        left_counts[k] = count
      }
      None => ()
    }
    if matches.length() > 0 {
      matched_left = matched_left + 1
      if matches.length() > max_fanout {
        max_fanout = matches.length()
        worst_key = key
        worst_count = matches.length()
        worst_left = [l]
        worst_right = []
        for r in matches {
          if worst_right.length() < 2 {
            worst_right.push(r)
          }
        }
      } else if matches.length() == max_fanout &&
        max_fanout > 1 &&
        worst_left.length() < 2 {
        worst_left.push(l)
      }
    } else {
      unmatched_left = unmatched_left + 1
    }
    match kind {
      Inner =>
        for r in matches {
          left_idx.push(l)
          right_idx.push(r)
        }
      Left =>
        if matches.length() == 0 {
          left_idx.push(l)
          right_idx.push(-1)
        } else {
          for r in matches {
            left_idx.push(l)
            right_idx.push(r)
          }
        }
      Right =>
        for r in matches {
          left_idx.push(l)
          right_idx.push(r)
          matched_right[r] = true
        }
      Full =>
        if matches.length() == 0 {
          left_idx.push(l)
          right_idx.push(-1)
        } else {
          for r in matches {
            left_idx.push(l)
            right_idx.push(r)
            matched_right[r] = true
          }
        }
      Semi =>
        if matches.length() > 0 {
          left_idx.push(l)
          right_idx.push(-1)
        }
      Anti =>
        if matches.length() == 0 {
          left_idx.push(l)
          right_idx.push(-1)
        }
    }
  }
  let mut unmatched_right = 0
  if kind == Right || kind == Full {
    for r in 0..<right_rows {
      if !matched_right[r] {
        unmatched_right = unmatched_right + 1
        left_idx.push(-1)
        right_idx.push(r)
      }
    }
  }
  let rows_out = left_idx.length()
  let evidence = match worst_key {
    Some(key) =>
      if max_fanout > 1 {
        Some(JoinEvidence::{
          key,
          fanout: max_fanout,
          left_rows: worst_left,
          right_rows: worst_right,
        })
      } else {
        None
      }
    None => None
  }
  let mut left_unique = true
  for _key, count in left_counts {
    if count > 1 {
      left_unique = false
    }
  }
  if kind == Semi || kind == Anti {
    let batch = batch_take(left, left_idx)
    (
      batch,
      {
        op: "join:" + join_kind_name(kind),
        rows_in: left_rows + right_rows,
        rows_out,
        matched_left,
        unmatched_left,
        unmatched_right,
        max_fanout,
        left_unique,
        right_unique,
        worst_key,
        worst_count,
        evidence,
      },
    )
  } else {
    let (schema, right_names) = join_schema(left, right)
    let columns = []
    for i, _field in left.schema.fields {
      let values = []
      for pair in 0..<rows_out {
        let idx = left_idx[pair]
        if idx < 0 {
          values.push(VNull)
        } else {
          values.push(left.columns[i].values[idx])
        }
      }
      columns.push(Column::{ values, })
    }
    for i, _name in right_names {
      let values = []
      for pair in 0..<rows_out {
        let idx = right_idx[pair]
        if idx < 0 {
          values.push(VNull)
        } else {
          values.push(right.columns[i].values[idx])
        }
      }
      columns.push(Column::{ values, })
    }
    (
      { schema, columns, },
      {
        op: "join:" + join_kind_name(kind),
        rows_in: left_rows + right_rows,
        rows_out,
        matched_left,
        unmatched_left,
        unmatched_right,
        max_fanout,
        left_unique,
        right_unique,
        worst_key,
        worst_count,
        evidence,
      },
    )
  }
}

///|
fn aggregate_batch(
  input : Batch,
  keys : Array[String],
  aggs : Array[AggSpec],
) -> Batch raise EngineError {
  let rows = batch_rows(input)
  let order = []
  let groups : Map[String, Array[Int32]] = Map([])
  for row in 0..<rows {
    let mut key = ""
    for name in keys {
      let value = eval_expr(Col(name), input, row)
      key = key + value_key(value) + "|"
    }
    match groups.get(key) {
      Some(bucket) => bucket.push(row)
      None => {
        groups[key] = [row]
        order.push(key)
      }
    }
  }
  let fields = []
  for name in keys {
    let index = batch_column_index(input, name)
    fields.push(input.schema.fields[index])
  }
  for agg in aggs {
    let dtype = match agg.func {
      "count" => TInt
      "avg" => TFloat
      _ =>
        match agg.input {
          Some(name) => {
            let index = batch_column_index(input, name)
            input.schema.fields[index].dtype
          }
          None => TInt
        }
    }
    fields.push(Field::{ name: agg.out_name, dtype, nullable: true, })
  }
  let columns = []
  for name in keys {
    let index = batch_column_index(input, name)
    let values = []
    for key in order {
      let rows = groups[key]
      if rows.length() > 0 {
        values.push(input.columns[index].values[rows[0]])
      } else {
        values.push(VNull)
      }
    }
    columns.push(Column::{ values, })
  }
  for agg in aggs {
    let values = []
    for key in order {
      let rows = groups[key]
      let result = match agg.func {
        "count" =>
          match agg.input {
            Some(name) => {
              let index = batch_column_index(input, name)
              let mut count = 0
              for row in rows {
                if !value_is_null(input.columns[index].values[row]) {
                  count = count + 1
                }
              }
              VInt(count.to_int64())
            }
            None => VInt(rows.length().to_int64())
          }
        "sum" =>
          match agg.input {
            Some(name) => {
              let index = batch_column_index(input, name)
              let mut int_sum = 0L
              let mut float_sum = 0.0
              let mut is_float = false
              let mut seen = false
              for row in rows {
                match input.columns[index].values[row] {
                  VInt(n) => {
                    seen = true
                    int_sum = int_sum + n
                    float_sum = float_sum + n.to_double()
                  }
                  VFloat(f) => {
                    seen = true
                    is_float = true
                    float_sum = float_sum + f
                  }
                  _ => ()
                }
              }
              if !seen {
                VNull
              } else if is_float {
                VFloat(float_sum)
              } else {
                VInt(int_sum)
              }
            }
            None => VNull
          }
        "min" | "max" =>
          match agg.input {
            Some(name) => {
              let index = batch_column_index(input, name)
              let mut best = VNull
              let mut seen = false
              for row in rows {
                let value = input.columns[index].values[row]
                if value_is_null(value) {
                  continue
                }
                if !seen {
                  best = value
                  seen = true
                } else {
                  let cmp = value_compare(value, best)
                  if (agg.func == "min" && cmp < 0) ||
                    (agg.func == "max" && cmp > 0) {
                    best = value
                  }
                }
              }
              best
            }
            None => VNull
          }
        "avg" =>
          match agg.input {
            Some(name) => {
              let index = batch_column_index(input, name)
              let mut total = 0.0
              let mut count = 0
              for row in rows {
                match input.columns[index].values[row] {
                  VInt(n) => {
                    total = total + n.to_double()
                    count = count + 1
                  }
                  VFloat(f) => {
                    total = total + f
                    count = count + 1
                  }
                  _ => ()
                }
              }
              if count == 0 {
                VNull
              } else {
                VFloat(total / count.to_double())
              }
            }
            None => VNull
          }
        _ => VNull
      }
      values.push(result)
    }
    columns.push(Column::{ values, })
  }
  { schema: Schema::{ fields, }, columns, }
}

///|
fn sort_batch(
  input : Batch,
  keys : Array[(String, Bool)],
) -> Batch raise EngineError {
  let rows = batch_rows(input)
  let indices = []
  for i in 0..<rows {
    indices.push(i)
  }
  let key_columns = []
  for key in keys {
    let (name, desc) = key
    let index = batch_column_index(input, name)
    key_columns.push((input.columns[index].values, desc))
  }
  indices.sort_by(fn(a, b) {
    for key in key_columns {
      let (values, desc) = key
      let left = values[a]
      let right = values[b]
      let cmp = match (value_is_null(left), value_is_null(right)) {
        (true, true) => 0
        (true, false) => 1
        (false, true) => -1
        (false, false) =>
          if desc {
            -value_compare(left, right)
          } else {
            value_compare(left, right)
          }
      }
      if cmp != 0 {
        return cmp
      }
    }
    0
  })
  batch_take(input, indices)
}

///|
fn project_batch(
  input : Batch,
  columns : Array[(String, Expr)],
) -> Batch raise EngineError {
  let rows = batch_rows(input)
  let fields = []
  let out = []
  for column in columns {
    let (name, expr) = column
    let values = []
    let mut dtype = TNull
    for row in 0..<rows {
      let value = eval_expr(expr, input, row)
      if !value_is_null(value) && dtype == TNull {
        dtype = dtype_of(value)
      }
      values.push(value)
    }
    fields.push(Field::{ name, dtype, nullable: true, })
    out.push(Column::{ values, })
  }
  { schema: Schema::{ fields, }, columns: out, }
}

///|
fn distinct_batch(
  input : Batch,
  keys : Array[String],
) -> Batch raise EngineError {
  if keys.length() == 0 {
    fail("distinct requires at least one key")
  }
  let seen : Map[String, Bool] = Map([])
  let keep = []
  for row in 0..<batch_rows(input) {
    let mut key = ""
    for name in keys {
      key = key + value_key(eval_expr(Col(name), input, row)) + "|"
    }
    if !seen.contains(key) {
      seen[key] = true
      keep.push(row)
    }
  }
  batch_take(input, keep)
}

///|
fn merge_dtype(left : DataType, right : DataType) -> DataType? {
  if left == right {
    return Some(left)
  }
  match (left, right) {
    (TInt, TFloat) | (TFloat, TInt) => Some(TFloat)
    (TNull, other) | (other, TNull) => Some(other)
    _ => None
  }
}

///|
fn union_batches(left : Batch, right : Batch) -> Batch raise EngineError {
  if left.schema.fields.length() != right.schema.fields.length() {
    fail("union requires the same number of columns")
  }
  let fields = []
  for i, field in left.schema.fields {
    let other = right.schema.fields[i]
    if field.name != other.name {
      fail("union requires identical column names")
    }
    let merged = merge_dtype(field.dtype, other.dtype)
    match merged {
      Some(dtype) =>
        fields.push(Field::{ name: field.name, dtype, nullable: true, })
      None =>
        fail(
          "union cannot merge column " +
          field.name +
          ": " +
          dtype_name(field.dtype) +
          " vs " +
          dtype_name(other.dtype),
        )
    }
  }
  let columns = []
  for i, field in fields {
    let values = []
    for value in left.columns[i].values {
      values.push(cast_value(value, field.dtype))
    }
    for value in right.columns[i].values {
      values.push(cast_value(value, field.dtype))
    }
    columns.push(Column::{ values, })
  }
  { schema: Schema::{ fields, }, columns, }
}

///|
pub fn execute(plan : Plan) -> ExecResult raise EngineError {
  match plan {
    Scan(batch) => {
      let rows = batch_rows(batch)
      { batch, stats: [plain_stat("scan", rows, rows)], frames: [], }
    }
    Filter(predicate, input) => {
      let inner = execute(input)
      let rows = batch_rows(inner.batch)
      let keep = []
      for row in 0..<rows {
        match eval_expr(predicate, inner.batch, row) {
          VBool(true) => keep.push(row)
          _ => ()
        }
      }
      let batch = batch_take(inner.batch, keep)
      let stats = inner.stats.copy()
      stats.push(plain_stat("filter", rows, batch_rows(batch)))
      { batch, stats, frames: inner.frames, }
    }
    Project(columns, input) => {
      let inner = execute(input)
      let batch = project_batch(inner.batch, columns)
      let stats = inner.stats.copy()
      stats.push(
        plain_stat("project", batch_rows(inner.batch), batch_rows(batch)),
      )
      { batch, stats, frames: inner.frames, }
    }
    Join(left, right, left_keys, right_keys, kind) => {
      let l = execute(left)
      let r = execute(right)
      let (batch, stat) = join_batches(
        l.batch,
        r.batch,
        left_keys,
        right_keys,
        kind,
      )
      let stats = l.stats.copy()
      for item in r.stats {
        stats.push(item)
      }
      stats.push(stat)
      let frames = l.frames.copy()
      for frame in r.frames {
        frames.push(frame)
      }
      { batch, stats, frames, }
    }
    Aggregate(keys, aggs, input) => {
      let inner = execute(input)
      let batch = aggregate_batch(inner.batch, keys, aggs)
      let stats = inner.stats.copy()
      stats.push(
        plain_stat("aggregate", batch_rows(inner.batch), batch_rows(batch)),
      )
      { batch, stats, frames: inner.frames, }
    }
    Sort(keys, input) => {
      let inner = execute(input)
      let batch = sort_batch(inner.batch, keys)
      let stats = inner.stats.copy()
      stats.push(plain_stat("sort", batch_rows(inner.batch), batch_rows(batch)))
      { batch, stats, frames: inner.frames, }
    }
    Limit(n, input) => {
      if n < 0 {
        fail("limit must be non-negative")
      }
      let inner = execute(input)
      let rows = batch_rows(inner.batch)
      let count = if n < rows { n } else { rows }
      let indices = []
      for i in 0..<count {
        indices.push(i)
      }
      let batch = batch_take(inner.batch, indices)
      let stats = inner.stats.copy()
      stats.push(plain_stat("limit", rows, count))
      { batch, stats, frames: inner.frames, }
    }
    Union(left, right) => {
      let l = execute(left)
      let r = execute(right)
      let batch = union_batches(l.batch, r.batch)
      let stats = l.stats.copy()
      for item in r.stats {
        stats.push(item)
      }
      stats.push(
        plain_stat(
          "union",
          batch_rows(l.batch) + batch_rows(r.batch),
          batch_rows(batch),
        ),
      )
      let frames = l.frames.copy()
      for frame in r.frames {
        frames.push(frame)
      }
      { batch, stats, frames, }
    }
    Distinct(keys, input) => {
      let inner = execute(input)
      let batch = distinct_batch(inner.batch, keys)
      let stats = inner.stats.copy()
      stats.push(
        plain_stat("distinct", batch_rows(inner.batch), batch_rows(batch)),
      )
      { batch, stats, frames: inner.frames, }
    }
    Tag(label, input) => {
      let inner = execute(input)
      let stats = inner.stats.copy()
      stats.push(
        plain_stat(
          "tag:" + label,
          batch_rows(inner.batch),
          batch_rows(inner.batch),
        ),
      )
      let frames = inner.frames.copy()
      frames.push(Frame::{ label, batch: inner.batch, })
      { batch: inner.batch, stats, frames, }
    }
  }
}
