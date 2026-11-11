// Cross-layer regressions: generated URLs reach HTTP and large payloads survive caching/HLS rewriting.
import assert from 'node:assert/strict';
import test from 'node:test';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {startLoopbackServer} from '../dist/desktop-runtime-startup.js';
import {encodeSourceResourceToken,decodeSourceResourceUrl} from '../dist/source-resource-token.js';
import {validateSearchResult} from '../dist/plugin-content-validation.js';
import {serveSourceResource} from '../dist/loopback-resources.js';
import {PluginCache} from '../../mg_read_plugin_cache/index.js';

test('a long generated cover URL passes result validation, decoding and the real HTTP listener', async t=>{
 const request={kind:'image',url:'https://example.test/cover.png',headers:{referer:`https://example.test/${'x'.repeat(40000)}`}};
 const token=encodeSourceResourceToken('org.test.fixture',request);
 const {server,port}=await startLoopbackServer({host:'127.0.0.1',port:0,onUpgrade(){},onHttp(req,res){res.end(req.url);}});
 t.after(()=>new Promise(resolve=>server.close(resolve)));
 const coverUrl=`http://127.0.0.1:${port}/v1/source-resource/${token}`;
 const item={id:'book:1',title:'长标题'.repeat(200),contentKind:'novel',coverOrientation:'portrait',author:null,url:null,coverUrl,description:null,language:null,status:'unknown',access:'unknown',wordCount:null,chapterCount:null,publishedAt:null,updatedAt:null,latestChapter:null,categories:[],tags:[],attributes:[]};
 assert.equal(validateSearchResult('org.test.fixture','Fixture',{items:[item],nextCursor:null,totalCount:null}).items[0].coverUrl,coverUrl);
 assert.deepEqual(decodeSourceResourceUrl(coverUrl).request,request);
 const response=await fetch(coverUrl);
 assert.equal(response.status,200);
 assert.equal(await response.text(),`/v1/source-resource/${token}`);
});

test('a source cache reload preserves a chapter over the old 1 and 2 MiB thresholds',async t=>{
 const root=await mkdtemp(join(tmpdir(),'mgread-large-source-cache-'));
 t.after(()=>rm(root,{recursive:true,force:true}));
 const text='正文'.repeat(600000), policy={namespace:'chapter',staleAfterMs:60000},url=new URL('https://example.test/chapter');
 await new PluginCache(root).getOrFetchText(url,policy,async()=>text);
 const loaded=await new PluginCache(root).getOrFetchText(url,policy,async()=>{throw Error('must use persisted cache');});
 assert.equal(loaded,text);
});

test('HLS playlists beyond 1 MiB are rewritten and delivered completely',async t=>{
 const text=`#EXTM3U\n${('# comment '+ 'x'.repeat(100)+'\n').repeat(11000)}#EXTINF:5,\nsegment.ts\n#EXT-X-ENDLIST\n`;
 const manager={async openSourceResource(){return {request:{kind:'hls',url:'https://example.test/index.m3u8'},responseUrl:'https://example.test/index.m3u8',response:new Response(text),proxy(){return 'https://proxy.test/segment';}};}};
 const {server,port}=await startLoopbackServer({host:'127.0.0.1',port:0,onUpgrade(){},onHttp(req,res){void serveSourceResource(manager,'token',res,()=>{},req);}});
 t.after(()=>new Promise(resolve=>server.close(resolve)));
 const response=await fetch(`http://127.0.0.1:${port}/hls`);
 assert.equal(response.status,200);
 const result=await response.text();assert.ok(result.length>1024*1024);assert.ok(result.includes('https://proxy.test/segment'));assert.ok(result.endsWith('#EXT-X-ENDLIST\n'));
});
