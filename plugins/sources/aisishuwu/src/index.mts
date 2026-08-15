import { readFile } from 'node:fs/promises';

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
import { AliceBookHouseSource, type SourceRules } from './source.js';
import { requireActivated } from './utils.js';

let source: AliceBookHouseSource | undefined;

/** Runtime cold activation: load only the packaged source configuration. */
export async function activate(context: MgReadPluginContext): Promise<void> {
  const rules = JSON.parse(
    await readFile(new URL('../assets/rules.json', import.meta.url), 'utf8'),
  ) as SourceRules;
  source = new AliceBookHouseSource(context, rules);
  context.log.info('source_activated');
}

/** Maps source categories and category pages to the host discovery screen. */
export async function discover(request: DiscoverRequest): Promise<DiscoverResult> {
  return requireActivated(source).discover(request);
}

/** Maps a user query to this source's search endpoint. */
export async function search(request: SearchRequest): Promise<SearchResult> {
  return requireActivated(source).search(request);
}

/** Resolves one opaque `novel:<id>` reference to its metadata. */
export async function getDetail(request: ContentReferenceRequest): Promise<ContentDetail> {
  return requireActivated(source).getDetail(request);
}

/** Resolves a novel reference to ordered opaque chapter IDs. */
export async function getChapters(request: ChaptersRequest): Promise<ChaptersResult> {
  return requireActivated(source).getChapters(request);
}

/** Resolves one opaque chapter reference to clean text content. */
export async function getContent(request: ContentRequest): Promise<ChapterContent> {
  return requireActivated(source).getContent(request);
}
