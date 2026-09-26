# Alice native source boundary

This directory owns the portable Alice source core, native C ABI adapter,
fixture tests, and deterministic `.mgplugin` packaging. `src/parsing.rs` owns
pure HTML and URL projection; `src/source.rs` owns source routing and public
result projection; `src/lib.rs` owns ABI entry points and host IO/cache/cancel
adaptation. The native runtime's public ABI is owned by
`packages/mg_read_native_runtime/abi` and must be consumed as-is.

The plugin is a Rust `cdylib` and `rlib`; it does not use Node.js, WASI, or
retain host pointers. Cache values are complete public source values with
resource descriptors, never Runtime-generated proxy URLs. `cargo test --locked`
is the direct portable fixture and ABI-stub test entry point. `tools/package.ps1`
requires NanaZip 7.0 version 2609.2 on PATH and builds one reproducible
high-compression Deflate ZIP with Windows x64 and Android arm64
libraries. Both platforms import the same archive; LAN transfer filters it to
the receiver's platform and recomputes the transfer descriptor.
