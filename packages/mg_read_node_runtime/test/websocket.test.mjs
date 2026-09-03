import assert from "node:assert/strict";
import { Duplex } from "node:stream";
import test from "node:test";

import {
  maxWebSocketControlFrameBytes,
  ServerWebSocketSession,
} from "../dist/websocket.js";

function maskedTextFrame(payload) {
  const mask = Buffer.from([0x12, 0x34, 0x56, 0x78]);
  let header;
  if (payload.length <= 0xffff) {
    header = Buffer.allocUnsafe(4);
    header[0] = 0x81;
    header[1] = 0x80 | 126;
    header.writeUInt16BE(payload.length, 2);
  } else {
    header = Buffer.allocUnsafe(10);
    header[0] = 0x81;
    header[1] = 0x80 | 127;
    header.writeBigUInt64BE(BigInt(payload.length), 2);
  }
  const masked = Buffer.allocUnsafe(payload.length);
  for (let index = 0; index < payload.length; index += 1) {
    masked[index] = payload[index] ^ mask[index % mask.length];
  }
  return Buffer.concat([header, mask, masked]);
}

function serverPayloadLength(frame) {
  const marker = frame[1] & 0x7f;
  if (marker <= 125) return marker;
  if (marker === 126) return frame.readUInt16BE(2);
  return Number(frame.readBigUInt64BE(2));
}

function capturingSocket(output) {
  return new Duplex({
    read() {},
    write(chunk, _encoding, callback) {
      output.push(Buffer.from(chunk));
      callback();
    },
  });
}

for (const bytes of [64 * 1024, 190 * 1024, maxWebSocketControlFrameBytes]) {
  test(`WebSocket uses extended lengths for a ${bytes}-byte Runtime frame`, () => {
    const output = [];
    const socket = capturingSocket(output);
    const session = new ServerWebSocketSession(socket, {
      onClosed() {},
      onText() {},
    });

    assert.equal(session.sendText("x".repeat(bytes)), true);
    const frame = Buffer.concat(output);
    assert.equal(frame[0], 0x81);
    assert.equal(frame[1] & 0x7f, 127);
    assert.equal(serverPayloadLength(frame), bytes);
  });
}

test("WebSocket decodes a masked 64-bit client frame", () => {
  const socket = capturingSocket([]);
  let received = null;
  const session = new ServerWebSocketSession(socket, {
    onClosed() {},
    onText(text) {
      received = text;
    },
  });
  const payload = Buffer.from("目".repeat(70_000), "utf8");

  session.receive(maskedTextFrame(payload));

  assert.equal(received, payload.toString("utf8"));
  assert.equal(session.isClosed, false);
});

test("WebSocket closes an inbound frame above 4 MiB with code 1009", () => {
  const output = [];
  const socket = capturingSocket(output);
  const session = new ServerWebSocketSession(socket, {
    onClosed() {},
    onText() {
      assert.fail("oversized input must not reach the application");
    },
  });
  const payload = Buffer.alloc(maxWebSocketControlFrameBytes + 1, 0x61);

  session.receive(maskedTextFrame(payload));

  const closeFrame = Buffer.concat(output);
  assert.equal(session.isClosed, true);
  assert.equal(closeFrame[0], 0x88);
  assert.equal(closeFrame.readUInt16BE(2), 1009);
});

test("WebSocket closes instead of retaining an outbound queue above 8 MiB", () => {
  const socket = new Duplex({
    readableHighWaterMark: 1,
    writableHighWaterMark: 1,
    read() {},
    write(_chunk, _encoding, _callback) {
      // Intentionally hold the first write so subsequent frames exercise the
      // session-owned queue instead of the operating-system socket buffer.
    },
  });
  const session = new ServerWebSocketSession(socket, {
    onClosed() {},
    onText() {},
  });
  const payload = "x".repeat(3 * 1024 * 1024);

  assert.equal(session.sendText(payload), true);
  assert.equal(session.sendText(payload), true);
  assert.equal(session.sendText(payload), false);
  assert.equal(session.isClosed, true);
  socket.destroy();
});
