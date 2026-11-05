/** Cross-engine authentication regressions. The fixed vector was produced by
 * the previous Node/OpenSSL implementation, independently of noble-ciphers.
 */
import assert from 'node:assert/strict';
import test from 'node:test';
import { xchacha20poly1305 } from '@noble/ciphers/chacha.js';
import { decryptObject } from '../dist/encrypted-payload.mjs';
const vector = "01000102030405060708090a0b0c0d0e0f1011121314151617a41c206e9899f01bbc549a48d729738dd20ccf8c2201e2c42ea0374062f7c0468c5eb1a3e984637cf08b896c69300acdc1101735847f6d589652eea4d443a094cad600bab72d4a689f63095ff5dd8328d7ab7484c8f559236fe72f374974f544bc";
const expected = {id:123,title:'跨引擎验收',chapters:[{index:7,title:'第一集'}]};

test('decodes independent Node/OpenSSL vector for both envelope versions', () => {
  assert.deepEqual(decryptObject(vector), expected);
  const v2 = Buffer.from(vector, 'hex');
  v2[0] = 2; v2.subarray(25).reverse();
  assert.deepEqual(decryptObject(v2.toString('hex')), expected);
  assert.deepEqual(decryptObject(vector.match(/.{1,12}/g).join(' \n')), expected);
});

test('rejects nonce, ciphertext and authentication tag tampering', () => {
  for (const offset of [1, 25, Buffer.from(vector, 'hex').length - 1]) {
    const damaged = Buffer.from(vector, 'hex'); damaged[offset] ^= 1;
    assert.throws(() => decryptObject(damaged.toString('hex')), /authentication/);
  }
});

test('rejects malformed/truncated envelopes and unsupported versions', () => {
  for (const value of ['', '00', vector.slice(1), vector.slice(0, 60), vector + 'zz']) {
    assert.throws(() => decryptObject(value), /invalid/);
  }
  assert.throws(() => decryptObject('03' + vector.slice(2)), /unsupported/);
});

test('authenticated plaintext must still be a valid JSON object', () => {
  const key=Buffer.from('ea9d9d4f9a983fe6f6382f29c7b46b8d6dc47abc6da36662e6ddff8c78902f65','hex');
  const nonce=Buffer.from(vector,'hex').subarray(1,25);
  for (const plain of ['null','[]','42','not-json']) {
    const payload=Buffer.concat([Buffer.from([1]),nonce,xchacha20poly1305(key,nonce).encrypt(Buffer.from(plain))]).toString('hex');
    assert.throws(() => decryptObject(payload), /invalid/);
  }
});
