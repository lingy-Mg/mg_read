import { createRequire as __mgreadCreateRequire } from 'node:module'; const require = __mgreadCreateRequire(import.meta.url);

// src/index.mts
import { randomUUID } from "node:crypto";

// node_modules/@noble/ciphers/utils.js
function isBytes(a) {
  return a instanceof Uint8Array || ArrayBuffer.isView(a) && a.constructor.name === "Uint8Array" && "BYTES_PER_ELEMENT" in a && a.BYTES_PER_ELEMENT === 1;
}
var atitle = (title) => title ? `"${title}" ` : "";
function abool(value, title = "") {
  if (typeof value !== "boolean")
    throw new TypeError(atitle(title) + "expected boolean, got type=" + typeof value);
  return value;
}
function anumber(n, title = "") {
  if (typeof n !== "number")
    throw new TypeError(atitle(title) + "expected number, got " + typeof n);
  if (!Number.isSafeInteger(n) || n < 0)
    throw new RangeError(atitle(title) + "expected integer >= 0, got " + n);
  return n;
}
function abytes(value, length, title = "") {
  if (isBytes(value) && (length === void 0 || value.length === length))
    return value;
  if (length !== void 0)
    anumber(length, "length");
  const bytes = isBytes(value);
  const ofLen = length !== void 0 ? ` of length ${length}` : "";
  const got = bytes ? `length=${value.length}` : `type=${typeof value}`;
  const message = atitle(title) + "expected Uint8Array" + ofLen + ", got " + got;
  if (!bytes)
    throw new TypeError(message);
  throw new RangeError(message);
}
var aobject = (value, label) => {
  if (value === null || typeof value !== "object" || Array.isArray(value))
    throw new TypeError(label === "object" ? "expected valid options object" : `"${label}" expected object, got type=${typeof value}`);
};
function aexists(instance, checkFinished = true) {
  if (instance.destroyed)
    throw new Error("hash was destroyed");
  if (checkFinished && instance.finished)
    throw new Error("digest() was already called");
}
function aoutput(out, instance) {
  abytes(out, void 0, "output");
  const min = instance.outputLen;
  if (!(out.length >= min)) {
    throw new RangeError('"output" expected length >= ' + min);
  }
}
function u32(arr) {
  return new Uint32Array(arr.buffer, arr.byteOffset, Math.floor(arr.byteLength / 4));
}
function clean(...arrays) {
  for (let i = 0; i < arrays.length; i++) {
    arrays[i].fill(0);
  }
}
function createView(arr) {
  return new DataView(arr.buffer, arr.byteOffset, arr.byteLength);
}
var isLE = /* @__PURE__ */ (() => new Uint8Array(new Uint32Array([287454020]).buffer)[0] === 68)();
function byteSwap(word) {
  return word << 24 & 4278190080 | word << 8 & 16711680 | word >>> 8 & 65280 | word >>> 24 & 255;
}
function byteSwap32(arr) {
  for (let i = 0; i < arr.length; i++) {
    arr[i] = byteSwap(arr[i]);
  }
  return arr;
}
var swap32IfBE = isLE ? (u) => u : byteSwap32;
function overlapBytes(a, b) {
  if (!a.byteLength || !b.byteLength)
    return false;
  return a.buffer === b.buffer && // best we can do, may fail with an obscure Proxy
  a.byteOffset < b.byteOffset + b.byteLength && // a starts before b end
  b.byteOffset < a.byteOffset + a.byteLength;
}
function complexOverlapBytes(input, output) {
  if (overlapBytes(input, output) && input.byteOffset < output.byteOffset)
    throw new Error("complex overlap of input and output is not supported");
}
function checkOpts(defaults, opts) {
  aobject(defaults, "defaults");
  aobject(opts, "opts");
  const merged = Object.assign(defaults, opts);
  return merged;
}
function equalBytes(a, b) {
  a = abytes(a);
  b = abytes(b);
  if (a.length !== b.length)
    return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++)
    diff |= a[i] ^ b[i];
  return diff === 0;
}
function wrapMacConstructor(keyLen, macCons, fromMsg) {
  const mac = macCons;
  const getArgs = fromMsg || (() => []);
  const macC = (msg, key2) => mac(key2, ...getArgs(msg)).update(msg).digest();
  const tmp = mac(new Uint8Array(keyLen), ...getArgs(new Uint8Array(0)));
  macC.outputLen = tmp.outputLen;
  macC.blockLen = tmp.blockLen;
  macC.create = (key2, ...args) => mac(key2, ...args);
  return macC;
}
var wrapCipher = /* @__NO_SIDE_EFFECTS__ */ (params, constructor) => {
  function wrappedCipher(key2, ...args) {
    abytes(key2, void 0, "key");
    if (params.nonceLength !== void 0) {
      const nonce = args[0];
      abytes(nonce, params.varSizeNonce ? void 0 : params.nonceLength, "nonce");
    }
    const tagl = params.tagLength;
    const aadStart = params.nonceLength !== void 0 ? 1 : 0;
    if (!params.withAAD) {
      for (let i = aadStart; i < args.length; i++)
        if (isBytes(args[i]))
          throw new Error("AAD not supported");
    }
    if (params.withAAD && args[aadStart] !== void 0)
      abytes(args[aadStart], void 0, "AAD");
    const cipher = constructor(key2, ...args);
    const checkOutput = (fnLength, output) => {
      if (output !== void 0) {
        if (fnLength !== 2)
          throw new Error("cipher output not supported");
        abytes(output, void 0, "output");
      }
    };
    let called = false;
    const wrCipher = {
      encrypt(data, output) {
        if (called)
          throw new Error("cannot encrypt() twice with same key + nonce");
        called = true;
        abytes(data, void 0, "data");
        checkOutput(cipher.encrypt.length, output);
        return cipher.encrypt(data, output);
      },
      decrypt(data, output) {
        abytes(data, void 0, "data");
        if (tagl && data.length < tagl)
          throw new Error('"ciphertext" expected length >= tagLength=' + tagl);
        checkOutput(cipher.decrypt.length, output);
        return cipher.decrypt(data, output);
      }
    };
    return wrCipher;
  }
  Object.assign(wrappedCipher, params);
  return wrappedCipher;
};
function getOutput(expectedLength, out, onlyAligned = true) {
  if (out === void 0)
    return new Uint8Array(expectedLength);
  abytes(out, expectedLength, "output");
  if (onlyAligned && !isAligned32(out))
    throw new Error("invalid output, must be aligned");
  return out;
}
function u64Lengths(dataLength, aadLength, isLE2) {
  anumber(dataLength);
  anumber(aadLength);
  abool(isLE2);
  const num = new Uint8Array(16);
  const view = createView(num);
  view.setBigUint64(0, BigInt(aadLength), isLE2);
  view.setBigUint64(8, BigInt(dataLength), isLE2);
  return num;
}
function isAligned32(bytes) {
  return bytes.byteOffset % 4 === 0;
}
function copyBytes(bytes) {
  return Uint8Array.from(abytes(bytes));
}

// node_modules/@noble/ciphers/_arx.js
var encodeStr = (str) => Uint8Array.from(str.split(""), (c) => c.charCodeAt(0));
var sigma16_32 = /* @__PURE__ */ (() => swap32IfBE(u32(encodeStr("expand 16-byte k"))))();
var sigma32_32 = /* @__PURE__ */ (() => swap32IfBE(u32(encodeStr("expand 32-byte k"))))();
function rotl(a, b) {
  return a << b | a >>> 32 - b;
}
var BLOCK_LEN = 64;
var BLOCK_LEN32 = 16;
var MAX_COUNTER = /* @__PURE__ */ (() => 2 ** 32 - 1)();
var U32_EMPTY = /* @__PURE__ */ Uint32Array.of();
function runCipher(core, sigma, key2, nonce, data, output, counter, rounds) {
  const len = data.length;
  const block = new Uint8Array(BLOCK_LEN);
  const b32 = u32(block);
  const isAligned = isLE && isAligned32(data) && isAligned32(output);
  const d32 = isAligned ? u32(data) : U32_EMPTY;
  const o32 = isAligned ? u32(output) : U32_EMPTY;
  if (!isLE) {
    for (let pos = 0; pos < len; counter++) {
      core(sigma, key2, nonce, b32, counter, rounds);
      swap32IfBE(b32);
      if (counter >= MAX_COUNTER)
        throw new Error("arx: counter overflow");
      const take = Math.min(BLOCK_LEN, len - pos);
      for (let j = 0, posj; j < take; j++) {
        posj = pos + j;
        output[posj] = data[posj] ^ block[j];
      }
      pos += take;
    }
    return;
  }
  for (let pos = 0; pos < len; counter++) {
    core(sigma, key2, nonce, b32, counter, rounds);
    if (counter >= MAX_COUNTER)
      throw new Error("arx: counter overflow");
    const take = Math.min(BLOCK_LEN, len - pos);
    if (isAligned && take === BLOCK_LEN) {
      const pos32 = pos / 4;
      if (pos % 4 !== 0)
        throw new Error("arx: invalid block position");
      for (let j = 0, posj; j < BLOCK_LEN32; j++) {
        posj = pos32 + j;
        o32[posj] = d32[posj] ^ b32[j];
      }
      pos += BLOCK_LEN;
      continue;
    }
    for (let j = 0, posj; j < take; j++) {
      posj = pos + j;
      output[posj] = data[posj] ^ block[j];
    }
    pos += take;
  }
}
function createCipher(core, opts) {
  const { allowShortKeys, extendNonceFn, counterLength, counterRight, rounds } = checkOpts({ allowShortKeys: false, counterLength: 8, counterRight: false, rounds: 20 }, opts);
  if (typeof core !== "function")
    throw new Error("core must be a function");
  anumber(counterLength);
  anumber(rounds);
  abool(counterRight);
  abool(allowShortKeys);
  return (key2, nonce, data, output, counter = 0) => {
    abytes(key2, void 0, "key");
    abytes(nonce, void 0, "nonce");
    abytes(data, void 0, "data");
    const len = data.length;
    const hasOutput = output !== void 0;
    output = getOutput(len, output, false);
    if (hasOutput)
      complexOverlapBytes(data, output);
    anumber(counter);
    if (counter < 0 || counter >= MAX_COUNTER)
      throw new Error("arx: counter overflow");
    const toClean = [];
    let l = key2.length;
    let k;
    let sigma;
    if (l === 32) {
      toClean.push(k = copyBytes(key2));
      sigma = sigma32_32;
    } else if (l === 16 && allowShortKeys) {
      k = new Uint8Array(32);
      k.set(key2);
      k.set(key2, 16);
      sigma = sigma16_32;
      toClean.push(k);
    } else {
      abytes(key2, 32, "arx key");
      throw new Error("invalid key size");
    }
    if (!isLE || !isAligned32(nonce))
      toClean.push(nonce = copyBytes(nonce));
    let k32 = u32(k);
    if (extendNonceFn) {
      if (nonce.length !== 24)
        throw new Error("arx: extended nonce must be 24 bytes");
      const n16 = nonce.subarray(0, 16);
      if (isLE)
        extendNonceFn(sigma, k32, u32(n16), k32);
      else {
        const sigmaRaw = swap32IfBE(Uint32Array.from(sigma));
        extendNonceFn(sigmaRaw, k32, u32(n16), k32);
        clean(sigmaRaw);
        swap32IfBE(k32);
      }
      nonce = nonce.subarray(16);
    } else if (!isLE)
      swap32IfBE(k32);
    const nonceNcLen = 16 - counterLength;
    if (nonceNcLen !== nonce.length)
      throw new Error(`arx: nonce must be ${nonceNcLen} or 16 bytes`);
    if (nonceNcLen !== 12) {
      const nc = new Uint8Array(12);
      nc.set(nonce, counterRight ? 0 : 12 - nonce.length);
      nonce = nc;
      toClean.push(nonce);
    }
    const n32 = swap32IfBE(u32(nonce));
    try {
      runCipher(core, sigma, k32, n32, data, output, counter, rounds);
      return output;
    } finally {
      clean(...toClean);
    }
  };
}

// node_modules/@noble/ciphers/_poly1305.js
function u8to16(a, i) {
  return a[i++] & 255 | (a[i++] & 255) << 8;
}
var Poly1305 = class {
  blockLen = 16;
  outputLen = 16;
  buffer = new Uint8Array(16);
  r = new Uint16Array(10);
  // Allocating 1 array with .subarray() here is slower than 3
  h = new Uint16Array(10);
  pad = new Uint16Array(8);
  pos = 0;
  finished = false;
  destroyed = false;
  // Can be speed-up using BigUint64Array, at the cost of complexity
  constructor(key2) {
    key2 = copyBytes(abytes(key2, 32, "key"));
    const t0 = u8to16(key2, 0);
    const t1 = u8to16(key2, 2);
    const t2 = u8to16(key2, 4);
    const t3 = u8to16(key2, 6);
    const t4 = u8to16(key2, 8);
    const t5 = u8to16(key2, 10);
    const t6 = u8to16(key2, 12);
    const t7 = u8to16(key2, 14);
    this.r[0] = t0 & 8191;
    this.r[1] = (t0 >>> 13 | t1 << 3) & 8191;
    this.r[2] = (t1 >>> 10 | t2 << 6) & 7939;
    this.r[3] = (t2 >>> 7 | t3 << 9) & 8191;
    this.r[4] = (t3 >>> 4 | t4 << 12) & 255;
    this.r[5] = t4 >>> 1 & 8190;
    this.r[6] = (t4 >>> 14 | t5 << 2) & 8191;
    this.r[7] = (t5 >>> 11 | t6 << 5) & 8065;
    this.r[8] = (t6 >>> 8 | t7 << 8) & 8191;
    this.r[9] = t7 >>> 5 & 127;
    for (let i = 0; i < 8; i++)
      this.pad[i] = u8to16(key2, 16 + 2 * i);
  }
  process(data, offset, isLast = false) {
    const hibit = isLast ? 0 : 1 << 11;
    const { h, r } = this;
    const r0 = r[0];
    const r1 = r[1];
    const r2 = r[2];
    const r3 = r[3];
    const r4 = r[4];
    const r5 = r[5];
    const r6 = r[6];
    const r7 = r[7];
    const r8 = r[8];
    const r9 = r[9];
    const t0 = u8to16(data, offset + 0);
    const t1 = u8to16(data, offset + 2);
    const t2 = u8to16(data, offset + 4);
    const t3 = u8to16(data, offset + 6);
    const t4 = u8to16(data, offset + 8);
    const t5 = u8to16(data, offset + 10);
    const t6 = u8to16(data, offset + 12);
    const t7 = u8to16(data, offset + 14);
    let h0 = h[0] + (t0 & 8191);
    let h1 = h[1] + ((t0 >>> 13 | t1 << 3) & 8191);
    let h2 = h[2] + ((t1 >>> 10 | t2 << 6) & 8191);
    let h3 = h[3] + ((t2 >>> 7 | t3 << 9) & 8191);
    let h4 = h[4] + ((t3 >>> 4 | t4 << 12) & 8191);
    let h5 = h[5] + (t4 >>> 1 & 8191);
    let h6 = h[6] + ((t4 >>> 14 | t5 << 2) & 8191);
    let h7 = h[7] + ((t5 >>> 11 | t6 << 5) & 8191);
    let h8 = h[8] + ((t6 >>> 8 | t7 << 8) & 8191);
    let h9 = h[9] + (t7 >>> 5 | hibit);
    let c = 0;
    let d0 = c + h0 * r0 + h1 * (5 * r9) + h2 * (5 * r8) + h3 * (5 * r7) + h4 * (5 * r6);
    c = d0 >>> 13;
    d0 &= 8191;
    d0 += h5 * (5 * r5) + h6 * (5 * r4) + h7 * (5 * r3) + h8 * (5 * r2) + h9 * (5 * r1);
    c += d0 >>> 13;
    d0 &= 8191;
    let d1 = c + h0 * r1 + h1 * r0 + h2 * (5 * r9) + h3 * (5 * r8) + h4 * (5 * r7);
    c = d1 >>> 13;
    d1 &= 8191;
    d1 += h5 * (5 * r6) + h6 * (5 * r5) + h7 * (5 * r4) + h8 * (5 * r3) + h9 * (5 * r2);
    c += d1 >>> 13;
    d1 &= 8191;
    let d2 = c + h0 * r2 + h1 * r1 + h2 * r0 + h3 * (5 * r9) + h4 * (5 * r8);
    c = d2 >>> 13;
    d2 &= 8191;
    d2 += h5 * (5 * r7) + h6 * (5 * r6) + h7 * (5 * r5) + h8 * (5 * r4) + h9 * (5 * r3);
    c += d2 >>> 13;
    d2 &= 8191;
    let d3 = c + h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * (5 * r9);
    c = d3 >>> 13;
    d3 &= 8191;
    d3 += h5 * (5 * r8) + h6 * (5 * r7) + h7 * (5 * r6) + h8 * (5 * r5) + h9 * (5 * r4);
    c += d3 >>> 13;
    d3 &= 8191;
    let d4 = c + h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0;
    c = d4 >>> 13;
    d4 &= 8191;
    d4 += h5 * (5 * r9) + h6 * (5 * r8) + h7 * (5 * r7) + h8 * (5 * r6) + h9 * (5 * r5);
    c += d4 >>> 13;
    d4 &= 8191;
    let d5 = c + h0 * r5 + h1 * r4 + h2 * r3 + h3 * r2 + h4 * r1;
    c = d5 >>> 13;
    d5 &= 8191;
    d5 += h5 * r0 + h6 * (5 * r9) + h7 * (5 * r8) + h8 * (5 * r7) + h9 * (5 * r6);
    c += d5 >>> 13;
    d5 &= 8191;
    let d6 = c + h0 * r6 + h1 * r5 + h2 * r4 + h3 * r3 + h4 * r2;
    c = d6 >>> 13;
    d6 &= 8191;
    d6 += h5 * r1 + h6 * r0 + h7 * (5 * r9) + h8 * (5 * r8) + h9 * (5 * r7);
    c += d6 >>> 13;
    d6 &= 8191;
    let d7 = c + h0 * r7 + h1 * r6 + h2 * r5 + h3 * r4 + h4 * r3;
    c = d7 >>> 13;
    d7 &= 8191;
    d7 += h5 * r2 + h6 * r1 + h7 * r0 + h8 * (5 * r9) + h9 * (5 * r8);
    c += d7 >>> 13;
    d7 &= 8191;
    let d8 = c + h0 * r8 + h1 * r7 + h2 * r6 + h3 * r5 + h4 * r4;
    c = d8 >>> 13;
    d8 &= 8191;
    d8 += h5 * r3 + h6 * r2 + h7 * r1 + h8 * r0 + h9 * (5 * r9);
    c += d8 >>> 13;
    d8 &= 8191;
    let d9 = c + h0 * r9 + h1 * r8 + h2 * r7 + h3 * r6 + h4 * r5;
    c = d9 >>> 13;
    d9 &= 8191;
    d9 += h5 * r4 + h6 * r3 + h7 * r2 + h8 * r1 + h9 * r0;
    c += d9 >>> 13;
    d9 &= 8191;
    c = (c << 2) + c | 0;
    c = c + d0 | 0;
    d0 = c & 8191;
    c = c >>> 13;
    d1 += c;
    h[0] = d0;
    h[1] = d1;
    h[2] = d2;
    h[3] = d3;
    h[4] = d4;
    h[5] = d5;
    h[6] = d6;
    h[7] = d7;
    h[8] = d8;
    h[9] = d9;
  }
  finalize() {
    const { h, pad } = this;
    const g = new Uint16Array(10);
    let c = h[1] >>> 13;
    h[1] &= 8191;
    for (let i = 2; i < 10; i++) {
      h[i] += c;
      c = h[i] >>> 13;
      h[i] &= 8191;
    }
    h[0] += c * 5;
    c = h[0] >>> 13;
    h[0] &= 8191;
    h[1] += c;
    c = h[1] >>> 13;
    h[1] &= 8191;
    h[2] += c;
    g[0] = h[0] + 5;
    c = g[0] >>> 13;
    g[0] &= 8191;
    for (let i = 1; i < 10; i++) {
      g[i] = h[i] + c;
      c = g[i] >>> 13;
      g[i] &= 8191;
    }
    g[9] -= 1 << 13;
    let mask = (c ^ 1) - 1;
    for (let i = 0; i < 10; i++)
      g[i] &= mask;
    mask = ~mask;
    for (let i = 0; i < 10; i++)
      h[i] = h[i] & mask | g[i];
    h[0] = (h[0] | h[1] << 13) & 65535;
    h[1] = (h[1] >>> 3 | h[2] << 10) & 65535;
    h[2] = (h[2] >>> 6 | h[3] << 7) & 65535;
    h[3] = (h[3] >>> 9 | h[4] << 4) & 65535;
    h[4] = (h[4] >>> 12 | h[5] << 1 | h[6] << 14) & 65535;
    h[5] = (h[6] >>> 2 | h[7] << 11) & 65535;
    h[6] = (h[7] >>> 5 | h[8] << 8) & 65535;
    h[7] = (h[8] >>> 8 | h[9] << 5) & 65535;
    let f = h[0] + pad[0];
    h[0] = f & 65535;
    for (let i = 1; i < 8; i++) {
      f = (h[i] + pad[i] | 0) + (f >>> 16) | 0;
      h[i] = f & 65535;
    }
    clean(g);
  }
  update(data) {
    aexists(this);
    abytes(data);
    data = copyBytes(data);
    const { buffer, blockLen } = this;
    const len = data.length;
    for (let pos = 0; pos < len; ) {
      const take = Math.min(blockLen - this.pos, len - pos);
      if (take === blockLen) {
        for (; blockLen <= len - pos; pos += blockLen)
          this.process(data, pos);
        continue;
      }
      buffer.set(data.subarray(pos, pos + take), this.pos);
      this.pos += take;
      pos += take;
      if (this.pos === blockLen) {
        this.process(buffer, 0, false);
        this.pos = 0;
      }
    }
    return this;
  }
  destroy() {
    this.destroyed = true;
    clean(this.h, this.r, this.buffer, this.pad);
  }
  digestInto(out) {
    aexists(this);
    aoutput(out, this);
    this.finished = true;
    const { buffer, h } = this;
    let { pos } = this;
    if (pos) {
      buffer[pos++] = 1;
      for (; pos < 16; pos++)
        buffer[pos] = 0;
      this.process(buffer, 0, true);
    }
    this.finalize();
    let opos = 0;
    for (let i = 0; i < 8; i++) {
      out[opos++] = h[i] >>> 0;
      out[opos++] = h[i] >>> 8;
    }
  }
  digest() {
    const { buffer, outputLen } = this;
    this.digestInto(buffer);
    const res = buffer.slice(0, outputLen);
    this.destroy();
    return res;
  }
};
var poly1305 = /* @__PURE__ */ wrapMacConstructor(32, (key2) => new Poly1305(key2));

// node_modules/@noble/ciphers/chacha.js
function chachaCore(s, k, n, out, cnt, rounds = 20) {
  let y00 = s[0], y01 = s[1], y02 = s[2], y03 = s[3], y04 = k[0], y05 = k[1], y06 = k[2], y07 = k[3], y08 = k[4], y09 = k[5], y10 = k[6], y11 = k[7], y12 = cnt, y13 = n[0], y14 = n[1], y15 = n[2];
  let x00 = y00, x01 = y01, x02 = y02, x03 = y03, x04 = y04, x05 = y05, x06 = y06, x07 = y07, x08 = y08, x09 = y09, x10 = y10, x11 = y11, x12 = y12, x13 = y13, x14 = y14, x15 = y15;
  for (let r = 0; r < rounds; r += 2) {
    x00 = x00 + x04 | 0;
    x12 = rotl(x12 ^ x00, 16);
    x08 = x08 + x12 | 0;
    x04 = rotl(x04 ^ x08, 12);
    x00 = x00 + x04 | 0;
    x12 = rotl(x12 ^ x00, 8);
    x08 = x08 + x12 | 0;
    x04 = rotl(x04 ^ x08, 7);
    x01 = x01 + x05 | 0;
    x13 = rotl(x13 ^ x01, 16);
    x09 = x09 + x13 | 0;
    x05 = rotl(x05 ^ x09, 12);
    x01 = x01 + x05 | 0;
    x13 = rotl(x13 ^ x01, 8);
    x09 = x09 + x13 | 0;
    x05 = rotl(x05 ^ x09, 7);
    x02 = x02 + x06 | 0;
    x14 = rotl(x14 ^ x02, 16);
    x10 = x10 + x14 | 0;
    x06 = rotl(x06 ^ x10, 12);
    x02 = x02 + x06 | 0;
    x14 = rotl(x14 ^ x02, 8);
    x10 = x10 + x14 | 0;
    x06 = rotl(x06 ^ x10, 7);
    x03 = x03 + x07 | 0;
    x15 = rotl(x15 ^ x03, 16);
    x11 = x11 + x15 | 0;
    x07 = rotl(x07 ^ x11, 12);
    x03 = x03 + x07 | 0;
    x15 = rotl(x15 ^ x03, 8);
    x11 = x11 + x15 | 0;
    x07 = rotl(x07 ^ x11, 7);
    x00 = x00 + x05 | 0;
    x15 = rotl(x15 ^ x00, 16);
    x10 = x10 + x15 | 0;
    x05 = rotl(x05 ^ x10, 12);
    x00 = x00 + x05 | 0;
    x15 = rotl(x15 ^ x00, 8);
    x10 = x10 + x15 | 0;
    x05 = rotl(x05 ^ x10, 7);
    x01 = x01 + x06 | 0;
    x12 = rotl(x12 ^ x01, 16);
    x11 = x11 + x12 | 0;
    x06 = rotl(x06 ^ x11, 12);
    x01 = x01 + x06 | 0;
    x12 = rotl(x12 ^ x01, 8);
    x11 = x11 + x12 | 0;
    x06 = rotl(x06 ^ x11, 7);
    x02 = x02 + x07 | 0;
    x13 = rotl(x13 ^ x02, 16);
    x08 = x08 + x13 | 0;
    x07 = rotl(x07 ^ x08, 12);
    x02 = x02 + x07 | 0;
    x13 = rotl(x13 ^ x02, 8);
    x08 = x08 + x13 | 0;
    x07 = rotl(x07 ^ x08, 7);
    x03 = x03 + x04 | 0;
    x14 = rotl(x14 ^ x03, 16);
    x09 = x09 + x14 | 0;
    x04 = rotl(x04 ^ x09, 12);
    x03 = x03 + x04 | 0;
    x14 = rotl(x14 ^ x03, 8);
    x09 = x09 + x14 | 0;
    x04 = rotl(x04 ^ x09, 7);
  }
  let oi = 0;
  out[oi++] = y00 + x00 | 0;
  out[oi++] = y01 + x01 | 0;
  out[oi++] = y02 + x02 | 0;
  out[oi++] = y03 + x03 | 0;
  out[oi++] = y04 + x04 | 0;
  out[oi++] = y05 + x05 | 0;
  out[oi++] = y06 + x06 | 0;
  out[oi++] = y07 + x07 | 0;
  out[oi++] = y08 + x08 | 0;
  out[oi++] = y09 + x09 | 0;
  out[oi++] = y10 + x10 | 0;
  out[oi++] = y11 + x11 | 0;
  out[oi++] = y12 + x12 | 0;
  out[oi++] = y13 + x13 | 0;
  out[oi++] = y14 + x14 | 0;
  out[oi++] = y15 + x15 | 0;
}
function hchacha(s, k, i, out) {
  const s2 = isLE ? s : swap32IfBE(s.slice(0, 4));
  const k2 = isLE ? k : swap32IfBE(k.slice(0, 8));
  const i2 = isLE ? i : swap32IfBE(i.slice(0, 4));
  const t = new Uint32Array(16);
  chachaCore(s2, k2, i2.subarray(1), t, i2[0]);
  let oi = 0;
  out[oi++] = t[0] - s2[0] | 0;
  out[oi++] = t[1] - s2[1] | 0;
  out[oi++] = t[2] - s2[2] | 0;
  out[oi++] = t[3] - s2[3] | 0;
  out[oi++] = t[12] - i2[0] | 0;
  out[oi++] = t[13] - i2[1] | 0;
  out[oi++] = t[14] - i2[2] | 0;
  out[oi++] = t[15] - i2[3] | 0;
  swap32IfBE(out);
  if (!isLE)
    clean(s2, k2, i2);
  clean(t);
}
var xchacha20 = /* @__PURE__ */ createCipher(chachaCore, {
  counterRight: false,
  counterLength: 8,
  extendNonceFn: hchacha,
  allowShortKeys: false
});
var ZEROS16 = /* @__PURE__ */ new Uint8Array(16);
var updatePadded = (h, msg) => {
  h.update(msg);
  const leftover = msg.length % 16;
  if (leftover)
    h.update(ZEROS16.subarray(leftover));
};
var ZEROS32 = /* @__PURE__ */ new Uint8Array(32);
function computeTag(fn, key2, nonce, ciphertext, AAD) {
  if (AAD !== void 0)
    abytes(AAD, void 0, "AAD");
  const authKey = fn(key2, nonce, ZEROS32);
  const lengths = u64Lengths(ciphertext.length, AAD ? AAD.length : 0, true);
  const h = poly1305.create(authKey);
  if (AAD)
    updatePadded(h, AAD);
  updatePadded(h, ciphertext);
  h.update(lengths);
  const res = h.digest();
  clean(authKey, lengths);
  return res;
}
var _poly1305_aead = (xorStream) => (key2, nonce, AAD) => {
  const tagLength = 16;
  return {
    encrypt(plaintext, output) {
      const plength = plaintext.length;
      output = getOutput(plength + tagLength, output, false);
      output.set(plaintext);
      const oPlain = output.subarray(0, -tagLength);
      xorStream(key2, nonce, oPlain, oPlain, 1);
      const tag = computeTag(xorStream, key2, nonce, oPlain, AAD);
      output.set(tag, plength);
      clean(tag);
      return output;
    },
    decrypt(ciphertext, output) {
      output = getOutput(ciphertext.length - tagLength, output, false);
      const data = ciphertext.subarray(0, -tagLength);
      const passedTag = ciphertext.subarray(-tagLength);
      const tag = computeTag(xorStream, key2, nonce, data, AAD);
      if (!equalBytes(passedTag, tag)) {
        clean(tag);
        throw new Error("invalid tag");
      }
      output.set(ciphertext.subarray(0, -tagLength));
      xorStream(key2, nonce, output, output, 1);
      clean(tag);
      return output;
    }
  };
};
var xchacha20poly1305 = /* @__PURE__ */ wrapCipher(
  { blockSize: 64, nonceLength: 24, tagLength: 16, withAAD: true },
  /* @__PURE__ */ _poly1305_aead(xchacha20)
);

// src/encrypted-payload.mts
var key = Buffer.from("ea9d9d4f9a983fe6f6382f29c7b46b8d6dc47abc6da36662e6ddff8c78902f65", "hex");
function decryptObject(payload) {
  const hex = payload.replaceAll(/\s/gu, "");
  if (hex.length < 82 || hex.length % 2 !== 0 || !/^[\da-f]+$/iu.test(hex)) {
    throw new Error("Encrypted payload is invalid.");
  }
  const bytes = Buffer.from(hex, "hex");
  if (bytes[0] !== 1 && bytes[0] !== 2) throw new Error("Encrypted payload version is unsupported.");
  const nonce = bytes.subarray(1, 25);
  const encrypted = bytes[0] === 2 ? bytes.subarray(25).reverse() : bytes.subarray(25);
  let value;
  try {
    const plain = xchacha20poly1305(key, nonce).decrypt(encrypted);
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(plain));
  } catch {
    throw new Error("Encrypted payload authentication or content is invalid.");
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error("Source response is invalid.");
  return value;
}

// src/discovery-channels.ts
var channels = [
  {
    "id": "novel",
    "title": "小说",
    "category": "2",
    "classId": ""
  },
  {
    "id": "storytelling",
    "title": "评书",
    "category": "1",
    "classId": ""
  },
  {
    "id": "fantasy",
    "title": "玄幻奇幻",
    "category": "2",
    "classId": "46"
  },
  {
    "id": "wuxia",
    "title": "武侠小说",
    "category": "2",
    "classId": "11"
  },
  {
    "id": "romance",
    "title": "言情通俗",
    "category": "2",
    "classId": "19"
  },
  {
    "id": "type-21",
    "title": "相声小品",
    "category": "2",
    "classId": "21"
  },
  {
    "id": "thriller",
    "title": "恐怖惊悚",
    "category": "2",
    "classId": "14"
  },
  {
    "id": "type-17",
    "title": "官场商战",
    "category": "2",
    "classId": "17"
  },
  {
    "id": "history",
    "title": "历史军事",
    "category": "2",
    "classId": "15"
  },
  {
    "id": "type-9",
    "title": "百家讲坛",
    "category": "2",
    "classId": "9"
  },
  {
    "id": "type-16",
    "title": "刑侦反腐",
    "category": "2",
    "classId": "16"
  },
  {
    "id": "type-10",
    "title": "有声文学",
    "category": "2",
    "classId": "10"
  },
  {
    "id": "type-18",
    "title": "人物纪实",
    "category": "2",
    "classId": "18"
  },
  {
    "id": "radio-drama",
    "title": "广播剧",
    "category": "2",
    "classId": "36"
  },
  {
    "id": "type-22",
    "title": "英文读物",
    "category": "2",
    "classId": "22"
  },
  {
    "id": "type-23",
    "title": "轻音清心",
    "category": "2",
    "classId": "23"
  },
  {
    "id": "type-31",
    "title": "二人转",
    "category": "2",
    "classId": "31"
  },
  {
    "id": "type-33",
    "title": "健康养生",
    "category": "2",
    "classId": "33"
  },
  {
    "id": "type-34",
    "title": "综艺娱乐",
    "category": "2",
    "classId": "34"
  },
  {
    "id": "type-40",
    "title": "头条",
    "category": "2",
    "classId": "40"
  },
  {
    "id": "type-38",
    "title": "戏曲",
    "category": "2",
    "classId": "38"
  },
  {
    "id": "type-41",
    "title": "脱口秀",
    "category": "2",
    "classId": "41"
  },
  {
    "id": "type-42",
    "title": "商业财经",
    "category": "2",
    "classId": "42"
  },
  {
    "id": "type-43",
    "title": "亲子教育",
    "category": "2",
    "classId": "43"
  },
  {
    "id": "type-44",
    "title": "教育培训",
    "category": "2",
    "classId": "44"
  },
  {
    "id": "type-45",
    "title": "时尚生活",
    "category": "2",
    "classId": "45"
  },
  {
    "id": "children",
    "title": "童话寓言",
    "category": "2",
    "classId": "20"
  },
  {
    "id": "shan-tianfang",
    "title": "单田芳",
    "category": "1",
    "classId": "1"
  },
  {
    "id": "liu-lanfang",
    "title": "刘兰芳",
    "category": "1",
    "classId": "2"
  },
  {
    "id": "tian-lianyuan",
    "title": "田连元",
    "category": "1",
    "classId": "3"
  },
  {
    "id": "teller-4",
    "title": "袁阔成",
    "category": "1",
    "classId": "4"
  },
  {
    "id": "teller-5",
    "title": "连丽如",
    "category": "1",
    "classId": "5"
  },
  {
    "id": "teller-8",
    "title": "孙一",
    "category": "1",
    "classId": "8"
  },
  {
    "id": "teller-30",
    "title": "王子封臣",
    "category": "1",
    "classId": "30"
  },
  {
    "id": "teller-25",
    "title": "马长辉",
    "category": "1",
    "classId": "25"
  },
  {
    "id": "teller-26",
    "title": "昊儒书场",
    "category": "1",
    "classId": "26"
  },
  {
    "id": "teller-27",
    "title": "王军",
    "category": "1",
    "classId": "27"
  },
  {
    "id": "teller-28",
    "title": "王玥波",
    "category": "1",
    "classId": "28"
  },
  {
    "id": "teller-29",
    "title": "石连君",
    "category": "1",
    "classId": "29"
  },
  {
    "id": "teller-12",
    "title": "粤语评书",
    "category": "1",
    "classId": "12"
  },
  {
    "id": "teller-35",
    "title": "关永超",
    "category": "1",
    "classId": "35"
  },
  {
    "id": "teller-6",
    "title": "张少佐",
    "category": "1",
    "classId": "6"
  },
  {
    "id": "teller-7",
    "title": "田战义",
    "category": "1",
    "classId": "7"
  },
  {
    "id": "teller-13",
    "title": "其他评书",
    "category": "1",
    "classId": "13"
  }
];
var sorts = [["comprehensive", "综合排序"], ["popular", "播放最多"], ["updated", "最近更新"], ["new", "最新发布"]];
var statuses = [["all", "全部状态"], ["0", "已完结"], ["1", "连载中"]];

// src/discovery-page.ts
function position(cursor, target) {
  if (cursor === null) return { page: 1, offset: 0 };
  const prefix = target + ":";
  const value = cursor.startsWith(prefix) ? cursor.slice(prefix.length) : "";
  const match = /^(\d+)(?::(\d+))?$/u.exec(value);
  const page = Number(match?.[1]), offset = Number(match?.[2] ?? 0);
  if (!match || !Number.isSafeInteger(page) || page < 1 || page > 1e4 || !Number.isSafeInteger(offset) || offset < 0 || offset > 1e4) throw new Error("Discovery cursor is invalid.");
  return { page, offset };
}

// src/index.mts
var catalogRoot = "https://json.tingyou8.vip/azybk/json_v1/";
var apiRoot = "https://tingyou.fm/listening-api/";
var appAgent = "zybk/1.0.6";
var context;
var listeningSession = "";
var deferredGroups = true;
async function activate(next) {
  context = next;
  listeningSession = randomUUID();
  next.log.info("source_activated");
}
async function search(request) {
  const query = request.query.trim();
  if (query === "") return frozen({ items: [], nextCursor: null, totalCount: 0 });
  const page = cursorPage(request.cursor, "search"), data = await listeningRequest("search", { keyword: query, page }), values = records(data.results), items = summaries(values).slice(0, clamp(request.pageSize));
  return frozen({ items, nextCursor: data.has_more === true ? `search:${page + 1}` : null, totalCount: nonNegative(data.total) });
}
async function searchSuggestions(_request) {
  return frozen({ items: [], nextCursor: null });
}
async function discover(request) {
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error("Initial discovery request is invalid.");
    const components = [];
    for (const id of ["novel", "storytelling"]) {
      const result = await discover({ target: "channel:" + id, cursor: null, collectionId: null, pageSize: Math.min(6, clamp(request.pageSize)) });
      if (result.kind === "document") components.push(...result.document.components);
    }
    for (const [category, title] of [["2", "全部听书分类"], ["1", "评书与主播"]]) {
      components.push({ type: "section", id: "yueting-channels-" + category, title, subtitle: null, icon: "explore", children: [{ type: "categoryCollection", id: "yueting-channel-list-" + category, layout: "chips", categories: channels.filter((channel2) => channel2.category === category).map((channel2) => ({ id: channel2.id, title: channel2.title, target: "channel:" + channel2.id, count: null, url: null, icon: "audio" })) }] });
    }
    return { kind: "document", document: { components } };
  }
  const match = /^channel:([a-z0-9-]+)(?::sort:([a-z]+):status:(all|0|1))?$/u.exec(request.target);
  const channel = channels.find((value) => value.id === match?.[1]), sort = match?.[2] ?? "comprehensive", status = match?.[3] ?? "all";
  if (!channel || !sorts.some(([id]) => id === sort)) throw new Error("Discovery target is invalid.");
  const suffix = sort === "comprehensive" && status === "all" ? "" : ":" + sort + ":" + status;
  const collectionId = "yueting:" + channel.id + suffix;
  if (request.collectionId !== null && request.collectionId !== collectionId) throw new Error("Discovery collection is invalid.");
  let { page, offset } = position(request.cursor, request.target);
  const values = [];
  let continuation = null;
  for (let scan = 0; scan < 5; scan++) {
    const prefix = channel.classId === "" ? "categories/" + channel.category : "types/" + channel.classId;
    const data = decryptObject(await getPayload(prefix + "/" + sort + "/p" + page));
    const raw = records(first(data.data, data.results, data));
    while (offset < raw.length && values.length < clamp(request.pageSize)) {
      const value = raw[offset++];
      if (status !== "all" && String(value.status) !== status) continue;
      values.push(...summaries([value]));
    }
    const pages = nonNegative(data.pages), more = raw.length > 0 && (pages === null || page < pages);
    continuation = offset < raw.length ? { target: request.target, cursor: request.target + ":" + page + ":" + offset } : more && page < 1e4 ? { target: request.target, cursor: request.target + ":" + (page + 1) + ":0" } : null;
    if (values.length >= clamp(request.pageSize) || !continuation) break;
    page++;
    offset = 0;
  }
  const items = values.map((content) => ({ content, rank: null, metric: null, recommendation: null }));
  const filters = [{ type: "categoryCollection", id: collectionId + ":sorts", layout: "chips", categories: sorts.map(([id, title]) => ({ id, title, target: "channel:" + channel.id + ":sort:" + id + ":status:" + status, count: null, url: null, icon: "audio" })) }, { type: "categoryCollection", id: collectionId + ":statuses", layout: "chips", categories: statuses.map(([id, title]) => ({ id, title, target: "channel:" + channel.id + ":sort:" + sort + ":status:" + id, count: null, url: null, icon: id === "0" ? "completed" : "audio" })) }];
  if (request.collectionId !== null) return { kind: "append", collectionId, items, continuation };
  return { kind: "document", document: { components: [{ type: "section", id: collectionId + ":section", title: channel.title, subtitle: null, icon: "audio", children: [{ type: "contentCollection", id: collectionId, layout: "coverGrid", items, continuation }, ...filters] }] } };
}
async function getDetail(request) {
  const id = contentId(request.id), data = decryptObject(await getPayload(`album_info/${encodeURIComponent(id)}`)), item = summary(data, id);
  return frozen({ ...item, aliases: [], catalogUrl: `${catalogRoot}album_chapters/${encodeURIComponent(id)}` });
}
async function getChapters(request) {
  const id = contentId(request.id), data = decryptObject(await getPayload(`album_chapters/${encodeURIComponent(id)}`)), items = records(data.chapters).map((value, index) => chapter(id, value, index)).filter(notNull);
  if (items.length <= 5e3) {
    if (request.groupId !== void 0) throw new Error("Requested chapter group is unavailable.");
    return frozen({ items, groups: items.length === 0 ? [] : [frozen({ id: `group:${id}:main`, title: "节目", order: 0, episodes: items })] });
  }
  const groups = chapterGroups(id, items);
  if (request.groupId !== void 0) {
    const group = groups.find((value) => value.id === request.groupId);
    if (group === void 0) throw new Error("Requested chapter group is unavailable.");
    return frozen({ items: group.episodes, groups: [frozen({ ...group, order: 0 })] });
  }
  if (request.supportsDeferredGroups !== true) throw new Error("This catalog requires deferred chapter groups.");
  const projected = groups.map((group, index) => index === 0 ? group : frozen({ ...group, episodes: [], deferred: true }));
  return frozen({ items: groups[0]?.episodes ?? [], groups: projected });
}
async function getContent(request) {
  const albumId = contentId(request.id), chapterIndex = chapterNative(request.chapterId, albumId), data = await listeningRequest("play", { album_id: albumId, chapter_idx: Number(chapterIndex) }), upstream = text(data.play_url);
  if (!safeUrl(upstream)) throw new Error("Audio address is unavailable.");
  const mediaHeaders = { Referer: "https://tingyou.fm/" };
  return frozen({ chapterId: request.chapterId, contentKind: "audio", title: nullable(data.title), updatedAt: null, text: null, pages: [], media: { url: requireContext().resource.proxy({ kind: "audio", url: upstream, headers: mediaHeaders }), resourceType: "audio", resourcePolicy: "sessionOnly", expiresAt: null, mimeType: /\.m4a(?:$|[?#])/iu.test(upstream) ? "audio/mp4" : "audio/mpeg", headers: mediaHeaders } });
}
async function listeningRequest(path, body) {
  const raw = await requestText(new URL(path, apiRoot).toString(), { method: "POST", headers: { Accept: "application/json", "Content-Type": "application/json", "x-listening-timezone": "Asia/Shanghai", "x-listening-session": listeningSession }, body: JSON.stringify(body) }), value = parseJson(raw);
  if (!isObject(value)) throw new Error("Source response is invalid.");
  return value;
}
async function getPayload(path) {
  const raw = await requestText(new URL(path, catalogRoot).toString(), { headers: { "User-Agent": appAgent } }), value = parseJson(raw);
  return payloadOf(value);
}
async function requestText(url, init) {
  const response = await requireContext().http.fetch(url, init);
  if (!response.ok) throw new Error("Source request failed.");
  return await response.text();
}
function payloadOf(value) {
  if (isObject(value)) {
    const payload = text(value.payload);
    if (payload !== "") return payload;
  }
  const raw = text(value);
  if (raw !== "") return raw;
  throw new Error("Encrypted payload is missing.");
}
function summaries(values) {
  const result = /* @__PURE__ */ new Map();
  for (const value of values) {
    const id = sourceId(first(value.id, value.album_id));
    if (id !== null && text(value.title) !== "") result.set(id, summary(value, id));
  }
  return [...result.values()];
}
function summary(value, id) {
  const encoded = sourceId(id);
  if (encoded === null) throw new Error("Album ID is invalid.");
  const cover = text(first(value.cover_url, value.cover));
  return frozen({ id: `album:${encoded}`, title: text(value.title) || id, contentKind: "audio", coverOrientation: "portrait", author: nullable(first(value.teller, value.author)), url: `${catalogRoot}album_info/${encodeURIComponent(id)}`, coverUrl: proxyImage(cover), description: nullable(first(value.intro, value.description)), language: "zh-CN", status: value.status === 0 ? "completed" : value.status === 1 ? "ongoing" : "unknown", access: "unknown", wordCount: null, chapterCount: nonNegative(first(value.chapter_count, value.chapterCount, value.count)), publishedAt: null, updatedAt: null, latestChapter: nullable(value.latest_chapter_title) === null ? null : { id: `album:${id}:latest`, title: text(value.latest_chapter_title), url: null, updatedAt: null }, categories: stringList(first(value.cat, value.category)), tags: [], attributes: [] });
}
function chapter(albumId, value, index) {
  const native = sourceId(first(value.index, value.chapter_idx, value.id));
  if (native === null) return null;
  return frozen({ id: `album:${albumId}:${native}`, title: text(value.title) || `第 ${index + 1} 集`, order: index, url: null, volumeTitle: "节目", wordCount: null, updatedAt: null, isLocked: false, attributes: [] });
}
function chapterGroups(albumId, items, size = 500) {
  const groups = [];
  for (let start = 0; start < items.length; start += size) {
    const episodes = items.slice(start, start + size).map((item, index) => frozen({ ...item, order: index })), firstId = episodes[0]?.id ?? String(start);
    groups.push(frozen({ id: `group:${albumId}:${firstId}`, title: `第 ${start + 1}-${start + episodes.length} 集`, order: groups.length, episodes }));
  }
  return groups;
}
function sourceId(value) {
  const id = text(value);
  return /^\d+$/u.test(id) ? id : null;
}
function contentId(id) {
  const value = /^album:(\d+)$/u.exec(id)?.[1];
  if (value === void 0) throw new Error("Content ID is invalid.");
  return value;
}
function chapterNative(id, albumId) {
  const value = new RegExp(`^album:${albumId}:(\\d+)$`, "u").exec(id)?.[1];
  if (value === void 0) throw new Error("Chapter ID is invalid.");
  return value;
}
function proxyImage(value) {
  if (!safeUrl(value)) return null;
  return requireContext().resource.proxy({ kind: "image", url: value, headers: { Referer: "https://tingyou.fm/" } });
}
function safeUrl(value) {
  try {
    const url = new URL(value);
    return (url.protocol === "https:" || url.protocol === "http:") && url.username === "" && url.password === "";
  } catch {
    return false;
  }
}
function cursorPage(cursor, target) {
  if (cursor === null) return 1;
  const raw = cursor.startsWith(`${target}:`) ? cursor.slice(target.length + 1) : "", page = Number(raw);
  if (!Number.isSafeInteger(page) || page < 2 || page > 1e3) throw new Error("Cursor is invalid.");
  return page;
}
function clamp(value) {
  return Math.max(1, Math.min(50, Math.floor(value)));
}
function nonNegative(value) {
  const result = Number(value);
  return Number.isSafeInteger(result) && result >= 0 ? result : null;
}
function stringList(value) {
  if (Array.isArray(value)) return value.map(text).filter(Boolean).slice(0, 32);
  const raw = text(value);
  return raw === "" ? [] : raw.split(/[,，/]/u).map((part) => part.trim()).filter(Boolean).slice(0, 32);
}
function parseJson(raw) {
  try {
    return JSON.parse(raw);
  } catch {
    throw new Error("Source response is invalid.");
  }
}
function first(...values) {
  return values.find((value) => value !== null && value !== void 0 && value !== "") ?? "";
}
function records(value) {
  return Array.isArray(value) ? value.filter(isObject) : [];
}
function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function text(value) {
  return typeof value === "string" ? value.trim() : typeof value === "number" || typeof value === "bigint" ? String(value) : "";
}
function nullable(value) {
  const result = text(value);
  return result === "" ? null : result;
}
function notNull(value) {
  return value !== null;
}
function frozen(value) {
  return Object.freeze(value);
}
function requireContext() {
  if (context === void 0) throw new Error("Source is not activated.");
  return context;
}
export {
  activate,
  deferredGroups,
  discover,
  getChapters,
  getContent,
  getDetail,
  search,
  searchSuggestions
};
