/** Bounded MPEG-TS prefix inspection for HLS joins; no decoding or media storage. */
export type TransportClock = { readonly pts: number; readonly tracks: string };
const packetSize = 188;
const videoTypes = new Set([0x02, 0x1b, 0x24]);

export function readTransportClock(bytes: Uint8Array): TransportClock | undefined {
  let sync = -1;
  for (let index = 0; index < Math.min(4096, bytes.length - packetSize * 2); index += 1) {
    if (bytes[index] === 0x47 && bytes[index + packetSize] === 0x47 && bytes[index + packetSize * 2] === 0x47) { sync = index; break; }
  }
  if (sync < 0) return undefined;
  let pmt: number | undefined;
  const streams = new Map<number, number>();
  for (let index = sync; index + packetSize <= bytes.length; index += packetSize) {
    const packet = bytes.subarray(index, index + packetSize);
    if (packet[0] !== 0x47 || (packet[1]! & 0x80) !== 0 || (packet[3]! & 0xc0) !== 0) return undefined;
    const pid = ((packet[1]! & 31) << 8) | packet[2]!, start = (packet[1]! & 64) !== 0;
    const adaptation = (packet[3]! >> 4) & 3;
    const offset = 4 + (adaptation === 2 || adaptation === 3 ? packet[4]! + 1 : 0);
    if (!(adaptation & 1) || offset >= packetSize || !start) continue;
    const payload = packet.subarray(offset);
    if (pid === 0 || pid === pmt) {
      const section = payload.subarray(payload[0]! + 1);
      if (section.length < 12) continue;
      const end = 3 + (((section[1]! & 15) << 8) | section[2]!) - 4;
      if (end > section.length) continue;
      if (pid === 0 && section[0] === 0) {
        for (let position = 8; position + 4 <= end; position += 4) {
          if (section[position] !== 0 || section[position + 1] !== 0) pmt = ((section[position + 2]! & 31) << 8) | section[position + 3]!;
        }
      } else if (pid === pmt && section[0] === 2) {
        let position = 12 + (((section[10]! & 15) << 8) | section[11]!);
        while (position + 5 <= end) {
          streams.set(((section[position + 1]! & 31) << 8) | section[position + 2]!, section[position]!);
          position += 5 + (((section[position + 3]! & 15) << 8) | section[position + 4]!);
        }
      }
      continue;
    }
    if (!videoTypes.has(streams.get(pid) ?? -1) || payload.length < 14 || payload[0] !== 0 ||
        payload[1] !== 0 || payload[2] !== 1 || payload[3]! < 0xe0 || payload[3]! > 0xef ||
        !(payload[7]! & 128) || payload[8]! < 5) continue;
    const pts = payload.subarray(9, 14);
    if (!(pts[0]! & 1) || !(pts[2]! & 1) || !(pts[4]! & 1)) continue;
    const value = ((pts[0]! >> 1) & 7) * 1073741824 + pts[1]! * 4194304 +
      (pts[2]! >> 1) * 32768 + pts[3]! * 128 + (pts[4]! >> 1);
    return { pts: value / 90000, tracks: [...streams].sort((a, b) => a[0] - b[0]).map(([id, type]) => `${id}:${type}`).join(",") };
  }
  return undefined;
}

/** Signed distance across the MPEG 33-bit timestamp wrap. */
export function transportClockDelta(after: number, before: number): number {
  const wrap = 8589934592 / 90000;
  return ((after - before + wrap / 2) % wrap + wrap) % wrap - wrap / 2;
}
