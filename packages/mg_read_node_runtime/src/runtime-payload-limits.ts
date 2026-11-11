/**
 * Shared inline-result and control-transport byte budgets, without I/O.
 * Ordinary results retain their 10 MiB budget. Novel text permits 10 MiB of
 * UTF-8; JSON can escape each byte as six ASCII bytes, with a separate 1 MiB
 * metadata allowance. Frames also reserve the RPC envelope; no buffer is preallocated.
 */
import { contentLimits } from './content-limits.js';

export const MAX_INLINE_RESULT_BYTES = contentLimits.inlineBytes;
export const MAX_INLINE_TEXT_BYTES = contentLimits.novelBytes;
export const MAX_INLINE_NOVEL_RESULT_BYTES = 6 * MAX_INLINE_TEXT_BYTES + contentLimits.novelMetadataBytes;
export const MAX_CONTROL_FRAME_BYTES = Math.max(MAX_INLINE_RESULT_BYTES, MAX_INLINE_NOVEL_RESULT_BYTES) + contentLimits.rpcEnvelopeBytes;
export const MAX_CONTROL_QUEUE_BYTES = 2 * (MAX_CONTROL_FRAME_BYTES + 10);
