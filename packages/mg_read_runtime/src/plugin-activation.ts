/**
 * Bounded activation for one plugin module in the Runtime-owned VM.
 *
 * The timeout prevents an async activate hook from blocking Runtime readiness.
 * It cannot preempt synchronous JavaScript because the core contract permits
 * only one V8 VM and forbids Worker/process isolation.
 */
import type { LoadedPluginModule, MgReadPluginContext } from "./plugin-manager-contract.js";
import { PluginManagerError } from "./plugin-manager-contract.js";

export const defaultPluginActivationTimeoutMs = 5_000;

export async function activatePlugin(
  candidate: LoadedPluginModule,
  context: MgReadPluginContext,
  timeoutMs: number,
): Promise<void> {
  let timeout: ReturnType<typeof setTimeout> | undefined;
  const activation = Promise.resolve().then(() => candidate.activate?.(context));
  const deadline = new Promise<never>((_resolve, reject) => {
    timeout = setTimeout(
      () => reject(new PluginManagerError("plugin_load_failed")),
      Math.max(1, timeoutMs),
    );
  });
  try {
    await Promise.race([activation, deadline]);
  } finally {
    if (timeout !== undefined) clearTimeout(timeout);
    void activation.catch(() => {});
  }
}
