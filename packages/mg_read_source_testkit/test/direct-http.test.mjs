/** Real local HTTP verifies direct Fetch decompression and cancellation, without an external proxy or site. */
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {gzipSync,deflateSync,brotliCompressSync,zstdCompressSync,createGzip,constants} from 'node:zlib';
import test from 'node:test';
import {createSourceTestHarness} from '../index.js';

for (const [encoding,encode] of Object.entries({gzip:gzipSync,deflate:deflateSync,br:brotliCompressSync,zstd:zstdCompressSync})) {
  test(`direct HTTP decodes ${encoding} pages like the real Fetch host`,async t=>{
    const body='<h1>真实目录页</h1><a href="/next">下一页</a>';
    const server=createServer((req,res)=>{res.writeHead(200,{'Content-Type':'text/html; charset=utf-8','Content-Encoding':encoding});res.end(encode(Buffer.from(body)));});
    await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(()=>{server.closeAllConnections();server.close();});
    const h=await createSourceTestHarness({plugin:{activate(){}},pluginId:'org.test.direct-compression',version:'1.0.0'});t.after(h.cleanup);
    const r=await h.context.http.fetch(`http://127.0.0.1:${server.address().port}/`,{proxyMode:'direct'});
    assert.equal(r.status,200);assert.equal(await r.text(),body);
  });
}

test('cancelling a decoded direct response closes its upstream HTTP connection',async t=>{
  let seenClose;const closed=new Promise(resolve=>seenClose=resolve);
  const server=createServer((req,res)=>{req.on('close',seenClose);res.writeHead(200,{'Content-Encoding':'gzip'});const gz=createGzip();gz.pipe(res);gz.write('a bounded prefix');gz.flush(constants.Z_SYNC_FLUSH);req.on('close',()=>gz.destroy());});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(()=>{server.closeAllConnections();server.close();});
  const h=await createSourceTestHarness({plugin:{activate(){}},pluginId:'org.test.direct-cancel',version:'1.0.0'});t.after(h.cleanup);
  const response=await h.context.http.fetch(`http://127.0.0.1:${server.address().port}/`,{proxyMode:'direct'});
  const reader=response.body.getReader();assert.ok((await reader.read()).value.length>0);await reader.cancel();
  await Promise.race([closed,new Promise((_,reject)=>setTimeout(()=>reject(new Error('upstream remained open')),1000))]);
});
