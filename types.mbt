///|
/// Logical scalar types supported by the execution core.
pub(all) enum DataType {
  TNull
  TBool
  TInt
  TFloat
  TText
} derive(Eq)

///|
/// A closed scalar value. Text is UTF-8/UTF-16 as provided by MoonBit strings.
pub(all) enum Value {
  VNull
  VBool(Bool)
  VInt(Int64)
  VFloat(Double)
  VText(String)
} derive(Eq)

///|
pub(all) struct Field {
  name : String
  dtype : DataType
  nullable : Bool
} derive(Eq)

///|
pub(all) struct Schema {
  fields : Array[Field]
} derive(Eq)

///|
pub(all) struct Column {
  values : Array[Value]
} derive(Eq)

///|
/// A column-major batch. Every column has the same length.
pub(all) struct Batch {
  schema : Schema
  columns : Array[Column]
} derive(Eq)

///|
pub(all) suberror EngineError {
  EngineError(String)
}

///|
pub fn[T] fail(message : String) -> T raise EngineError {
  raise EngineError(message)
}

///|
pub fn dtype_name(dtype : DataType) -> String {
  match dtype {
    TNull => "null"
    TBool => "bool"
    TInt => "int64"
    TFloat => "float64"
    TText => "text"
  }
}

///|
pub fn dtype_of(value : Value) -> DataType {
  match value {
    VNull => TNull
    VBool(_) => TBool
    VInt(_) => TInt
    VFloat(_) => TFloat
    VText(_) => TText
  }
}

///|
/// Canonical key used by joins, grouping and distinct. The type tag prevents
/// accidental collisions such as the text "1" and the integer 1.
pub fn value_key(value : Value) -> String {
  match value {
    VNull => "n:"
    VBool(b) => if b { "b:1" } else { "b:0" }
    VInt(n) => "i:" + n.to_string()
    VFloat(f) => "f:" + f.to_string()
    VText(s) => "t:" + s
  }
}

///|
pub fn value_text(value : Value) -> String {
  match value {
    VNull => ""
    VBool(b) => b.to_string()
    VInt(n) => n.to_string()
    VFloat(f) => f.to_string()
    VText(s) => s
  }
}

///|
pub fn value_is_null(value : Value) -> Bool {
  match value {
    VNull => true
    _ => false
  }
}

///|
pub fn value_compare(left : Value, right : Value) -> Int32 {
  match (left, right) {
    (VNull, VNull) => 0
    (VNull, _) => 1
    (_, VNull) => -1
    (VBool(a), VBool(b)) => if a == b { 0 } else if a { 1 } else { -1 }
    (VInt(a), VInt(b)) => a.compare(b)
    (VFloat(a), VFloat(b)) => a.compare(b)
    (VInt(a), VFloat(b)) => a.to_double().compare(b)
    (VFloat(a), VInt(b)) => a.compare(b.to_double())
    (VText(a), VText(b)) => a.compare(b)
    (a, b) => value_text(a).compare(value_text(b))
  }
}

///|
pub fn schema_index(schema : Schema, name : String) -> Int32? {
  for i, field in schema.fields {
    if field.name == name {
      return Some(i)
    }
  }
  None
}

///|
pub fn batch_rows(batch : Batch) -> Int32 {
  if batch.columns.length() == 0 {
    0
  } else {
    batch.columns[0].values.length()
  }
}

///|
pub fn batch_cell(
  batch : Batch,
  column : Int32,
  row : Int32,
) -> Value raise EngineError {
  if column < 0 || column >= batch.columns.length() {
    fail("column index out of range")
  }
  let values = batch.columns[column].values
  if row < 0 || row >= values.length() {
    fail("row index out of range")
  }
  values[row]
}

///|
pub fn batch_column_index(
  batch : Batch,
  name : String,
) -> Int32 raise EngineError {
  match schema_index(batch.schema, name) {
    Some(i) => i
    None => fail("unknown column: " + name)
  }
}

///|
pub fn batch_from_rows(
  schema : Schema,
  rows : Array[Array[Value]],
) -> Batch raise EngineError {
  let columns = []
  for i, field in schema.fields {
    let values = []
    for row in rows {
      if row.length() != schema.fields.length() {
        fail("row width differs from schema")
      }
      values.push(row[i])
    }
    ignore(field)
    columns.push(Column::{ values, })
  }
  { schema, columns, }
}

///|
pub fn batch_take(
  batch : Batch,
  indices : Array[Int32],
) -> Batch raise EngineError {
  let columns = []
  for column in batch.columns {
    let values = []
    for index in indices {
      if index < 0 || index >= column.values.length() {
        fail("take index out of range")
      }
      values.push(column.values[index])
    }
    columns.push(Column::{ values, })
  }
  { schema: batch.schema, columns, }
}

///|
pub fn batch_empty(schema : Schema) -> Batch {
  let columns = []
  for _ in schema.fields {
    columns.push(Column::{ values: [], })
  }
  { schema, columns, }
}
