// Public result/request boundaries: 1000 items, 10 MiB catalogs and manga manifests.
import assert from 'node:assert/strict';
import test from 'node:test';
import { parseSearchParams, parseDiscoverParams } from '../dist/plugin-content-request.js';
import { validateSearchResult, validateChaptersResult, validateContentResult } from '../dist/plugin-content-validation.js';
import { validateDiscoverResult } from '../dist/plugin-content.js';

const summary = id => ({id, title:'标题', contentKind:'novel', coverOrientation:'portrait', author:null, url:null,
  coverUrl:null, description:null, language:null, status:'unknown', access:'unknown', wordCount:null,
  chapterCount:null, publishedAt:null, updatedAt:null, latestChapter:null, categories:[], tags:[], attributes:[]});
const items = Array.from({length:1000},(_,i)=>summary(`book:${i}`));
test('search and discovery accept 1000 items, rejecting item 1001', () => {
  assert.equal(validateSearchResult('fixture','Fixture',{items,nextCursor:null,totalCount:null}).items.length,1000);
  const discover = entries => validateDiscoverResult('fixture','Fixture',{kind:'document',document:{components:[{
    type:'contentCollection',id:'all',layout:'list',continuation:null,
    items:entries.map(content=>({content,rank:null,metric:null,recommendation:null})),
  }]}});
  assert.equal(discover(items).document.components[0].items.length,1000);
  const over=[...items,summary('book:1000')];
  assert.throws(()=>validateSearchResult('fixture','Fixture',{items:over,nextCursor:null,totalCount:null}));
  assert.throws(()=>discover(over));
  for(const pageSize of [1000,1001]) {
    const search=()=>parseSearchParams({pluginId:'org.test.fixture',query:'q',cursor:null,pageSize});
    const discovery=()=>parseDiscoverParams({pluginId:'org.test.fixture',target:null,cursor:null,collectionId:null,pageSize});
    if(pageSize===1000){assert.equal(search().request.pageSize,1000);assert.equal(discovery().request.pageSize,1000);}
    else {assert.throws(search);assert.throws(discovery);}
  }
});
const chapter = i => ({id:`${i}-${'x'.repeat(4090)}`,title:'章节',order:i,url:null,volumeTitle:null,
  wordCount:null,updatedAt:null,isLocked:null,attributes:[]});
test('complete catalogs larger than 2 MiB load while the 10 MiB budget still applies', () => {
  const items=Array.from({length:800},(_,i)=>chapter(i));
  assert.ok(Buffer.byteLength(JSON.stringify({items}))>2*1024*1024);
  assert.equal(validateChaptersResult('fixture','Fixture',{items}).items.length,800);
  assert.throws(()=>validateChaptersResult('fixture','Fixture',{
    items:Array.from({length:2900},(_,i)=>chapter(i)),
  }),/10485760-byte limit/u);
});
test('a manga manifest larger than 512 KiB loads without altering its 500-page limit', () => {
  const pages=Array.from({length:500},(_,index)=>({id:`page:${index}`,index,
    url:`https://example.com/${'x'.repeat(4096)}`,mimeType:null,width:null,height:null}));
  const content={chapterId:'chapter:1',contentKind:'manga',title:null,updatedAt:null,text:null,pages};
  assert.ok(Buffer.byteLength(JSON.stringify(content))>512*1024);
  assert.equal(validateContentResult('fixture','Fixture',content).pages.length,500);
  assert.throws(()=>validateContentResult('fixture','Fixture',{...content,pages:[...pages,{...pages[0],id:'extra',index:500}]}));
});
