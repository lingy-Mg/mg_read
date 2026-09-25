/** Diagnostic parity probe prints lengths/hashes only, never source content. */
import { createHash } from 'node:crypto';
import { createSourceTestHarness } from '../../../../packages/mg_read_source_testkit/index.js';
import { validateContentResult } from '../../../../packages/mg_read_node_runtime/dist/plugin-content.js';
const id = process.argv[2] ?? 'novel:3211';
for(const variant of ['js','wasm']) {
  const plugin=await import(variant==='wasm'?'../dist/index.mjs':'../../aisishuwu/dist/index.mjs');
  const harness=await createSourceTestHarness({plugin,pluginId:'org.mgread.parity',version:'0.1.0',fetch});
  try {
    const chapters=await plugin.getChapters({id});
    const content=await plugin.getContent({id,chapterId:chapters.items[0].id});
    let validation='passed';
    try { validateContentResult('org.mgread.parity','parity',content); } catch(error) { validation=error.message; }
    console.log(JSON.stringify({variant,id,chapters:chapters.items.length,textBytes:Buffer.byteLength(content.text),textChars:content.text.length,
      titleChars:content.title?.length,sha256:createHash('sha256').update(content.text).digest('hex'),
      normalizedSha256:createHash('sha256').update(content.text.replace(/\s+/gu,'')).digest('hex'),validation}));
  }finally{await harness.cleanup();}
}
