import assert from'node:assert/strict';import{createCipheriv}from'node:crypto';import test from'node:test';import*as plugin from'../dist/index.mjs';
const key=Buffer.from('ea9d9d4f9a983fe6f6382f29c7b46b8d6dc47abc6da36662e6ddff8c78902f65','hex');
function rotl(value,bits){return((value<<bits)|(value>>>(32-bits)))>>>0;}function add(a,b){return(a+b)>>>0;}function quarter(s,a,b,c,d){s[a]=add(s[a],s[b]);s[d]=rotl(s[d]^s[a],16);s[c]=add(s[c],s[d]);s[b]=rotl(s[b]^s[c],12);s[a]=add(s[a],s[b]);s[d]=rotl(s[d]^s[a],8);s[c]=add(s[c],s[d]);s[b]=rotl(s[b]^s[c],7);}function hchacha(nonce){const s=new Uint32Array(16),constant=Buffer.from('expand 32-byte k');for(let i=0;i<4;i++)s[i]=constant.readUInt32LE(i*4);for(let i=0;i<8;i++)s[i+4]=key.readUInt32LE(i*4);for(let i=0;i<4;i++)s[i+12]=nonce.readUInt32LE(i*4);for(let i=0;i<10;i++){quarter(s,0,4,8,12);quarter(s,1,5,9,13);quarter(s,2,6,10,14);quarter(s,3,7,11,15);quarter(s,0,5,10,15);quarter(s,1,6,11,12);quarter(s,2,7,8,13);quarter(s,3,4,9,14);}const out=Buffer.alloc(32),p=[0,1,2,3,12,13,14,15];p.forEach((v,i)=>out.writeUInt32LE(s[v],i*4));return out;}function encrypted(value){const nonce=Buffer.from('000102030405060708090a0b0c0d0e0f1011121314151617','hex'),subkey=hchacha(nonce.subarray(0,16)),nonce12=Buffer.concat([Buffer.alloc(4),nonce.subarray(16)]),cipher=createCipheriv('chacha20-poly1305',subkey,nonce12,{authTagLength:16}),body=Buffer.concat([cipher.update(JSON.stringify(value),'utf8'),cipher.final(),cipher.getAuthTag()]);return Buffer.concat([Buffer.from([1]),nonce,body]).toString('hex');}
test('Yueting native source decrypts albums, keeps stable IDs and proxies resources',async()=>{const proxied=[],calls=[];await plugin.activate({log:{info(){},warn(){}},resource:{proxy(value){proxied.push(value);return`http://127.0.0.1/resource/${proxied.length}`;}},http:{async fetch(input,init={}){const url=String(input);calls.push([url,init]);if(url.includes('/album_info/'))return Response.json({payload:encrypted({id:123,title:'测试专辑',teller:'主播',cover_url:'https://img.example/cover.jpg'})});if(url.includes('/album_chapters/'))return Response.json({payload:encrypted({chapters:[{index:7,title:'第一集'}]})});if(url.endsWith('/me'))return Response.json({ok:true});if(url.endsWith('/play_token'))return Response.json({payload:encrypted({play_url:'https://media.example/episode.mp3'})});return Response.json({payload:encrypted({data:[{id:123,title:'测试专辑',teller:'主播',cover_url:'https://img.example/cover.jpg'}]})});}}});const listing=await plugin.discover({target:'channel:novel',cursor:null,collectionId:null,pageSize:5});const item=listing.document.components[0].children[0].items[0].content;assert.equal(item.id,'album:123');assert.equal(proxied[0].kind,'image');const detail=await plugin.getDetail({id:item.id});assert.equal(detail.author,'主播');const chapters=await plugin.getChapters({id:item.id});assert.equal(chapters.items[0].id,'album:123:7');const content=await plugin.getContent({id:item.id,chapterId:chapters.items[0].id});assert.equal(content.media.resourceType,'audio');assert.equal(proxied.at(-1).url,'https://media.example/episode.mp3');assert.match(calls.find(([url])=>url.endsWith('/play_token'))[1].body,/^[0-9a-f]+$/u);});

function discoveryCollections(result) {const found=[]; const visit=node=>{if(node.type==='contentCollection')found.push(node);for(const child of node.children??[])visit(child);};for(const node of result.document?.components??[])visit(node);return found;}

test('all 44 channels fit host groups and status filtering retains raw page offsets',async()=>{
 const calls=[];
 await plugin.activate({log:{info(){}},resource:{proxy:v=>v.url},http:{fetch:async input=>{calls.push(String(input));return Response.json({payload:encrypted({pages:1,data:Array.from({length:9},(_,i)=>({id:i+1,title:'Album '+i,status:i%2}))})});}}});
 const root=await plugin.discover({target:null,cursor:null,collectionId:null,pageSize:3});
 const groups=root.document.components.filter(x=>x.id.startsWith('yueting-channels-')).flatMap(x=>x.children);
 assert.equal(groups.flatMap(x=>x.categories).length,44);assert.ok(groups.every(x=>x.categories.length<=32));
 const target='channel:fantasy:sort:updated:status:0';
 const child=await plugin.discover({target,cursor:null,collectionId:null,pageSize:2});const list=discoveryCollections(child)[0];
 assert.deepEqual(list.items.map(x=>x.content.id),['album:1','album:3']);
 const append=await plugin.discover({...list.continuation,collectionId:list.id,pageSize:10});
 assert.deepEqual(append.items.map(x=>x.content.id),['album:5','album:7','album:9']);assert.equal(append.continuation,null);
 assert.ok(calls.some(url=>url.includes('/types/46/updated/p1')));
 assert.ok(child.document.components[0].children[1].categories.every(x=>x.target.endsWith(':status:0')));
});
test('discovery keeps the remainder before advancing the encrypted upstream page',async()=>{
 const calls=[];await plugin.activate({log:{info(){}},resource:{proxy:v=>v.url},http:{fetch:async input=>{const url=String(input);calls.push(url);return Response.json({payload:encrypted({data:url.endsWith('p2')?[]:Array.from({length:7},(_,i)=>({id:i+1,title:'Album '+i}))})});}}});
 const root=await plugin.discover({target:null,cursor:null,collectionId:null,pageSize:3});assert.equal(discoveryCollections(root).length,2);
 const first=await plugin.discover({target:'channel:novel',cursor:null,collectionId:null,pageSize:3});let list=discoveryCollections(first)[0], seen=list.items.map(x=>x.content.id);const id=list.id;
 for(let i=0;list.continuation&&i<5;i++){list=await plugin.discover({...list.continuation,collectionId:id,pageSize:3});seen.push(...list.items.map(x=>x.content.id));}
 assert.equal(list.continuation,null);assert.equal(seen.length,7);assert.equal(new Set(seen).size,7);
 assert.equal(calls.filter(x=>x.endsWith('p2')).length,1);
 await assert.rejects(plugin.discover({target:'channel:novel',cursor:'channel:storytelling:2',collectionId:null,pageSize:3}));
});
