/** Generate cross-language capacity policies; --check detects stale copies without modifying files. */
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const policy=JSON.parse(await readFile(resolve(root,'tools/content_limits.json'),'utf8'));
for(const [key,value] of Object.entries(policy))if(!/^[a-z][a-zA-Z0-9]+$/.test(key)||!Number.isSafeInteger(value)||value<1)throw new Error(`Invalid limit: ${key}`);
const generated='GENERATED from tools/content_limits.json by tools/generate_content_limits.mjs. DO NOT EDIT.';
const ts=`// ${generated}\nexport const contentLimits = Object.freeze(${JSON.stringify(policy,null,2)});\n`;
const dart=name=>`// ${generated}\n/// Shared capacity budgets; values bound allocation and never preallocate memory.\nabstract final class ${name} {\n${Object.entries(policy).map(([k,v])=>`  static const int ${k} = ${v};`).join('\n')}\n}\n`;
const upper=name=>name.replace(/[A-Z]/g,char=>'_'+char).toUpperCase();
const rust=`//! ${generated}\n#![allow(dead_code)]\n${Object.entries(policy).filter(([key])=>!key.startsWith('local')&&!key.startsWith('epub')).map(([key,value])=>`pub const ${upper(key)}: usize = ${value};`).join('\n')}\n`;
const kotlin=`// ${generated}\npackage com.mgread.mgread_plugin_runtime\n\ninternal object ContentLimits {\n${Object.entries(policy).map(([key,value])=>`    const val ${key}: ${value>2147483647?'Long':'Int'} = ${value}${value>2147483647?'L':''}`).join('\n')}\n}\n`;
const targets={
 'packages/mg_read_node_runtime/src/content-limits.ts':ts,
 'lib/core/content_limits.dart':dart('ContentLimits'),
 'packages/mgread_plugin_runtime/lib/src/content_limits.dart':dart('RuntimeContentLimits'),
 'packages/mg_read_reader_ui/lib/src/core/content_limits.dart':dart('ReaderContentLimits'),
 'packages/mg_read_native_runtime/sdk/src/limits.rs':rust,
 'packages/mg_read_native_runtime/src/limits.rs':rust,
 'packages/mgread_plugin_runtime/android/src/main/kotlin/com/mgread/mgread_plugin_runtime/ContentLimits.kt':kotlin,
 'plugins/sources/aisishuwu/src/content-limits.ts':ts,
 'plugins/sources/jmcomic/src/content-limits.ts':ts,
 'packages/mg_read_plugin_cache/content-limits.js':ts,
};
const stale=[];
for (const source of ['35ge-info','baozimh-com','tatays-novel','xtyxsw-org','manhuagui-com','elkoparts-net','shukuge-365','douyinxiaoshuo-biquge','p5hanman','shudugu','bz777777777-comv3','xiezhenji']) targets[`plugins/sources/${source}/src/content-limits.ts`] = ts;
for(const [path,text] of Object.entries(targets)){
 const file=resolve(root,path);let current;try{current=await readFile(file,'utf8');}catch{}
 if(current?.replaceAll('\r\n','\n')===text)continue;
 if(process.argv.includes('--check'))stale.push(path);else{await mkdir(dirname(file),{recursive:true});await writeFile(file,text);}
}
if(stale.length){console.error(`Stale capacity policies: ${stale.join(', ')}`);process.exitCode=1;}else console.log(`Capacity policy ${process.argv.includes('--check')?'checked':'generated'}: ${Object.keys(targets).length} targets.`);
