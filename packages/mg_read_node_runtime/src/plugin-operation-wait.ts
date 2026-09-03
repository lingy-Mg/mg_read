/**
 * Caller-facing cancellation/deadline wait for one already-started operation.
 *
 * The underlying Promise remains observed after the caller receives a terminal
 * error. Its owner releases capacity only when real plugin work settles.
 */
import { PluginManagerError } from "./plugin-manager-contract.js";

export type PluginOperationOutcome<TResult> =
  | { readonly ok: true; readonly value: TResult }
  | { readonly error: unknown; readonly ok: false };

export function settlePluginOperation<TResult>(
  operation: Promise<TResult>,
): Promise<PluginOperationOutcome<TResult>> {
  return operation.then(
    (value) => ({ ok: true, value }),
    (error: unknown) => ({ error, ok: false }),
  );
}

export function throwIfPluginOperationUnavailable(
  signal: AbortSignal,
  deadlineUnixMs: string,
): void {
  if (signal.aborted) throw new PluginManagerError("cancelled");
  const deadline = Number(deadlineUnixMs);
  if (!Number.isFinite(deadline)) throw new PluginManagerError("invalid_request");
  if (deadline <= Date.now()) throw new PluginManagerError("timeout");
}

export function waitForPluginOperation<TResult>(
  completion: Promise<PluginOperationOutcome<TResult>>,
  signal: AbortSignal,
  deadlineUnixMs: string,
): Promise<TResult> {
  throwIfPluginOperationUnavailable(signal, deadlineUnixMs);
  const deadline = Number(deadlineUnixMs);
  return new Promise<TResult>((resolve, reject) => {
    let settled = false;
    let deadlineTimer: ReturnType<typeof setTimeout> | undefined;
    const cleanup = (): void => {
      signal.removeEventListener("abort", onAbort);
      if (deadlineTimer !== undefined) clearTimeout(deadlineTimer);
    };
    const fail = (code: "cancelled" | "timeout"): void => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(new PluginManagerError(code));
    };
    const onAbort = (): void => fail("cancelled");
    signal.addEventListener("abort", onAbort, { once: true });
    deadlineTimer = setTimeout(
      () => fail("timeout"),
      Math.max(1, Math.min(2_147_483_647, deadline - Date.now())),
    );
    void completion.then((outcome) => {
      if (settled) return;
      settled = true;
      cleanup();
      if (outcome.ok) {
        resolve(outcome.value);
      } else {
        reject(outcome.error);
      }
    });
    if (signal.aborted) onAbort();
  });
}

export function positiveMilliseconds(value: number | undefined, fallback: number): number {
  return value === undefined || !Number.isFinite(value) || value <= 0
    ? fallback
    : Math.max(1, Math.floor(value));
}
