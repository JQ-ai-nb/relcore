///|
fn is_digit(ch : Int32) -> Bool {
  ch >= 48 && ch <= 57
}

///|
fn parse_int64_opt(text : String) -> Int64? {
  let n = text.length()
  if n == 0 {
    return None
  }
  let mut i = 0
  let mut sign = 1L
  if text[0] == '-' {
    sign = -1L
    i = 1
  } else if text[0] == '+' {
    i = 1
  }
  if i >= n {
    return None
  }
  let mut total = 0L
  while i < n {
    let ch = text[i].to_int()
    if !is_digit(ch) {
      return None
    }
    let digit = (ch - 48).to_int64()
    if total > 922337203685477580L {
      return None
    }
    total = total * 10L + digit
    i = i + 1
  }
  Some(total * sign)
}

///|
fn parse_float_opt(text : String) -> Double? {
  let n = text.length()
  if n == 0 {
    return None
  }
  let mut has_digit = false
  let mut has_marker = false
  let mut i = 0
  while i < n {
    let ch = text[i].to_int()
    if is_digit(ch) {
      has_digit = true
    } else if ch == 46 || ch == 101 || ch == 69 {
      has_marker = true
    } else if ch == 43 || ch == 45 {
      if i != 0 && text[i - 1].to_int() != 101 && text[i - 1].to_int() != 69 {
        return None
      }
    } else {
      return None
    }
    i = i + 1
  }
  if !has_digit || !has_marker {
    return None
  }
  let value = @string.parse_double(text) catch { _ => return None }
  Some(value)
}

///|
fn parse_bool_opt(text : String) -> Bool? {
  if text == "true" || text == "TRUE" || text == "True" {
    Some(true)
  } else if text == "false" || text == "FALSE" || text == "False" {
    Some(false)
  } else {
    None
  }
}

///|
/// RFC-4180-style record splitter with strict quote handling.
pub fn csv_records(source : String) -> Array[Array[String]] raise EngineError {
  let records = []
  let row = []
  let mut cell = ""
  let mut quoted = false
  let mut i = 0
  while i < source.length() {
    let ch = source[i]
    if quoted {
      if ch == 34 {
        if i + 1 < source.length() && source[i + 1] == 34 {
          cell = cell + "\""
          i = i + 2
        } else {
          if i + 1 < source.length() &&
            source[i + 1] != 44 &&
            source[i + 1] != 10 &&
            source[i + 1] != 13 {
            fail("CSV text follows a closing quote")
          }
          quoted = false
          i = i + 1
        }
      } else {
        cell = cell + source[i:i + 1].to_owned()
        i = i + 1
      }
    } else if ch == 34 {
      if cell != "" {
        fail("CSV quote must begin a field")
      }
      quoted = true
      i = i + 1
    } else if ch == 44 {
      row.push(cell)
      cell = ""
      i = i + 1
    } else if ch == 10 || ch == 13 {
      row.push(cell)
      cell = ""
      if row.length() > 0 && !(row.length() == 1 && row[0] == "") {
        records.push(row.copy())
      }
      row.clear()
      if ch == 13 && i + 1 < source.length() && source[i + 1] == 10 {
        i = i + 2
      } else {
        i = i + 1
      }
    } else {
      cell = cell + source[i:i + 1].to_owned()
      i = i + 1
    }
  }
  if quoted {
    fail("unterminated CSV quote")
  }
  if cell != "" || row.length() > 0 {
    row.push(cell)
    records.push(row)
  }
  if records.length() == 0 {
    fail("CSV input requires a header row")
  }
  records
}

///|
fn infer_column(raw : Array[String]) -> DataType {
  let mut any = false
  let mut bools = true
  let mut ints = true
  let mut floats = true
  for text in raw {
    let value = text.trim().to_owned()
    if value.length() == 0 {
      continue
    }
    any = true
    if parse_bool_opt(value) is None {
      bools = false
    }
    if parse_int64_opt(value) is None {
      ints = false
    }
    if parse_float_opt(value) is None && parse_int64_opt(value) is None {
      floats = false
    }
  }
  if !any {
    TNull
  } else if bools {
    TBool
  } else if ints {
    TInt
  } else if floats {
    TFloat
  } else {
    TText
  }
}

///|
fn cell_value(text : String, dtype : DataType) -> Value {
  let value = text.trim().to_owned()
  if value.length() == 0 {
    return VNull
  }
  match dtype {
    TBool =>
      match parse_bool_opt(value) {
        Some(b) => VBool(b)
        None => VText(value)
      }
    TInt =>
      match parse_int64_opt(value) {
        Some(n) => VInt(n)
        None => VText(value)
      }
    TFloat =>
      match parse_float_opt(value) {
        Some(f) => VFloat(f)
        None =>
          match parse_int64_opt(value) {
            Some(n) => VFloat(n.to_double())
            None => VText(value)
          }
      }
    TNull => VNull
    TText => VText(value)
  }
}

///|
pub fn read_csv(source : String, name : String) -> Batch raise EngineError {
  let text = if source.length() > 0 && source[0].to_int() == 65279 {
    source[1:].to_owned()
  } else {
    source
  }
  let records = csv_records(text)
  let header = records[0]
  if header.length() == 0 {
    fail("CSV header is empty")
  }
  let seen : Map[String, Bool] = Map([])
  for column in header {
    if column.trim().to_owned().length() == 0 {
      fail("CSV header contains an empty column name")
    }
    if seen.contains(column) {
      fail("CSV header contains a duplicate column: " + column)
    }
    seen[column] = true
  }
  let width = header.length()
  let raw_columns : Array[Array[String]] = []
  for _ in 0..<width {
    raw_columns.push([])
  }
  for row in records[1:] {
    if row.length() != width {
      fail("CSV row width differs from header in table " + name)
    }
    for i, cell in row {
      raw_columns[i].push(cell)
    }
  }
  let fields = []
  let columns = []
  for i, column_name in header {
    let dtype = infer_column(raw_columns[i])
    fields.push(Field::{
      name: column_name.trim().to_owned(),
      dtype,
      nullable: true,
    })
    let values = []
    for raw in raw_columns[i] {
      values.push(cell_value(raw, dtype))
    }
    columns.push(Column::{ values, })
  }
  { schema: Schema::{ fields, }, columns, }
}
