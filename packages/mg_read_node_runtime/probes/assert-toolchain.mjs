// @ts-check

/** Exact Node executable version approved for this Runtime repository. */
const expectedNodeVersion = "24.16.0";

/** Exact npm version that generated and validates the locked dependency tree. */
const expectedNpmVersion = "11.13.0";

// Keep this probe independent from compiled Runtime files: it must also catch a
// wrong PATH before TypeScript compilation or staging can begin.
if (process.versions.node !== expectedNodeVersion) {
  throw new Error(
    "Expected Node " +
      expectedNodeVersion +
      " but PATH resolved Node " +
      process.versions.node +
      ". Activate the pinned Node toolchain before running npm scripts.",
  );
}

/** npm writes its resolved version into this script environment on every run. */
const userAgent = process.env.npm_config_user_agent ?? "";
const npmVersion = /^npm\/([^ ]+)/.exec(userAgent)?.[1];

if (npmVersion !== expectedNpmVersion) {
  throw new Error(
    "Expected npm " +
      expectedNpmVersion +
      " but npm_config_user_agent was " +
      JSON.stringify(userAgent) +
      ".",
  );
}

// A successful line is intentionally concise and contains no local paths.
console.log(
  "Pinned toolchain active: Node " +
    expectedNodeVersion +
    ", npm " +
    expectedNpmVersion +
    ".",
);
