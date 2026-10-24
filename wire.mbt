///|
fn j_obj(value : Json, what : String) -> Map[String, Json] raise EngineError {
  match value {
    Object(fields) => fields
    _ => fail("expected JSON object for " + what)
  }
}

///|
fn j_array(value : Json, what : String) -> Array[Json] raise EngineError {
  match value {
    Array(items) => items
    _ => fail("expected JSON array for " + what)
  }
}

///|
fn j_str(value : Json, what : String) -> String raise EngineError {
  match value {
    String(text) => text
    _ => fail("expected JSON string for " + what)
  }
}

///|
fn j_int(value : Json, what : String) -> Int32 raise EngineError {
  match value {
    Number(n, ..) => {
      let i = n.to_int()
      if i.to_double() != n {
        fail("expected integer for " + what)
      }
      i
    }
    _ => fail("expected JSON number for " + what)
  }
}

///|
fn j_bool(value : Json, what : String) -> Bool raise EngineError {
  match value {
    True => true
    False => false
    _ => fail("expected JSON boolean for " + what)
  }
}

///|
fn required(
  fields : Map[String, Json],
  name : String,
) -> Json raise EngineError {
  match fields.get(name) {
    Some(value) => value
    None => fail("missing required field: " + name)
  }
}

///|
fn optional_string(
  fields : Map[String, Json],
  name : String,
) -> String? raise EngineError {
  match fields.get(name) {
    Some(Null) | None => None
    Some(value) => Some(j_str(value, name))
  }
}

///|
fn j_scalar(value : Json) -> Value raise EngineError {
  match value {
    Null => VNull
    True => VBool(true)
    False => VBool(false)
    String(text) => VText(text)
    Number(n, repr=Some(token)) => {
      // Preserve exact integer tokens; fall back to float for fractions.
      let text = token
      match parse_int64_opt(text) {
        Some(integer) => VInt(integer)
        None => VFloat(n)
      }
    }
    Number(n, ..) => VFloat(n)
    _ => fail("literal must be a JSON scalar")
  }
}

///|
fn read_dtype(text : String) -> DataType raise EngineError {
  match text {
    "null" => TNull
    "bool" => TBool
    "int64" | "int" => TInt
    "float64" | "float" => TFloat
    "text" | "string" => TText
    _ => fail("unknown data type: " + text)
  }
}

///|
fn read_expr(value : Json) -> Expr raise EngineError {
  let fields = j_obj(value, "expression")
  match fields.get("col") {
    Some(name) => return Col(j_str(name, "col"))
    None => ()
  }
  match fields.get("lit") {
    Some(literal) => return Lit(j_scalar(literal))
    None => ()
  }
  match fields.get("call") {
    Some(name) => {
      let arg_values = j_array(required(fields, "args"), "call args")
      let args = []
      for item in arg_values {
        args.push(read_expr(item))
      }
      return Call(j_str(name, "call"), args)
    }
    None => ()
  }
  let op = j_str(required(fields, "op"), "expression op")
  if op == "not" {
    return Not(read_expr(required(fields, "arg")))
  }
  if op == "is_null" {
    return IsNull(read_expr(required(fields, "arg")))
  }
  if op == "cast" {
    return Cast(
      read_expr(required(fields, "arg")),
      read_dtype(j_str(required(fields, "dtype"), "dtype")),
    )
  }
  Bin(
    op,
    read_expr(required(fields, "left")),
    read_expr(required(fields, "right")),
  )
}

///|
fn read_join_kind(text : String) -> JoinKind raise EngineError {
  match text {
    "inner" => Inner
    "left" => Left
    "right" => Right
    "full" => Full
    "semi" => Semi
    "anti" => Anti
    _ => fail("unknown join kind: " + text)
  }
}

///|
fn read_string_array(
  value : Json,
  what : String,
) -> Array[String] raise EngineError {
  let items = j_array(value, what)
  let out = []
  for item in items {
    out.push(j_str(item, what))
  }
  out
}

///|
fn read_plan(
  value : Json,
  sources : Map[String, Batch],
) -> Plan raise EngineError {
  let fields = j_obj(value, "plan node")
  let op = j_str(required(fields, "op"), "plan op")
  match op {
    "scan" => {
      let name = j_str(required(fields, "source"), "source")
      match sources.get(name) {
        Some(batch) => Scan(batch)
        None => fail("unknown source: " + name)
      }
    }
    "filter" =>
      Filter(
        read_expr(required(fields, "predicate")),
        read_plan(required(fields, "input"), sources),
      )
    "project" => {
      let columns = []
      for item in j_array(required(fields, "columns"), "project columns") {
        let column = j_obj(item, "project column")
        columns.push(
          (
            j_str(required(column, "name"), "name"),
            read_expr(required(column, "expr")),
          ),
        )
      }
      Project(columns, read_plan(required(fields, "input"), sources))
    }
    "join" =>
      Join(
        read_plan(required(fields, "left"), sources),
        read_plan(required(fields, "right"), sources),
        read_string_array(required(fields, "left_keys"), "left_keys"),
        read_string_array(required(fields, "right_keys"), "right_keys"),
        read_join_kind(j_str(required(fields, "kind"), "join kind")),
      )
    "aggregate" => {
      let aggs = []
      for item in j_array(required(fields, "aggs"), "aggregates") {
        let agg = j_obj(item, "aggregate")
        aggs.push({
          func: j_str(required(agg, "func"), "aggregate func"),
          input: optional_string(agg, "input"),
          out_name: j_str(required(agg, "as"), "aggregate alias"),
        })
      }
      Aggregate(
        read_string_array(required(fields, "keys"), "group keys"),
        aggs,
        read_plan(required(fields, "input"), sources),
      )
    }
    "sort" => {
      let keys = []
      for item in j_array(required(fields, "keys"), "sort keys") {
        let key = j_obj(item, "sort key")
        keys.push(
          (
            j_str(required(key, "column"), "sort column"),
            match key.get("desc") {
              Some(value) => j_bool(value, "desc")
              None => false
            },
          ),
        )
      }
      Sort(keys, read_plan(required(fields, "input"), sources))
    }
    "limit" =>
      Limit(
        j_int(required(fields, "n"), "limit"),
        read_plan(required(fields, "input"), sources),
      )
    "union" =>
      Union(
        read_plan(required(fields, "left"), sources),
        read_plan(required(fields, "right"), sources),
      )
    "distinct" =>
      Distinct(
        read_string_array(required(fields, "keys"), "distinct keys"),
        read_plan(required(fields, "input"), sources),
      )
    "tag" =>
      Tag(
        j_str(required(fields, "name"), "tag name"),
        read_plan(required(fields, "input"), sources),
      )
    _ => fail("unknown plan op: " + op)
  }
}

///|
fn read_node_contract(value : Json) -> NodeContract raise EngineError {
  let fields = j_obj(value, "contract")
  NodeContract::{
    at: optional_string(fields, "at"),
    contract: read_contract(value),
  }
}

///|
fn read_contract(value : Json) -> Contract raise EngineError {
  let fields = j_obj(value, "contract")
  let kind = j_str(required(fields, "kind"), "contract kind")
  match kind {
    "row_count" =>
      RowCount(
        j_int(required(fields, "min"), "row_count.min"),
        j_int(required(fields, "max"), "row_count.max"),
      )
    "unique" =>
      Unique(read_string_array(required(fields, "columns"), "unique columns"))
    "no_null" =>
      NoNull(read_string_array(required(fields, "columns"), "no_null columns"))
    "join_cardinality" =>
      JoinCardinality(
        read_string_array(required(fields, "allowed"), "allowed cardinalities"),
      )
    _ => fail("unknown contract kind: " + kind)
  }
}

///|
fn read_jsonl(source : String, name : String) -> Batch raise EngineError {
  let text = if source.length() > 0 && source[0].to_int() == 65279 {
    source[1:].to_owned()
  } else {
    source
  }
  let objects = []
  for line in text.split("\n") {
    let text = line.trim().to_owned()
    if text.length() > 0 {
      objects.push(
        j_obj(
          @json.parse(text) catch {
            _ => fail("invalid JSONL line in " + name)
          },
          "JSONL row",
        ),
      )
    }
  }
  if objects.length() == 0 {
    fail("JSONL input has no rows")
  }
  let key_set : Map[String, Bool] = Map([])
  for object in objects {
    for key, _ in object {
      key_set[key] = true
    }
  }
  let keys = []
  for key, _ in key_set {
    keys.push(key)
  }
  keys.sort()
  let fields = []
  let columns = []
  for key in keys {
    let mut dtype = TNull
    for object in objects {
      match object.get(key) {
        Some(value) => {
          let scalar = j_scalar(value) catch { _ => VText(value.stringify()) }
          let kind = dtype_of(scalar)
          if kind != TNull {
            if dtype == TNull {
              dtype = kind
            } else if dtype != kind {
              if (dtype == TInt && kind == TFloat) ||
                (dtype == TFloat && kind == TInt) {
                dtype = TFloat
              } else {
                dtype = TText
              }
            }
          }
        }
        None => ()
      }
    }
    fields.push(Field::{ name: key, dtype, nullable: true, })
    let values = []
    for object in objects {
      match object.get(key) {
        Some(value) => {
          let scalar = j_scalar(value) catch { _ => VText(value.stringify()) }
          values.push(cast_value(scalar, dtype))
        }
        None => values.push(VNull)
      }
    }
    columns.push(Column::{ values, })
  }
  { schema: Schema::{ fields, }, columns, }
}
