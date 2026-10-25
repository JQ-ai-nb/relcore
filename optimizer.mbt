///|
/// Conservative optimizer. Every rule is local and semantics-preserving; if a
/// rule cannot prove safety from the plan alone, it leaves the node untouched.
/// The goal is not a cost-based optimizer, but a plan that is easier to explain
/// and cheaper on the common filter/project/limit shapes.
fn fold_expr(expr : Expr) -> Expr {
  match expr {
    Col(_) | Lit(_) => expr
    Bin(op, left, right) => {
      let left = fold_expr(left)
      let right = fold_expr(right)
      match (left, right) {
        (Lit(a), Lit(b)) => Lit(eval_binary(op, a, b))
        _ => Bin(op, left, right)
      }
    }
    Not(inner) =>
      match fold_expr(inner) {
        Lit(VBool(value)) => Lit(VBool(!value))
        other => Not(other)
      }
    IsNull(inner) =>
      match fold_expr(inner) {
        Lit(value) => Lit(VBool(value_is_null(value)))
        other => IsNull(other)
      }
    Cast(inner, dtype) =>
      match fold_expr(inner) {
        Lit(value) => Lit(cast_value(value, dtype))
        other => Cast(other, dtype)
      }
    Call(name, args) => Call(name, args.map(fold_expr))
  }
}

///|
fn substitute(expr : Expr, mapping : Map[String, String]) -> Expr {
  match expr {
    Col(name) =>
      Col(
        match mapping.get(name) {
          Some(source) => source
          None => name
        },
      )
    Lit(_) => expr
    Bin(op, left, right) =>
      Bin(op, substitute(left, mapping), substitute(right, mapping))
    Not(inner) => Not(substitute(inner, mapping))
    IsNull(inner) => IsNull(substitute(inner, mapping))
    Cast(inner, dtype) => Cast(substitute(inner, mapping), dtype)
    Call(name, args) =>
      Call(name, args.map(fn(arg) { substitute(arg, mapping) }))
  }
}

///|
fn push_filter_through_project(
  predicate : Expr,
  columns : Array[(String, Expr)],
  input : Plan,
) -> Plan? {
  let mapping : Map[String, String] = Map([])
  for column in columns {
    let (name, expr) = column
    match expr {
      Col(source) => mapping[name] = source
      _ => ()
    }
  }
  let refs = []
  expr_columns(predicate, refs)
  for column_ref in refs {
    if !mapping.contains(column_ref) {
      return None
    }
  }
  Some(
    Project(columns, optimize(Filter(substitute(predicate, mapping), input))),
  )
}

///|
pub fn optimize(plan : Plan) -> Plan {
  match plan {
    Scan(_) => plan
    Filter(predicate, input) => {
      let predicate = fold_expr(predicate)
      let input = optimize(input)
      match input {
        Project(columns, inner) =>
          match push_filter_through_project(predicate, columns, inner) {
            Some(optimized) => optimized
            None => Filter(predicate, Project(columns, inner))
          }
        Filter(inner_predicate, inner) =>
          Filter(fold_expr(Bin("and", predicate, inner_predicate)), inner)
        Sort(keys, inner) => Sort(keys, optimize(Filter(predicate, inner)))
        _ => Filter(predicate, input)
      }
    }
    Project(columns, input) => {
      let folded = []
      for column in columns {
        let (name, expr) = column
        folded.push((name, fold_expr(expr)))
      }
      Project(folded, optimize(input))
    }
    Limit(n, input) =>
      match optimize(input) {
        Project(columns, inner) => Project(columns, Limit(n, inner))
        Limit(inner_n, inner) =>
          Limit(if n < inner_n { n } else { inner_n }, inner)
        other => Limit(n, other)
      }
    Join(left, right, left_keys, right_keys, kind) =>
      Join(optimize(left), optimize(right), left_keys, right_keys, kind)
    Aggregate(keys, aggs, input) => Aggregate(keys, aggs, optimize(input))
    Sort(keys, input) => Sort(keys, optimize(input))
    Union(left, right) => Union(optimize(left), optimize(right))
    Distinct(keys, input) => Distinct(keys, optimize(input))
    Tag(label, input) => Tag(label, optimize(input))
  }
}

///|
fn indent(depth : Int32) -> String {
  let mut out = ""
  for _ in 0..<depth {
    out = out + "  "
  }
  out
}

///|
fn render_plan(plan : Plan, depth : Int32, out : Array[String]) -> Unit {
  let pad = indent(depth)
  match plan {
    Scan(batch) => out.push(pad + "scan rows=" + batch_rows(batch).to_string())
    Filter(predicate, input) => {
      out.push(pad + "filter " + expr_to_string(predicate))
      render_plan(input, depth + 1, out)
    }
    Project(columns, input) => {
      let names = []
      for column in columns {
        let (name, _expr) = column
        names.push(name)
      }
      out.push(pad + "project [" + names.join(", ") + "]")
      render_plan(input, depth + 1, out)
    }
    Join(left, right, left_keys, right_keys, kind) => {
      out.push(
        pad +
        "join " +
        join_kind_name(kind) +
        " on [" +
        left_keys.join(", ") +
        "] -> [" +
        right_keys.join(", ") +
        "]",
      )
      render_plan(left, depth + 1, out)
      render_plan(right, depth + 1, out)
    }
    Aggregate(keys, aggs, input) => {
      let parts = []
      for agg in aggs {
        parts.push(agg.func + "->" + agg.out_name)
      }
      out.push(pad + "aggregate [" + keys.join(", ") + "] " + parts.join(", "))
      render_plan(input, depth + 1, out)
    }
    Sort(keys, input) => {
      let parts = []
      for key in keys {
        let (name, desc) = key
        parts.push(name + (if desc { " desc" } else { "" }))
      }
      out.push(pad + "sort [" + parts.join(", ") + "]")
      render_plan(input, depth + 1, out)
    }
    Limit(n, input) => {
      out.push(pad + "limit " + n.to_string())
      render_plan(input, depth + 1, out)
    }
    Union(left, right) => {
      out.push(pad + "union")
      render_plan(left, depth + 1, out)
      render_plan(right, depth + 1, out)
    }
    Distinct(keys, input) => {
      out.push(pad + "distinct [" + keys.join(", ") + "]")
      render_plan(input, depth + 1, out)
    }
    Tag(label, input) => {
      out.push(pad + "tag " + label)
      render_plan(input, depth + 1, out)
    }
  }
}

///|
pub fn plan_to_string(plan : Plan) -> String {
  let lines = []
  render_plan(plan, 0, lines)
  lines.join("\n")
}
