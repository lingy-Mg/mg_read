/**
 * Shared inline-result and control-transport byte budgets, without I/O.
 * A full 10 MiB result needs separate space for the RPC envelope; the write
 * queue can retain two maximum frames, including their WebSocket headers.
 */
export const MAX_INLINE_RESULT_BYTES = 10 * 1024 * 1024;
export const MAX_CONTROL_FRAME_BYTES = MAX_INLINE_RESULT_BYTES + 64 * 1024;
export const MAX_CONTROL_QUEUE_BYTES = 2 * (MAX_CONTROL_FRAME_BYTES + 10);
