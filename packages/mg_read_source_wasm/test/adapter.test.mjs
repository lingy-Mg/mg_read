/** Tiny genuine Wasm modules exercise the bridge independently of any source. */
import assert from 'node:assert/strict';
import test from 'node:test';
import { createWasmSource } from '../index.mjs';

const leb = (n) => n < 128 ? [n] : [(n & 127)|128,...leb(n>>>7)];
const string = (s) => [...leb(Buffer.byteLength(s)),...Buffer.from(s)];
const section = (id,data) => [id,...leb(data.length),...data];
function binary(value, version=1) {
  const data=Buffer.from(JSON.stringify(value));
  const exports=[['memory',2,0],['abi_version',0,0],['alloc',0,1],['release',0,2],['invoke',0,3],['result_len',0,4]];
  const body=(bytes)=>[...leb(bytes.length+1),0,...bytes];
  return new Uint8Array([0,97,115,109,1,0,0,0,
    ...section(1,[3,96,0,1,127,96,1,127,1,127,96,2,127,127,0]),
    ...section(3,[5,0,1,2,1,0]),
    ...section(5,[1,1,1,2]),
    ...section(7,[6,...exports.flatMap(([name,kind,index])=>[...string(name),kind,index])]),
    ...section(10,[5,...body([65,version,11]),...body([65,128,8,11]),...body([11]),...body([65,192,0,11]),...body([65,...leb(data.length),11])]),
    ...section(11,[1,0,65,192,0,11,...leb(data.length),...data]),
  ]);
}
const host=()=>({log:{info(){}},http:{fetch:async()=>new Response('fixture')},resource:{proxy:()=> 'http://127.0.0.1/resource'},errors:{raise(code){throw new Error(code);}}});
test('ABI results execute, release and deactivate without any source dependency',async()=>{
  const plugin=createWasmSource(binary({kind:'result',value:42}));
  await plugin.activate(host());
  assert.equal(await plugin.search({}),42);
  await plugin.deactivate();
  await assert.rejects(plugin.search({}),/not_active/);
});
test('rejects malformed binary and unsupported ABI',async()=>{
  for(const bytes of [new Uint8Array([1,2,3]),binary({kind:'result',value:null},2)]) {
    const plugin=createWasmSource(bytes); await plugin.activate(host());
    await assert.rejects(plugin.search({}));
  }
});
test('unknown continuation types fail closed',async()=>{
  const plugin=createWasmSource(binary({kind:'shell',command:'unused'}));
  await plugin.activate(host());
  await assert.rejects(plugin.search({}),/step_invalid/);
});
