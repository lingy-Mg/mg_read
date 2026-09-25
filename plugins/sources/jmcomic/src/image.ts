/**
 * JM image reconstruction in the source-owned proxy callback.
 * JPEG, WebP and PNG codecs are bundled with their WASM bytes in the single JS artifact.
 * Only one bounded image is decoded per request; no image bytes cross the content API.
 */
import decodeJpeg, { init as initJpeg } from '@jsquash/jpeg/decode.js';
import decodePng, { init as initPngDecode } from '@jsquash/png/decode.js';
import encodePng, { init as initPngEncode } from '@jsquash/png/encode.js';
import decodeWebp, { init as initWebp } from '@jsquash/webp/decode.js';
import jpegWasm from '../node_modules/@jsquash/jpeg/codec/dec/mozjpeg_dec.wasm';
import pngWasm from '../node_modules/@jsquash/png/codec/pkg/squoosh_png_bg.wasm';
import webpWasm from '../node_modules/@jsquash/webp/codec/dec/webp_dec.wasm';

let initialized: Promise<void> | undefined;

async function initialize(): Promise<void> {
  initialized ??= (async () => {
    await Promise.all([
      initJpeg(await WebAssembly.compile(Buffer.from(jpegWasm, 'base64'))),
      initWebp(await WebAssembly.compile(Buffer.from(webpWasm, 'base64'))),
      initPngDecode(Buffer.from(pngWasm, 'base64')),
      initPngEncode(Buffer.from(pngWasm, 'base64')),
    ]);
  })();
  return initialized;
}

export async function restoreImage(bytes: Uint8Array, segments: number): Promise<Uint8Array> {
  if (!Number.isSafeInteger(segments) || segments < 2 || segments > 20 || segments % 2 !== 0) throw new Error('Image segments are invalid.');
  await initialize();
  const source = Buffer.from(bytes);
  const input = source.buffer.slice(source.byteOffset, source.byteOffset + source.byteLength);
  const image = source.subarray(0, 3).equals(Buffer.from([0xff, 0xd8, 0xff])) ? await decodeJpeg(input)
    : source.subarray(0, 4).toString('ascii') === 'RIFF' ? await decodeWebp(input)
      : source.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) ? await decodePng(input)
        : null;
  if (image === null || image.width < 1 || image.height < segments || image.width * image.height > 25_000_000) {
    throw new Error('Image format or dimensions are invalid.');
  }
  const width = image.width;
  const height = image.height;
  const rowBytes = width * 4;
  const decoded = new Uint8ClampedArray(image.data.length);
  const move = Math.floor(height / segments);
  const over = height % segments;
  for (let index = 0; index < segments; index += 1) {
    const sourceY = height - move * (index + 1) - over;
    const destinationY = move * index + (index === 0 ? 0 : over);
    const rows = move + (index === 0 ? over : 0);
    decoded.set(image.data.subarray(sourceY * rowBytes, (sourceY + rows) * rowBytes), destinationY * rowBytes);
  }
  return new Uint8Array(await encodePng({ data: decoded, width, height } as ImageData));
}
