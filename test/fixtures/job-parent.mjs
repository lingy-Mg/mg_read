import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

// Test-only parent that keeps a descendant alive long enough for the Windows
// Job Object test to prove kill-on-close behavior for an entire process tree.
const input = createInterface({ input: process.stdin });

process.stdout.write(`${JSON.stringify({ type: "job_parent_ready" })}\n`);
input.on("line", (line) => {
  if (line !== "spawn") {
    return;
  }
  const child = spawn(
    process.execPath,
    ["--input-type=module", "--eval", "setInterval(() => {}, 1000);"],
    { stdio: "ignore", windowsHide: true },
  );
  process.stdout.write(`${JSON.stringify({ pid: child.pid, type: "job_child" })}\n`);
});

setInterval(() => {}, 1000);
