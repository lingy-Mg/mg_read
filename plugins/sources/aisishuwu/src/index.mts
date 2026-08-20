import type {
  ChapterContent,
  ChaptersRequest,
  ChaptersResult,
  ContentDetail,
  ContentReferenceRequest,
  ContentRequest,
  DiscoverRequest,
  DiscoverResult,
  MgReadPluginContext,
  SearchRequest,
  SearchResult,
} from './mgread-api.js';
import type { AliceBookHouseSource, SourceRules } from './source.js';

let source: AliceBookHouseSource | undefined;

const categoryRules: SourceRules['categories'] = Object.freeze([
  Object.freeze({ id: '71', title: '科幻' }),
  Object.freeze({ id: '79', title: '经典' }),
  Object.freeze({ id: '75', title: '奇幻' }),
  Object.freeze({ id: '69', title: '系统' }),
  Object.freeze({ id: '68', title: '武侠' }),
  Object.freeze({ id: '65', title: '乱伦' }),
  Object.freeze({ id: '64', title: '都市' }),
  Object.freeze({ id: '63', title: '乡村' }),
  Object.freeze({ id: '73', title: '同人' }),
  Object.freeze({ id: '62', title: '玄幻' }),
  Object.freeze({ id: '61', title: '校园' }),
  Object.freeze({ id: '70', title: '穿越' }),
  Object.freeze({ id: '22', title: '反差' }),
  Object.freeze({ id: '46', title: '凌辱' }),
  Object.freeze({ id: '18', title: '堕落' }),
  Object.freeze({ id: '19', title: '纯爱' }),
  Object.freeze({ id: '52', title: '伪娘' }),
  Object.freeze({ id: '48', title: '萝莉' }),
  Object.freeze({ id: '56', title: '熟女' }),
  Object.freeze({ id: '50', title: '正太' }),
  Object.freeze({ id: '72', title: '明星' }),
  Object.freeze({ id: '54', title: 'NTR' }),
  Object.freeze({ id: '53', title: '媚黑' }),
  Object.freeze({ id: '58', title: '调教' }),
  Object.freeze({ id: '59', title: '言情' }),
  Object.freeze({ id: '47', title: '百合' }),
  Object.freeze({ id: '82', title: '耽美' }),
  Object.freeze({ id: '21', title: '重口' }),
  Object.freeze({ id: '57', title: '其他' }),
]);

/** Runtime cold activation retains only the lightweight category projection. */
export async function activate(context: MgReadPluginContext): Promise<void> {
  globalThisContext = context;
  context.log.info('source_activated');
}

/** Maps source categories and category pages to the host discovery screen. */
export async function discover(request: DiscoverRequest): Promise<DiscoverResult> {
  const activeContext = requireContext();
  activeContext.log.info('source_discover_started');
  if (request.target === null) {
    activeContext.log.info('source_discover_category_branch');
    activeContext.log.info('source_discover_completed');
    return Object.freeze({
      tabs: Object.freeze([]),
      selectedTabId: null,
      nextCursor: null,
      sections: Object.freeze([
        Object.freeze({
          id: 'source-categories',
          title: '分类',
          subtitle: null,
          layout: 'categories' as const,
          items: Object.freeze([]),
          categories: Object.freeze(
            categoryRules.map((category) =>
              Object.freeze({
                id: `category:${category.id}`,
                title: category.title,
                target: `category:${category.id}`,
                count: null,
                url: null,
              }),
            ),
          ),
        }),
      ]),
    });
  }
  return (await loadSource(activeContext)).discover(request);
}

/** Maps a user query to this source's search endpoint. */
export async function search(request: SearchRequest): Promise<SearchResult> {
  return (await loadSource(requireContext())).search(request);
}

/** Resolves one opaque `novel:<id>` reference to its metadata. */
export async function getDetail(request: ContentReferenceRequest): Promise<ContentDetail> {
  return (await loadSource(requireContext())).getDetail(request);
}

/** Resolves a novel reference to ordered opaque chapter IDs. */
export async function getChapters(request: ChaptersRequest): Promise<ChaptersResult> {
  return (await loadSource(requireContext())).getChapters(request);
}

/** Resolves one opaque chapter reference to clean text content. */
export async function getContent(request: ContentRequest): Promise<ChapterContent> {
  return (await loadSource(requireContext())).getContent(request);
}

let globalThisContext: MgReadPluginContext | undefined;

function requireContext(): MgReadPluginContext {
  if (globalThisContext === undefined) throw new Error('Source is not activated.');
  return globalThisContext;
}

async function loadSource(activeContext: MgReadPluginContext): Promise<AliceBookHouseSource> {
  if (source !== undefined) return source;
  const [{ readFile }, { AliceBookHouseSource }] = await Promise.all([
    import('node:fs/promises'),
    import('./source.js'),
  ]);
  const rules = JSON.parse(
    await readFile(new URL('../assets/rules.json', import.meta.url), 'utf8'),
  ) as SourceRules;
  source = new AliceBookHouseSource(activeContext, rules);
  return source;
}
