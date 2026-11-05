/** Yueting's versioned XChaCha20-Poly1305 envelope, independent of host crypto.
 * Pure decoding only: authenticate before JSON parsing, reject malformed bytes,
 * and never expose upstream payloads in errors. Bundled into the single source
 * artifact; Node/Android and Bun use exactly the same implementation.
 */
import { xchacha20poly1305 } from '@noble/ciphers/chacha.js';

const key = Buffer.from('ea9d9d4f9a983fe6f6382f29c7b46b8d6dc47abc6da36662e6ddff8c78902f65', 'hex');

export function decryptObject(payload: string): Record<string, unknown> {
  const hex = payload.replaceAll(/\s/gu, '');
  if (hex.length < 82 || hex.length % 2 !== 0 || !/^[\da-f]+$/iu.test(hex)) {
    throw new Error('Encrypted payload is invalid.');
  }
  const bytes = Buffer.from(hex, 'hex');
  if (bytes[0] !== 1 && bytes[0] !== 2) throw new Error('Encrypted payload version is unsupported.');
  const nonce = bytes.subarray(1, 25);
  const encrypted = bytes[0] === 2 ? bytes.subarray(25).reverse() : bytes.subarray(25);
  let value: unknown;
  try {
    const plain = xchacha20poly1305(key, nonce).decrypt(encrypted);
    value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(plain));
  } catch {
    throw new Error('Encrypted payload authentication or content is invalid.');
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new Error('Source response is invalid.');
  return value as Record<string, unknown>;
}
