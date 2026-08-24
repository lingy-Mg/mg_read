import { readFile } from 'node:fs/promises';
import type {
  ChapterContent, ChaptersRequest, ChaptersResult, ContentDetail, ContentReferenceRequest,
  ContentRequest, DiscoverRequest, DiscoverResult, MgReadPluginContext, SearchRequest,
  SearchResult, SearchSuggestionsRequest, SearchSuggestionsResult,
} from './mgread-api.js';
import { ShuduguSource, type SourceRules } from './source.js';

let context: MgReadPluginContext | undefined;
let source: ShuduguSource | undefined;

export async function activate(nextContext: MgReadPluginContext): Promise<void> {
  context = nextContext;
  source = new ShuduguSource(nextContext, JSON.parse(await readFile(new URL('../assets/rules.json', import.meta.url), 'utf8')) as SourceRules);
  nextContext.log.info('source_activated');
}
export async function discover(request: DiscoverRequest): Promise<DiscoverResult> { return invoke('discover', () => requireSource().discover(request)); }
export async function search(request: SearchRequest): Promise<SearchResult> { return invoke('search', () => requireSource().search(request)); }
export async function searchSuggestions(request: SearchSuggestionsRequest): Promise<SearchSuggestionsResult> { return invoke('search_suggestions', () => requireSource().searchSuggestions(request)); }
export async function getDetail(request: ContentReferenceRequest): Promise<ContentDetail> { return invoke('get_detail', () => requireSource().getDetail(request)); }
export async function getChapters(request: ChaptersRequest): Promise<ChaptersResult> { return invoke('get_chapters', () => requireSource().getChapters(request)); }
export async function getContent(request: ContentRequest): Promise<ChapterContent> { return invoke('get_content', () => requireSource().getContent(request)); }

function requireSource(): ShuduguSource { if (source === undefined) throw new Error('Source is not activated.'); return source; }
type Operation = 'discover' | 'search' | 'search_suggestions' | 'get_detail' | 'get_chapters' | 'get_content';
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
