/**
 * 速读谷标准插件入口。
 *
 * 职责：保存激活上下文和数据源实现实例，并将 Plugin API capability 转发给数据源插件实现。
 * 注意：必须先 activate；解析、缓存和站点规则由 source.ts 拥有，本文件不复制实现。
 */
import type {
  ChapterContent, ChaptersRequest, ChaptersResult, ContentDetail, ContentReferenceRequest,
  ContentRequest, DiscoverRequest, DiscoverResult, MgReadPluginContext, SearchRequest,
  SearchResult, SearchSuggestionsRequest, SearchSuggestionsResult,
} from './mgread-api.js';
import { ShuduguSource, type SourceRules } from './source.js';

let context: MgReadPluginContext | undefined;
let source: ShuduguSource | undefined;
const sourceRules = Object.freeze({
  origin: 'https://www.shudugu.org',
  categories: Object.freeze([
    { id: 'dushi', title: '都市小说' },
    { id: 'xuanhuan', title: '玄幻小说' },
    { id: 'qing', title: '轻小说' },
    { id: 'xianxia', title: '仙侠小说' },
    { id: 'lishi', title: '历史小说' },
    { id: 'kehuan', title: '科幻小说' },
    { id: 'zhutianwuxian', title: '诸天无限' },
    { id: 'youxi', title: '游戏小说' },
    { id: 'qihuan', title: '奇幻小说' },
    { id: 'xuanyi', title: '悬疑小说' },
    { id: 'tiyu', title: '体育小说' },
    { id: 'guanchang', title: '官场小说' },
    { id: 'junshi', title: '军事小说' },
    { id: 'wuxia', title: '武侠小说' },
    { id: 'xiangcun', title: '乡村小说' },
    { id: 'xianshi', title: '现实小说' },
    { id: 'yanqing', title: '言情小说' },
  ]),
} satisfies SourceRules);

export async function activate(nextContext: MgReadPluginContext): Promise<void> {
  context = nextContext;
  source = new ShuduguSource(nextContext, sourceRules);
  nextContext.log.info('source_activated');
}
export async function discover(request: DiscoverRequest): Promise<DiscoverResult> { return invoke('discover', () => requireSource().discover(request)); }
export async function search(request: SearchRequest): Promise<SearchResult> { return invoke('search', () => requireSource().search(request)); }
export async function searchSuggestions(request: SearchSuggestionsRequest): Promise<SearchSuggestionsResult> { return invoke('search_suggestions', () => requireSource().searchSuggestions(request)); }
export async function getDetail(request: ContentReferenceRequest): Promise<ContentDetail> { return invoke('get_detail', () => requireSource().getDetail(request)); }
export async function getChapters(request: ChaptersRequest): Promise<ChaptersResult> { return invoke('get_chapters', () => requireSource().getChapters(request)); }
export async function getContent(request: ContentRequest): Promise<ChapterContent> { return invoke('get_content', () => requireSource().getContent(request)); }
export async function resource(request: Record<string, unknown>): Promise<{ readonly status: number; readonly headers: Readonly<Record<string, string>>; readonly body: Uint8Array }> {
  return invoke('resource', async () => {
    const value = request.url;
    if (typeof value !== 'string') return { status: 400, headers: {}, body: new Uint8Array() };
    let url: URL;
    try {
      url = new URL(value);
      if ((url.protocol !== 'http:' && url.protocol !== 'https:') || url.origin !== 'https://www.shudugu.org') return { status: 400, headers: {}, body: new Uint8Array() };
    } catch { return { status: 400, headers: {}, body: new Uint8Array() }; }
    const response = await context!.http.fetch(url, { method: 'GET' });
    const contentType = response.headers.get('content-type');
    return { status: response.status, headers: contentType === null ? {} : { 'content-type': contentType }, body: new Uint8Array(await response.arrayBuffer()) };
  });
}

function requireSource(): ShuduguSource { if (source === undefined) throw new Error('Source is not activated.'); return source; }
type Operation = 'discover' | 'search' | 'search_suggestions' | 'get_detail' | 'get_chapters' | 'get_content' | 'resource';
async function invoke<T>(operation: Operation, action: () => Promise<T>): Promise<T> {
  const activeContext = context; if (activeContext === undefined) throw new Error('Source is not activated.');
  activeContext.log.info(`source_${operation}_started`);
  try {
    activeContext.log.debug(`source_${operation}_validated`);
    const result = await action();
    activeContext.log.debug(`source_${operation}_parsed`);
    activeContext.log.info(`source_${operation}_result_ready`);
    activeContext.log.info(`source_${operation}_completed`);
    return result;
  } catch {
    activeContext.log.warn(`source_${operation}_failed`);
    throw new Error('Source operation failed.');
  }
}
