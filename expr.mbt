///|
/// A small, inspectable expression tree. Expressions are data, so plans can be
/// serialized, printed, rewritten and tested without closures.
pub(all) enum Expr {
  Col(String)
  Lit(Value)
  Bin(String, Expr, Expr)
  Not(Expr)
  IsNull(Expr)
  Cast(Expr, DataType)
  Call(String, Array[Expr])
} derive(Eq)

///|
fn as_float(value : Value) -> Double? {
  match value {
    VInt(n) => Some(n.to_double())
    VFloat(f) => Some(f)
    _ => None
  }
}

///|
fn as_text(value : Value) -> String {
  value_text(value)
}

///|
fn numeric_binary(op : String, left : Value, right : Value) -> Value {
  if left is VNull || right is VNull {
    return VNull
  }
  match (left, right) {
    (VInt(a), VInt(b)) =>
      match op {
        "+" => VInt(a + b)
        "-" => VInt(a - b)
        "*" => VInt(a * b)
        "/" => if b == 0L { VNull } else { VInt(a / b) }
        "%" => if b == 0L { VNull } else { VInt(a % b) }
        _ => VNull
      }
    _ => {
      let a = as_float(left)
      let b = as_float(right)
      match (a, b) {
        (Some(x), Some(y)) =>
          match op {
            "+" => VFloat(x + y)
            "-" => VFloat(x - y)
            "*" => VFloat(x * y)
            "/" => if y == 0.0 { VNull } else { VFloat(x / y) }
            "%" => VNull
            _ => VNull
          }
        _ => VNull
      }
    }
  }
}

///|
fn bool_and(left : Value, right : Value) -> Value {
  match (left, right) {
    (VBool(false), _) | (_, VBool(false)) => VBool(false)
    (VBool(true), VBool(true)) => VBool(true)
    _ => VNull
  }
}

///|
fn bool_or(left : Value, right : Value) -> Value {
  match (left, right) {
    (VBool(true), _) | (_, VBool(true)) => VBool(true)
    (VBool(false), VBool(false)) => VBool(false)
    _ => VNull
  }
}

///|
fn eval_binary(op : String, left : Value, right : Value) -> Value {
  match op {
    "+" | "-" | "*" | "/" | "%" => numeric_binary(op, left, right)
    "and" => bool_and(left, right)
    "or" => bool_or(left, right)
    "=" =>
      if left is VNull || right is VNull {
        VNull
      } else {
        VBool(value_compare(left, right) == 0)
      }
    "!=" =>
      if left is VNull || right is VNull {
        VNull
      } else {
        VBool(value_compare(left, right) != 0)
      }
    "<" =>
      if left is VNull || right is VNull {
        VNull
      } else {
        VBool(value_compare(left, right) < 0)
      }
    "<=" =>
      if left is VNull || right is VNull {
        VNull
      } else {
        VBool(value_compare(left, right) <= 0)
      }
    ">" =>
      if left is VNull || right is VNull {
        VNull
      } else {
        VBool(value_compare(left, right) > 0)
      }
    ">=" =>
      if left is VNull || right is VNull {
        VNull
      } else {
        VBool(value_compare(left, right) >= 0)
      }
    _ => VNull
  }
}

///|
fn cast_value(value : Value, dtype : DataType) -> Value {
  match dtype {
    TNull => VNull
    TText => VText(as_text(value))
    TBool =>
      match value {
        VNull => VNull
        VBool(_) => value
        VInt(n) => VBool(n != 0L)
        VFloat(f) => VBool(f != 0.0)
        VText(s) =>
          match parse_bool_opt(s) {
            Some(b) => VBool(b)
            None => VNull
          }
      }
    TInt =>
      match value {
        VNull => VNull
        VInt(_) => value
        VBool(b) => VInt(if b { 1L } else { 0L })
        VFloat(f) => VInt(f.to_int64())
        VText(s) =>
          match parse_int64_opt(s) {
            Some(n) => VInt(n)
            None => VNull
          }
      }
    TFloat =>
      match value {
        VNull => VNull
        VFloat(_) => value
        VInt(n) => VFloat(n.to_double())
        VBool(b) => VFloat(if b { 1.0 } else { 0.0 })
        VText(s) =>
          match parse_float_opt(s) {
            Some(f) => VFloat(f)
            None => VNull
          }
      }
  }
}

///|
pub fn eval_expr(
  expr : Expr,
  batch : Batch,
  row : Int32,
) -> Value raise EngineError {
  match expr {
    Col(name) => {
      let index = batch_column_index(batch, name)
      batch_cell(batch, index, row)
    }
    Lit(value) => value
    Bin(op, left, right) => {
      let a = eval_expr(left, batch, row)
      let b = eval_expr(right, batch, row)
      eval_binary(op, a, b)
    }
    Not(inner) =>
      match eval_expr(inner, batch, row) {
        VBool(b) => VBool(!b)
        _ => VNull
      }
    IsNull(inner) => VBool(value_is_null(eval_expr(inner, batch, row)))
    Cast(inner, dtype) => cast_value(eval_expr(inner, batch, row), dtype)
    Call(name, args) => {
      let values = []
      for arg in args {
        values.push(eval_expr(arg, batch, row))
      }
      match name {
        "lower" =>
          match values {
            [VText(s), ..] => VText(s.to_lower())
            _ => VNull
          }
        "upper" =>
          match values {
            [VText(s), ..] => VText(s.to_upper())
            _ => VNull
          }
        "len" =>
          match values {
            [VText(s), ..] => VInt(s.length().to_int64())
            _ => VNull
          }
        "coalesce" => {
          let mut result = VNull
          for value in values {
            if !value_is_null(value) {
              result = value
              break
            }
          }
          result
        }
        _ => VNull
      }
    }
  }
}

///|
pub fn expr_columns(expr : Expr, out : Array[String]) -> Unit {
  match expr {
    Col(name) => out.push(name)
    Lit(_) => ()
    Bin(_, left, right) => {
      expr_columns(left, out)
      expr_columns(right, out)
    }
    Not(inner) | IsNull(inner) | Cast(inner, _) => expr_columns(inner, out)
    Call(_, args) =>
      for arg in args {
        expr_columns(arg, out)
      }
  }
}

///|
pub fn expr_to_string(expr : Expr) -> String {
  match expr {
    Col(name) => name
    Lit(value) => "'" + value_text(value) + "'"
    Bin(op, left, right) =>
      "(" + expr_to_string(left) + " " + op + " " + expr_to_string(right) + ")"
    Not(inner) => "not(" + expr_to_string(inner) + ")"
    IsNull(inner) => "is_null(" + expr_to_string(inner) + ")"
    Cast(inner, dtype) =>
      "cast(" + expr_to_string(inner) + ", " + dtype_name(dtype) + ")"
    Call(name, args) => name + "(" + args.map(expr_to_string).join(", ") + ")"
  }
}
