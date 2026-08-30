/**
 * MgRead Plugin API v1 entry for the Elkoparts source.
 * Activation stores only the public Runtime context and creates one reusable source parser.
 */

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
  SearchSuggestionsRequest,
  SearchSuggestionsResult,
} from './mgread-api.js';
import { ElkopartsSource } from './source.js';

let context: MgReadPluginContext | undefined;
let source: ElkopartsSource | undefined;

export async function activate(nextContext: MgReadPluginContext): Promise<void> {
  context = nextContext;
  source = new ElkopartsSource(nextContext);
  nextContext.log.info('plugin_activated');
}

export async function discover(request: DiscoverRequest): Promise<DiscoverResult> {
  return invoke('discover', (activeSource) => activeSource.discover(request));
}

export async function search(request: SearchRequest): Promise<SearchResult> {
  return invoke('search', (activeSource) => activeSource.search(request));
}

export async function searchSuggestions(request: SearchSuggestionsRequest): Promise<SearchSuggestionsResult> {
  return invoke('search_suggestions', async (activeSource) => activeSource.searchSuggestions(request));
}

export async function getDetail(request: ContentReferenceRequest): Promise<ContentDetail> {
  return invoke('get_detail', (activeSource) => activeSource.getDetail(request));
}

export async function getChapters(request: ChaptersRequest): Promise<ChaptersResult> {
  return invoke('get_chapters', (activeSource) => activeSource.getChapters(request));
}

export async function getContent(request: ContentRequest): Promise<ChapterContent> {
  return invoke('get_content', (activeSource) => activeSource.getContent(request));
}

type Operation =
  | 'discover'
  | 'search'
  | 'search_suggestions'
  | 'get_detail'
  | 'get_chapters'
  | 'get_content'
  | 'resource';

async function invoke<T>(operation: Operation, action: (activeSource: ElkopartsSource) => Promise<T>): Promise<T> {
  const activeContext = requireActivated(context);
  const activeSource = requireActivated(source);
  activeContext.log.info(`source_${operation}_started`);
  try {
    const result = await action(activeSource);
    activeContext.log.info(`source_${operation}_completed`);
    return result;
  } catch {
    activeContext.log.warn(`source_${operation}_failed`);
    throw new Error('Source operation failed.');
  }
}

function requireActivated<T>(value: T | undefined): T {
  if (value === undefined) throw new Error('Source is not activated.');
  return value;
}
