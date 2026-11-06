/**
 * 来源真实榜单/分类发现；所有 target 来自已验证接口，不使用关键词伪造榜单。
 * 首页只预取热门和新上架的小窗口；分类由用户进入时请求，追加绑定 collectionId。
 */
import {json, records, natural, summaries, position, window, type DiscoverRequest} from './protocol.mjs';
const channels = [
  ['hot', '热门榜', 'rank?section=hot'], ['new', '最新上架', 'rank?section=new'],
  ['novel', '全部有声小说', 'category?category=2'], ['fantasy', '玄幻奇幻', 'category?category=2&type=46'],
  ['wuxia', '武侠小说', 'category?category=2&type=11'], ['suspense', '恐怖惊悚', 'category?category=2&type=14'],
  ['history', '历史军事', 'category?category=2&type=15'], ['drama', '广播剧', 'category?category=2&type=36'],
  ['storytelling', '全部评书', 'category?category=1'], ['shan', '单田芳', 'category?category=1&type=1'],
  ['liu', '刘兰芳', 'category?category=1&type=2'], ['tian', '田连元', 'category?category=1&type=3'],
  ['yuan', '袁阔成', 'category?category=1&type=4'],
] as const;
type Result = {kind: 'document'; document: {components: object[]}} | {kind: 'append'; collectionId: string; items: object[]; continuation: {target: string; cursor: string} | null};
export async function discover(request: DiscoverRequest): Promise<Result> {
  if (request.target === null) {
    if (request.cursor !== null || request.collectionId !== null) throw new Error('Invalid discovery root request.');
    const components: object[] = [
      {type: 'searchInput', id: 'source-search', label: '搜索有声专辑', placeholder: '输入书名、作者或演播者', submitLabel: '搜索'},
      {type: 'section', id: 'channels', title: '榜单与分类', subtitle: null, icon: 'audio', children: [
        {type: 'categoryCollection', id: 'channel-list', layout: 'chips', categories: channels.map(([id, title]) => ({id, title, target: 'channel:' + id, count: null, url: null, icon: 'audio'}))},
      ]},
    ];
    for (const id of ['hot', 'new']) {
      const result = await discover({target: 'channel:' + id, cursor: null, collectionId: null, pageSize: Math.min(6, request.pageSize)});
      if (result.kind === 'document') components.push(...result.document.components);
    }
    return {kind: 'document', document: {components}};
  }
  const channel = channels.find(([id]) => request.target === 'channel:' + id);
  if (!channel) throw new Error('Invalid discovery target.');
  const collectionId = request.target;
  if (request.collectionId !== null && request.collectionId !== collectionId) throw new Error('Invalid collection ID.');
  const {page} = position(request.cursor, request.target), data = await json(channel[2] + '&page=' + page);
  const raw = records(data.items ?? data.data), pages = natural(data.pages);
  const more = typeof data.has_more === 'boolean' ? data.has_more : pages !== null && page < pages;
  const result = window(summaries(raw), request.target, request.cursor, request.pageSize, more && raw.length > 0);
  const items = result.items.map(content => ({content, rank: null, metric: null, recommendation: null}));
  const continuation = result.nextCursor === null ? null : {target: request.target, cursor: result.nextCursor};
  if (request.collectionId !== null) return {kind: 'append', collectionId, items, continuation};
  return {kind: 'document', document: {components: [{type: 'section', id: collectionId + ':section', title: channel[1], subtitle: null, icon: 'audio', children: [
    {type: 'contentCollection', id: collectionId, layout: 'coverGrid', items, continuation},
  ]}]}};
}
