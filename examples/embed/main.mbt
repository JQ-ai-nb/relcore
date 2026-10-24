///|
/// A deliberately small consumer of the public MoonBit API. It proves that a
/// host program can depend on Relcore without the JSON plan format or the CLI.
fn main {
  let orders = @relcore.read_csv(
    "customer,tenant,amount\n7,acme,10\n7,acme,20\n8,globex,5\n", "orders",
  ) catch {
    _ => abort("orders parse failed")
  }
  let customers = @relcore.read_csv(
    "customer,tenant,segment\n7,acme,enterprise\n8,globex,smb\n", "customers",
  ) catch {
    _ => abort("customers parse failed")
  }
  let result = @relcore.execute(
    @relcore.Join(
      @relcore.Scan(orders),
      @relcore.Scan(customers),
      ["customer", "tenant"],
      ["customer", "tenant"],
      @relcore.Inner,
    ),
  ) catch {
    _ => abort("join failed")
  }
  let violations = @relcore.check_contracts(result.batch, result.stats, [
    @relcore.JoinCardinality(["many_to_one"]),
  ])
  println(
    "embed rows=\{@relcore.batch_rows(result.batch)} violations=\{violations.length()}",
  )
}
