import assert from 'node:assert/strict'; import { createHash } from 'node:crypto'; import test from 'node:test';
import { buildPluginArtifact } from '../tools/mgread.mjs';
test('single-file artifact is deterministic and hashed', async()=>{const a=await buildPluginArtifact();const b=await buildPluginArtifact();assert.equal(a.format,'singleFile');assert.deepEqual(a.bytes,b.bytes);const n=a.bytes.indexOf(10);const p='// @mgread-plugin-v1 ';const l=a.bytes.subarray(0,n).toString();assert.ok(l.startsWith(p));const e=JSON.parse(Buffer.from(l.slice(p.length),'base64url'));const c=a.bytes.subarray(n+1);assert.equal(e.descriptor.mgread.id,'org.mgread.manhuagui-com');assert.equal(e.codeSha256,createHash('sha256').update(c).digest('hex'));});

