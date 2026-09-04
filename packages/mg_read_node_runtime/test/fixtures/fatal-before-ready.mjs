// Test-only child entrypoint: exercises the Flutter monitor's structured fatal
// startup path without leaking raw process errors or requiring a Node server.
process.stderr.write(
  `${JSON.stringify({
    code: "test_startup_failure",
    message: "The desktop Runtime test fixture stopped before ready.",
    type: "fatal",
  })}\n`,
);
process.exitCode = 17;
