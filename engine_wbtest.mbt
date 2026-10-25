///|
test "csv infers int, float, bool and null" {
  let batch = read_csv(
    "id,qty,price,active,note\n1,2,3.5,true,hello\n2,0,,false,\n", "orders",
  )
  inspect(batch_rows(batch), content="2")
  inspect(dtype_name(batch.schema.fields[0].dtype), content="int64")
  inspect(dtype_name(batch.schema.fields[2].dtype), content="float64")
  inspect(dtype_name(batch.schema.fields[3].dtype), content="bool")
  inspect(value_key(batch.columns[4].values[1]), content="n:")
}

///|
test "filter and project compose" {
  let batch = read_csv("id,qty\n1,2\n2,0\n3,5\n", "orders")
  let plan = Project(
    [("id", Col("id")), ("double_qty", Bin("*", Col("qty"), Lit(VInt(2L))))],
    Filter(Bin(">", Col("qty"), Lit(VInt(1L))), Scan(batch)),
  )
  let result = execute(plan)
  inspect(batch_rows(result.batch), content="2")
  inspect(value_key(result.batch.columns[1].values[0]), content="i:4")
}

///|
test "inner join multiplies matching rows and reports fanout" {
  let orders = read_csv("customer,qty\n7,1\n7,2\n8,3\n", "orders")
  let customers = read_csv("customer,name\n7,alice\n8,bob\n", "customers")
  let result = execute(
    Join(Scan(orders), Scan(customers), ["customer"], ["customer"], Inner),
  )
  inspect(batch_rows(result.batch), content="3")
  inspect(result.stats[2].max_fanout, content="1")
  inspect(result.stats[2].unmatched_left, content="0")
}

///|
test "left join keeps unmatched rows" {
  let orders = read_csv("customer,qty\n7,1\n9,2\n", "orders")
  let customers = read_csv("customer,name\n7,alice\n", "customers")
  let result = execute(
    Join(Scan(orders), Scan(customers), ["customer"], ["customer"], Left),
  )
  inspect(batch_rows(result.batch), content="2")
  inspect(value_key(result.batch.columns[3].values[1]), content="n:")
  inspect(result.stats[2].unmatched_left, content="1")
}

///|
test "aggregate groups and sums" {
  let orders = read_csv("region,qty\nwest,1\nwest,2\neast,3\n", "orders")
  let result = execute(
    Aggregate(
      ["region"],
      [{ func: "sum", input: Some("qty"), out_name: "total", }],
      Scan(orders),
    ),
  )
  inspect(batch_rows(result.batch), content="2")
  inspect(value_key(result.batch.columns[1].values[0]), content="i:3")
}

///|
test "union stacks rows and distinct keeps the first occurrence" {
  let a = read_csv("id,v\n1,a\n2,b\n", "a")
  let b = read_csv("id,v\n2,b\n3,c\n", "b")
  let result = execute(Distinct(["id"], Union(Scan(a), Scan(b))))
  inspect(batch_rows(result.batch), content="3")
  inspect(value_key(result.batch.columns[0].values[2]), content="i:3")
}

///|
test "null join keys never match" {
  let orders = read_csv("customer,qty\n,1\n7,2\n", "orders")
  let customers = read_csv("customer,name\n7,alice\n", "customers")
  let result = execute(
    Join(Scan(orders), Scan(customers), ["customer"], ["customer"], Inner),
  )
  inspect(batch_rows(result.batch), content="1")
  inspect(result.stats[2].unmatched_left, content="1")
}

///|
test "sort keeps nulls last in both directions" {
  let input = read_csv("id,v\n1,\n2,b\n3,a\n", "t")
  let asc = execute(Sort([("v", false)], Scan(input)))
  inspect(value_key(asc.batch.columns[1].values[2]), content="n:")
  let desc = execute(Sort([("v", true)], Scan(input)))
  inspect(value_key(desc.batch.columns[1].values[2]), content="n:")
}

///|
test "empty csv with header is a valid zero-row batch" {
  let input = read_csv("id,v\n", "t")
  inspect(batch_rows(input), content="0")
  let result = execute(
    Aggregate(
      ["id"],
      [{ func: "count", input: None, out_name: "n", }],
      Scan(input),
    ),
  )
  inspect(batch_rows(result.batch), content="0")
}

///|
test "negative limit is rejected" {
  let input = read_csv("id\n1\n", "t")
  let ok = try {
    ignore(execute(Limit(-1, Scan(input))))
    false
  } catch {
    _ => true
  }
  inspect(ok, content="true")
}

///|
test "csv rejects text after a closing quote" {
  let ok = try {
    ignore(read_csv("a\n\"x\"y\n", "t"))
    false
  } catch {
    _ => true
  }
  inspect(ok, content="true")
}

///|
test "union widens int and float columns" {
  let a = read_csv("id,v\n1,1\n", "a")
  let b = read_csv("id,v\n2,2.5\n", "b")
  let result = execute(Union(Scan(a), Scan(b)))
  inspect(batch_rows(result.batch), content="2")
  inspect(dtype_name(result.batch.schema.fields[1].dtype), content="float64")
}

///|
test "join rejects mismatched key counts" {
  let a = read_csv("id,v\n1,a\n", "a")
  let b = read_csv("id,v\n1,b\n", "b")
  let ok = try {
    ignore(execute(Join(Scan(a), Scan(b), ["id"], ["id", "v"], Inner)))
    false
  } catch {
    _ => true
  }
  inspect(ok, content="true")
}

///|
test "sum over an all-null group is null" {
  let input = read_csv("k,v\na,\n", "t")
  let result = execute(
    Aggregate(
      ["k"],
      [{ func: "sum", input: Some("v"), out_name: "s", }],
      Scan(input),
    ),
  )
  inspect(value_key(result.batch.columns[1].values[0]), content="n:")
}

///|
test "optimizer pushes a filter below a project" {
  let input = read_csv("id,qty\n1,2\n2,0\n", "t")
  let plan = Filter(
    Bin(">", Col("qty"), Lit(VInt(1L))),
    Project([("id", Col("id")), ("qty", Col("qty"))], Scan(input)),
  )
  let optimized = optimize(plan)
  let text = plan_to_string(optimized)
  inspect(text.has_prefix("project"), content="true")
  inspect(text.contains("filter"), content="true")
  inspect(batch_rows(execute(optimized).batch), content="1")
}

///|
test "optimizer folds constant predicates" {
  let input = read_csv("id\n1\n", "t")
  let plan = Filter(Bin(">", Lit(VInt(2L)), Lit(VInt(1L))), Scan(input))
  let text = plan_to_string(optimize(plan))
  inspect(text.contains("'true'"), content="true")
}

///|
test "optimizer pushes a limit below a project" {
  let input = read_csv("id\n1\n2\n", "t")
  let plan = Limit(1, Project([("id", Col("id"))], Scan(input)))
  let text = plan_to_string(optimize(plan))
  inspect(text.has_prefix("project"), content="true")
  inspect(text.contains("limit 1"), content="true")
}
