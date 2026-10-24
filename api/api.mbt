///|
/// Stable JavaScript-facing entry point. Keep this thin so the core stays
/// usable from MoonBit, JS and (later) WASM hosts without duplicated logic.
pub fn run(source : String) -> String {
  @relcore.run(source)
}

///|
pub fn run_markdown(source : String) -> String {
  @relcore.run_markdown(source)
}

///|
pub fn compare(source : String) -> String {
  @relcore.compare(source)
}
