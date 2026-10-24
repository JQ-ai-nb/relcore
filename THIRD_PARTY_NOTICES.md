# Sources and licensing

Relcore is an original MoonBit implementation, MIT licensed. It does not copy source code from MoonFrame, moonsql, Polars, pandas, DuckDB or any other third-party project.

Conceptual references (public semantics, not code):

- PostgreSQL table expressions, join multiplicity and NULL comparison semantics.
- Polars expression and lazy-plan layering.
- pandas `merge(validate=...)` cardinality validation.
- DuckDB logical/physical plan separation and `EXPLAIN`.

Prior work by the same author: `JQ-ai-nb/JoinWitness` (MIT) explored bounded equi-join preflight, exact cardinality and constructive counterexamples. Relcore generalizes that idea from one operator to a plan IR with execution contracts. No JoinWitness business implementation is copied into this repository.

AI assistance was used for implementation, tests and documentation. The maintainer is responsible for the design, review and final quality.

All example data in `examples/` is synthetic. No private customer or personal data is redistributed.

The MoonBit standard library `moonbitlang/core` is a toolchain dependency under Apache-2.0 with LLVM exceptions. Compiled JS/WASM distributions may contain standard-library routines; its license and notice are distributed with the MoonBit toolchain.
