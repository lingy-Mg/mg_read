// Deliberately emits no stdout/stderr. The supervisor must classify this as a
// privacy-safe startup fatal and write only bounded fallback evidence.
process.exit(73);
