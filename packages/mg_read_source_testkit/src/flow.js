/**
 * 小说/漫画数据源的标准公共阅读链路。
 *
 * 职责：按阶段运行发现、搜索、建议、详情、目录和正文，并返回完整结果及计数摘要。
 */
import { SourceTestFailure, failureFromCause } from './diagnostics.js';

export function collectDiscoveryContent(result) {
  if (result?.kind === 'append') {
    return Object.freeze(result.items?.map((item) => item.content).filter(Boolean) ?? []);
  }
  const contents = [];
  const visit = (component) => {
    if (component?.type === 'contentCollection') {
      for (const item of component.items ?? []) {
        if (item?.content !== undefined) contents.push(item.content);
      }
    }
    for (const child of component?.children ?? []) visit(child);
  };
  for (const component of result?.document?.components ?? []) visit(component);
  return Object.freeze(contents);
}

export function collectDiscoveryTargets(result) {
  const targets = [];
  const add = (value) => {
    if (typeof value === 'string' && value.length > 0 && !targets.includes(value)) {
      targets.push(value);
    }
  };
  const visit = (component) => {
    for (const tab of component?.tabs ?? []) add(tab?.target);
    for (const category of component?.categories ?? []) add(category?.target);
    for (const child of component?.children ?? []) visit(child);
  };
  for (const component of result?.document?.components ?? []) visit(component);
  return Object.freeze(targets);
}

export async function runReadingSourceFlow({
  plugin,
  contentId = null,
  discoverRequest = null,
  searchRequest = null,
  suggestionsRequest = null,
}) {
  let discoveryItems = [];
  let searchItems = [];
  let suggestionItems = [];
  if (discoverRequest !== null) {
    const discovery = await runStage('discover', () => plugin.discover(discoverRequest));
    discoveryItems = collectDiscoveryContent(discovery);
    requireNonEmpty(discoveryItems, 'source_discovery_empty', 'discover');
  }
  if (searchRequest !== null) {
    const search = await runStage('search', () => plugin.search(searchRequest));
    searchItems = search?.items ?? [];
    requireNonEmpty(searchItems, 'source_search_empty', 'search');
  }
  if (suggestionsRequest !== null) {
    const suggestions = await runStage(
      'searchSuggestions',
      () => plugin.searchSuggestions(suggestionsRequest),
    );
    suggestionItems = suggestions?.items ?? [];
    requireNonEmpty(suggestionItems, 'source_suggestions_empty', 'searchSuggestions');
  }

  const selectedId = contentId ?? searchItems[0]?.id ?? discoveryItems[0]?.id;
  if (typeof selectedId !== 'string' || selectedId.length === 0) {
    throw new SourceTestFailure('source_content_id_missing', 'detail', {});
  }
  const detail = await runStage('detail', () => plugin.getDetail({ id: selectedId }));
  if (detail?.id !== selectedId || typeof detail?.title !== 'string' || detail.title.length === 0) {
    throw new SourceTestFailure('source_detail_invalid', 'detail', {
      idMatches: detail?.id === selectedId,
      hasTitle: typeof detail?.title === 'string' && detail.title.length > 0,
    });
  }
  const chapters = await runStage('chapters', () => plugin.getChapters({ id: selectedId }));
  const chapterItems = chapters?.items ?? [];
  requireNonEmpty(chapterItems, 'source_chapters_empty', 'chapters');
  const chapterIds = chapterItems
    .map((chapter) => chapter?.id)
    .filter((id) => typeof id === 'string');
  if (chapterIds.length !== chapterItems.length || new Set(chapterIds).size !== chapterItems.length) {
    throw new SourceTestFailure('source_chapters_invalid', 'chapters', {
      items: chapterItems.length,
      uniqueIds: new Set(chapterIds).size,
    });
  }

  const sampleIndexes = [...new Set([0, Math.floor((chapterIds.length - 1) / 2), chapterIds.length - 1])];
  const contents = [];
  let contentUnits = 0;
  for (const sampleIndex of sampleIndexes) {
    const chapterId = chapterIds[sampleIndex];
    const content = await runStage(
      `content.${sampleIndex}`,
      () => plugin.getContent({ id: selectedId, chapterId }),
    );
    if (content?.chapterId !== chapterId) {
      throw new SourceTestFailure('source_content_chapter_mismatch', 'content', {
        sampleIndex,
      });
    }
    const units = contentUnitCount(content);
    if (units === 0) {
      throw new SourceTestFailure('source_content_empty', 'content', {
        contentKind: content?.contentKind ?? null,
        sampleIndex,
      });
    }
    contents.push(content);
    contentUnits += units;
  }
  const content = contents[0];

  return Object.freeze({
    detail,
    chapters,
    content,
    contents: Object.freeze(contents),
    summary: Object.freeze({
      discoveryItems: discoveryItems.length,
      searchItems: searchItems.length,
      suggestionItems: suggestionItems.length,
      chapterItems: chapterItems.length,
      contentKind: content.contentKind,
      contentSamples: contents.length,
      contentUnits,
    }),
  });
}

function contentUnitCount(content) {
  if (content?.contentKind === 'novel') {
    return typeof content.text === 'string' ? content.text.trim().length : 0;
  }
  if (content?.contentKind === 'manga') {
    return Array.isArray(content.pages) ? content.pages.length : 0;
  }
  if (content?.contentKind === 'audio' || content?.contentKind === 'video') {
    return content.media === null || content.media === undefined ? 0 : 1;
  }
  return 0;
}

async function runStage(stage, action) {
  try {
    return await action();
  } catch (error) {
    if (error instanceof SourceTestFailure) throw error;
    throw failureFromCause(`source_${stage}_failed`, stage, error);
  }
}

function requireNonEmpty(items, code, stage) {
  if (!Array.isArray(items) || items.length === 0) {
    throw new SourceTestFailure(code, stage, { items: Array.isArray(items) ? 0 : null });
  }
}
