///|
test "json plan runs a filter and project pipeline" {
  let document = "{\"version\":1,\"sources\":{\"orders\":{\"format\":\"csv\",\"data\":\"id,qty\\n1,2\\n2,0\\n3,5\\n\"}},\"plan\":{\"op\":\"project\",\"columns\":[{\"name\":\"id\",\"expr\":{\"col\":\"id\"}},{\"name\":\"big\",\"expr\":{\"op\":\">\",\"left\":{\"col\":\"qty\"},\"right\":{\"lit\":1}}}],\"input\":{\"op\":\"filter\",\"predicate\":{\"op\":\">\",\"left\":{\"col\":\"qty\"},\"right\":{\"lit\":1}},\"input\":{\"op\":\"scan\",\"source\":\"orders\"}}},\"contracts\":[{\"kind\":\"row_count\",\"min\":1,\"max\":10}]}"
  let report = run(document)
  inspect(report.contains("\"ok\":true"), content="true")
  inspect(report.contains("\"rows\":2"), content="true")
}

///|
test "json plan reports a join cardinality violation with a witness" {
  let document = "{\"version\":1,\"sources\":{\"orders\":{\"format\":\"csv\",\"data\":\"customer,qty\\n7,1\\n7,2\\n\"},\"customers\":{\"format\":\"csv\",\"data\":\"customer,name\\n7,alice\\n7,alice2\\n\"}},\"plan\":{\"op\":\"join\",\"kind\":\"inner\",\"left\":{\"op\":\"scan\",\"source\":\"orders\"},\"right\":{\"op\":\"scan\",\"source\":\"customers\"},\"left_keys\":[\"customer\"],\"right_keys\":[\"customer\"]},\"contracts\":[{\"kind\":\"join_cardinality\",\"allowed\":[\"one_to_one\"]}]}"
  let report = run(document)
  inspect(report.contains("\"ok\":false"), content="true")
  inspect(report.contains("JOIN_CARDINALITY"), content="true")
  inspect(report.contains("worst_key"), content="true")
  inspect(report.contains("\"max_fanout\":2"), content="true")
}

///|
test "json plan reports duplicate keys" {
  let document = "{\"version\":1,\"sources\":{\"orders\":{\"format\":\"csv\",\"data\":\"customer,qty\\n7,1\\n7,2\\n\"}},\"plan\":{\"op\":\"scan\",\"source\":\"orders\"},\"contracts\":[{\"kind\":\"unique\",\"columns\":[\"customer\"]}]}"
  let report = run(document)
  inspect(report.contains("DUPLICATE_KEY"), content="true")
  inspect(report.contains("row=0"), content="true")
}

///|
test "jsonl source is columnar and nullable" {
  let document = "{\"version\":1,\"sources\":{\"events\":{\"format\":\"jsonl\",\"data\":\"{\\\"id\\\":1,\\\"kind\\\":\\\"a\\\"}\\n{\\\"id\\\":2}\"}},\"plan\":{\"op\":\"scan\",\"source\":\"events\"},\"contracts\":[{\"kind\":\"row_count\",\"min\":2,\"max\":2}]}"
  let report = run(document)
  inspect(report.contains("\"ok\":true"), content="true")
  inspect(report.contains("\"rows\":2"), content="true")
}

///|
test "unknown source is a structured error" {
  let document = "{\"version\":1,\"sources\":{},\"plan\":{\"op\":\"scan\",\"source\":\"missing\"}}"
  let report = run(document)
  inspect(report.contains("INVALID_INPUT"), content="true")
  inspect(report.contains("unknown source"), content="true")
}

///|
test "markdown report renders stages and violations" {
  let document = "{\"version\":1,\"sources\":{\"orders\":{\"format\":\"csv\",\"data\":\"customer,qty\\n7,1\\n7,2\\n\"},\"customers\":{\"format\":\"csv\",\"data\":\"customer,name\\n7,a\\n7,b\\n\"}},\"plan\":{\"op\":\"join\",\"kind\":\"inner\",\"left\":{\"op\":\"scan\",\"source\":\"orders\"},\"right\":{\"op\":\"scan\",\"source\":\"customers\"},\"left_keys\":[\"customer\"],\"right_keys\":[\"customer\"]},\"contracts\":[{\"kind\":\"join_cardinality\",\"allowed\":[\"one_to_one\"]}]}"
  let report = run_markdown(document)
  inspect(report.contains("Plan stages"), content="true")
  inspect(report.contains("JOIN_CARDINALITY"), content="true")
}

///|
test "contracts can target a tagged node" {
  let document = "{\"version\":1,\"sources\":{\"orders\":{\"format\":\"csv\",\"data\":\"customer,qty\\n7,1\\n7,2\\n\"},\"customers\":{\"format\":\"csv\",\"data\":\"customer,name\\n7,a\\n7,b\\n\"}},\"plan\":{\"op\":\"tag\",\"name\":\"after_join\",\"input\":{\"op\":\"join\",\"kind\":\"inner\",\"left\":{\"op\":\"scan\",\"source\":\"orders\"},\"right\":{\"op\":\"scan\",\"source\":\"customers\"},\"left_keys\":[\"customer\"],\"right_keys\":[\"customer\"]}},\"contracts\":[{\"kind\":\"row_count\",\"at\":\"after_join\",\"min\":1,\"max\":3}]}"
  let report = run(document)
  inspect(report.contains("ROW_COUNT"), content="true")
  inspect(report.contains("tag:after_join"), content="true")
}

///|
test "join evidence contains minimal row pointers" {
  let document = "{\"version\":1,\"sources\":{\"orders\":{\"format\":\"csv\",\"data\":\"customer,qty\\n7,1\\n7,2\\n\"},\"customers\":{\"format\":\"csv\",\"data\":\"customer,name\\n7,a\\n7,b\\n\"}},\"plan\":{\"op\":\"join\",\"kind\":\"inner\",\"left\":{\"op\":\"scan\",\"source\":\"orders\"},\"right\":{\"op\":\"scan\",\"source\":\"customers\"},\"left_keys\":[\"customer\"],\"right_keys\":[\"customer\"]},\"contracts\":[{\"kind\":\"join_cardinality\",\"allowed\":[\"one_to_one\"]}]}"
  let report = run(document)
  inspect(report.contains("\"left_rows\":[0,1]"), content="true")
  inspect(report.contains("\"right_rows\":[0,1]"), content="true")
}

///|
test "compare finds the first diverging stage and row diff" {
  let document = "{\"version\":1,\"sources\":{\"orders\":{\"format\":\"csv\",\"data\":\"customer,tenant,qty\\n9,acme,1\\n9,initech,2\\n\"},\"customers\":{\"format\":\"csv\",\"data\":\"customer,tenant,name\\n9,acme,Carol A\\n9,initech,Carol I\\n\"}},\"baseline\":{\"op\":\"join\",\"kind\":\"inner\",\"left\":{\"op\":\"scan\",\"source\":\"orders\"},\"right\":{\"op\":\"scan\",\"source\":\"customers\"},\"left_keys\":[\"customer\"],\"right_keys\":[\"customer\"]},\"candidate\":{\"op\":\"join\",\"kind\":\"inner\",\"left\":{\"op\":\"scan\",\"source\":\"orders\"},\"right\":{\"op\":\"scan\",\"source\":\"customers\"},\"left_keys\":[\"customer\",\"tenant\"],\"right_keys\":[\"customer\",\"tenant\"]}}"
  let report = compare(document)
  inspect(report.contains("\"baseline_rows\":4"), content="true")
  inspect(report.contains("\"candidate_rows\":2"), content="true")
  inspect(report.contains("\"retained\":2"), content="true")
  inspect(report.contains("\"lost\":2"), content="true")
  inspect(report.contains("\"index\":2"), content="true")
}

///|
test "unknown tag is an explicit violation" {
  let document = "{\"version\":1,\"sources\":{\"orders\":{\"format\":\"csv\",\"data\":\"id\\n1\\n\"}},\"plan\":{\"op\":\"scan\",\"source\":\"orders\"},\"contracts\":[{\"kind\":\"row_count\",\"at\":\"missing\",\"min\":1,\"max\":1}]}"
  let report = run(document)
  inspect(report.contains("UNKNOWN_NODE"), content="true")
}

///|
test "jsonl missing keys become nulls" {
  let document = "{\"version\":1,\"sources\":{\"e\":{\"format\":\"jsonl\",\"data\":\"{\\\"id\\\":1,\\\"v\\\":2}\\n{\\\"id\\\":2}\"}},\"plan\":{\"op\":\"scan\",\"source\":\"e\"},\"contracts\":[{\"kind\":\"row_count\",\"min\":2,\"max\":2}]}"
  let report = run(document)
  inspect(report.contains("\"ok\":true"), content="true")
}

///|
test "compare reports a schema mismatch" {
  let document = "{\"version\":1,\"sources\":{\"o\":{\"format\":\"csv\",\"data\":\"id,v\\n1,a\\n\"}},\"baseline\":{\"op\":\"scan\",\"source\":\"o\"},\"candidate\":{\"op\":\"project\",\"columns\":[{\"name\":\"id2\",\"expr\":{\"col\":\"id\"}}],\"input\":{\"op\":\"scan\",\"source\":\"o\"}}}"
  let report = compare(document)
  inspect(report.contains("\"schema_match\":false"), content="true")
  inspect(report.contains("\"ok\":false"), content="true")
}
