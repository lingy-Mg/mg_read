import type { Duplex } from "node:stream";

const CLOSE_GOING_AWAY = 1001;
const CLOSE_MESSAGE_TOO_BIG = 1009;
const CLOSE_NORMAL = 1000;
const CLOSE_PROTOCOL_ERROR = 1002;
const CLOSE_TRY_AGAIN_LATER = 1013;
const CLOSE_UNSUPPORTED_DATA = 1003;

/** Maximum encoded size of one Runtime control message. */
export const maxWebSocketControlFrameBytes = 4 * 1024 * 1024;

/** Maximum application-plus-socket backlog retained for one connection. */
export const maxWebSocketOutboundQueueBytes = 8 * 1024 * 1024;

const MAX_BUFFERED_BYTES = maxWebSocketControlFrameBytes + 32;
const webSocketOpcode = Object.freeze({
  close: 0x8,
  ping: 0x9,
  pong: 0xa,
  text: 0x1,
} as const);

/** Opcodes that the deliberately narrow Runtime control transport can emit. */
type RuntimeWebSocketOpcode =
  (typeof webSocketOpcode)[keyof typeof webSocketOpcode];

/** Callbacks supplied by the Runtime-owned WebSocket session owner. */
export interface ServerWebSocketSessionOptions {
  /** Invoked exactly once when the connection is no longer usable. */
  readonly onClosed: () => void;

  /** Receives one decoded, bounded, unfragmented client text message. */
  readonly onText: (text: string) => void;
}

/**
 * Small Runtime-internal WebSocket framing layer.
 *
 * It deliberately accepts only bounded, masked, unfragmented text control
 * frames. Outbound frames are serialized through a bounded queue so a slow
 * peer cannot turn the Node Runtime's writable buffer into unbounded memory.
 */
export class ServerWebSocketSession {
  /** Bytes not yet forming one complete client frame. Always size-bounded. */
  #buffer = Buffer.alloc(0);

  /** Terminal state; once true no user traffic may be accepted or queued. */
  #closed = false;

  /** Guards the owner callback against duplicate socket/close notifications. */
  #closedNotified = false;

  /** Application-owned frames waiting for the underlying writable stream. */
  #outboundFrames: Buffer[] = [];

  /** Exact byte count for [#outboundFrames], excluding socket internals. */
  #outboundQueuedBytes = 0;

  /** Prevents write attempts until Node emits the writable `drain` event. */
  #waitingForDrain = false;
  readonly #onClosed: () => void;
  readonly #onText: (text: string) => void;
  readonly #socket: Duplex;

  constructor(socket: Duplex, options: ServerWebSocketSessionOptions) {
    this.#socket = socket;
    this.#onClosed = options.onClosed;
    this.#onText = options.onText;

    socket.on("data", (chunk: Buffer) => {
      this.receive(chunk);
    });
    socket.on("drain", () => {
      this.#waitingForDrain = false;
      this.#flushOutbound();
    });
    socket.once("close", () => {
      this.#markClosed();
    });
    socket.once("error", () => {
      this.#markClosed();
    });
  }

  /** Whether this session can no longer carry Runtime control traffic. */
  get isClosed(): boolean {
    return this.#closed;
  }

  /**
   * Ends the WebSocket session and notifies its owner exactly once.
   *
   * Close reasons are truncated to the RFC control-frame maximum so an error
   * path can never manufacture an oversized frame.
   */
  close(code: number = CLOSE_NORMAL, reason: string = ""): void {
    if (this.#closed) {
      return;
    }

    const reasonBytes = Buffer.from(reason, "utf8").subarray(0, 123);
    const payload = Buffer.allocUnsafe(2 + reasonBytes.length);
    payload.writeUInt16BE(code, 0);
    reasonBytes.copy(payload, 2);
    const frame = this.#makeFrame(webSocketOpcode.close, payload);

    this.#closed = true;
    this.#outboundFrames = [];
    this.#outboundQueuedBytes = 0;
    if (this.#socket.writable && !this.#socket.destroyed) {
      this.#socket.write(frame);
      this.#socket.end();
    } else {
      this.#socket.destroy();
    }
    this.#markClosed();
  }

  /**
   * Accepts raw bytes delivered by Node's upgraded socket.
   *
   * This method is intentionally public to consume the HTTP upgrade's `head`
   * bytes, which arrive before the socket's normal `data` listener runs.
   */
  receive(chunk: Buffer): void {
    if (this.#closed) {
      return;
    }

    if (this.#buffer.length + chunk.length > MAX_BUFFERED_BYTES) {
      this.close(CLOSE_MESSAGE_TOO_BIG, "Frame exceeds Runtime limit.");
      return;
    }

    this.#buffer = Buffer.concat([this.#buffer, chunk]);
    this.#parseFrames();
  }

  /**
   * Queues one outbound text frame.
   *
   * Returns `false` after closing an overloaded/unavailable connection; an
   * oversized Runtime-generated payload is a programming error and throws.
   */
  sendText(text: string): boolean {
    const payload = Buffer.from(text, "utf8");
    if (payload.length > maxWebSocketControlFrameBytes) {
      throw new Error("Runtime attempted to send a WebSocket frame above its limit.");
    }

    return this.#enqueueFrame(webSocketOpcode.text, payload);
  }

  #fail(code: number, reason: string): void {
    this.close(code, reason);
  }

  #markClosed(): void {
    if (this.#closedNotified) {
      return;
    }
    this.#closed = true;
    this.#closedNotified = true;
    this.#onClosed();
  }

  #parseFrames(): void {
    while (!this.#closed) {
      if (this.#buffer.length < 2) {
        return;
      }

      const first = this.#buffer[0];
      const second = this.#buffer[1];
      if (first === undefined || second === undefined) {
        return;
      }

      const finalFrame = (first & 0x80) !== 0;
      const hasReservedBits = (first & 0x70) !== 0;
      const opcode = first & 0x0f;
      const isMasked = (second & 0x80) !== 0;
      let payloadLength = second & 0x7f;
      let offset = 2;

      if (hasReservedBits || !finalFrame) {
        this.#fail(CLOSE_PROTOCOL_ERROR, "Fragmented or extended frames are not supported.");
        return;
      }

      if (!isMasked) {
        this.#fail(CLOSE_PROTOCOL_ERROR, "Client WebSocket frames must be masked.");
        return;
      }

      if (payloadLength === 126) {
        if (this.#buffer.length < offset + 2) {
          return;
        }
        payloadLength = this.#buffer.readUInt16BE(offset);
        offset += 2;
      } else if (payloadLength === 127) {
        if (this.#buffer.length < offset + 8) {
          return;
        }
        const extendedLength = this.#buffer.readBigUInt64BE(offset);
        offset += 8;
        if (extendedLength > BigInt(Number.MAX_SAFE_INTEGER)) {
          this.#fail(CLOSE_MESSAGE_TOO_BIG, "Runtime control frame exceeds its limit.");
          return;
        }
        payloadLength = Number(extendedLength);
      }

      if (payloadLength > maxWebSocketControlFrameBytes) {
        this.#fail(CLOSE_MESSAGE_TOO_BIG, "Runtime control frame exceeds its limit.");
        return;
      }
      if (opcode >= 0x8 && payloadLength > 125) {
        this.#fail(CLOSE_PROTOCOL_ERROR, "WebSocket control frames must not exceed 125 bytes.");
        return;
      }

      const frameLength = offset + 4 + payloadLength;
      if (this.#buffer.length < frameLength) {
        return;
      }

      const mask = this.#buffer.subarray(offset, offset + 4);
      const maskedPayload = this.#buffer.subarray(offset + 4, frameLength);
      const payload = Buffer.allocUnsafe(payloadLength);
      for (let index = 0; index < payloadLength; index += 1) {
        payload[index] = maskedPayload[index]! ^ mask[index % 4]!;
      }
      this.#buffer = this.#buffer.subarray(frameLength);

      switch (opcode) {
        case webSocketOpcode.text:
          this.#onText(payload.toString("utf8"));
          break;
        case webSocketOpcode.close:
          this.close(CLOSE_NORMAL);
          return;
        case webSocketOpcode.ping:
          if (!this.#enqueueFrame(webSocketOpcode.pong, payload)) {
            return;
          }
          break;
        case webSocketOpcode.pong:
          break;
        default:
          this.#fail(CLOSE_UNSUPPORTED_DATA, "Only text Runtime control frames are supported.");
          return;
      }
    }
  }

  /** Adds a frame only while the per-session outbound budget permits it. */
  #enqueueFrame(opcode: RuntimeWebSocketOpcode, payload: Buffer): boolean {
    if (this.#closed || !this.#socket.writable || this.#socket.destroyed) {
      return false;
    }

    const frame = this.#makeFrame(opcode, payload);
    const bufferedBytes = this.#outboundQueuedBytes + this.#socket.writableLength;
    if (bufferedBytes + frame.length > maxWebSocketOutboundQueueBytes) {
      this.close(CLOSE_TRY_AGAIN_LATER, "Runtime outbound queue is overloaded.");
      return false;
    }

    this.#outboundFrames.push(frame);
    this.#outboundQueuedBytes += frame.length;
    this.#flushOutbound();
    return !this.#closed;
  }

  /** Flushes until Node applies backpressure, then waits for `drain`. */
  #flushOutbound(): void {
    if (this.#closed || this.#waitingForDrain || this.#socket.destroyed) {
      return;
    }

    while (this.#outboundFrames.length > 0) {
      const frame = this.#outboundFrames.shift();
      if (frame === undefined) {
        return;
      }
      this.#outboundQueuedBytes -= frame.length;
      const accepted = this.#socket.write(frame);
      if (!accepted) {
        this.#waitingForDrain = true;
        return;
      }
    }
  }

  /** Encodes a server-to-client, final, unmasked WebSocket frame. */
  #makeFrame(opcode: RuntimeWebSocketOpcode, payload: Buffer): Buffer {
    let header: Buffer;
    if (payload.length <= 125) {
      header = Buffer.from([0x80 | opcode, payload.length]);
    } else if (payload.length <= 0xffff) {
      header = Buffer.allocUnsafe(4);
      header[0] = 0x80 | opcode;
      header[1] = 126;
      header.writeUInt16BE(payload.length, 2);
    } else {
      header = Buffer.allocUnsafe(10);
      header[0] = 0x80 | opcode;
      header[1] = 127;
      header.writeBigUInt64BE(BigInt(payload.length), 2);
    }
    return Buffer.concat([header, payload]);
  }
}

/** Close codes the Runtime Core intentionally uses during controlled shutdown. */
export const webSocketCloseCode = Object.freeze({
  goingAway: CLOSE_GOING_AWAY,
  normal: CLOSE_NORMAL,
});
