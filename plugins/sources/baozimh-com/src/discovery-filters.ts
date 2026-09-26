/** Baozimh public classify dimensions, verified against the site's filter links; targets retain all selections. */
export const dimensions = [
  { key: 'type', title: '题材', values: [['all','全部'],['lianai','戀愛'],['chunai','純愛'],['gufeng','古風'],['yineng','異能'],['xuanyi','懸疑'],['juqing','劇情'],['kehuan','科幻'],['qihuan','奇幻'],['xuanhuan','玄幻'],['chuanyue','穿越'],['mouxian','冒險'],['tuili','推理'],['wuxia','武俠'],['gedou','格鬥'],['zhanzheng','戰爭'],['rexie','熱血'],['gaoxiao','搞笑'],['danuzhu','大女主'],['dushi','都市'],['zongcai','總裁'],['hougong','後宮'],['richang','日常'],['hanman','韓漫'],['shaonian','少年'],['qita','其他']] },
  { key: 'region', title: '地区', values: [['all','全部'],['cn','國漫'],['jp','日本'],['kr','韓國'],['en','歐美']] },
  { key: 'state', title: '状态', values: [['all','全部'],['serial','連載'],['pub','完結']] },
  { key: 'filter', title: '首字母', values: [['*','全部'],['ABCD','ABCD'],['EFGH','EFGH'],['IJKL','IJKL'],['MNOP','MNOP'],['QRST','QRST'],['UVW','UVW'],['XYZ','XYZ'],['0-9','0-9']] },
] as const;
export type Filters = Record<'type'|'region'|'state'|'filter', string>;
export const defaults: Filters = { type:'all', region:'all', state:'all', filter:'*' };
export function pathFor(value: Filters) { return '/classify?' + new URLSearchParams(value).toString(); }
export function targetFor(value: Filters) { return 'filter:' + Buffer.from(JSON.stringify(value)).toString('base64url'); }
export function readFilters(target: string): Filters {
  if (!/^filter:[A-Za-z0-9_-]{1,400}$/u.test(target)) throw new Error('Discovery target is invalid.');
  let value: Filters;
  try { value = JSON.parse(Buffer.from(target.slice(7), 'base64url').toString()) as Filters; } catch { throw new Error('Discovery target is invalid.'); }
  if (!value || dimensions.some(group => !group.values.some(([key]) => key === value[group.key]))) throw new Error('Discovery target is invalid.');
  return { type:value.type, region:value.region, state:value.state, filter:value.filter };
}
export function filterSections(current: Filters) {
  return dimensions.map(group => ({ type:'section', id:'filter-'+group.key, title:group.title, subtitle:null, children:[{type:'categoryCollection',id:'filter-list-'+group.key,layout:'chips',categories:group.values.map(([value,title])=>({id:value,title,target:targetFor({...current,[group.key]:value}),count:null,url:null,icon:'manga'}))}] }));
}
