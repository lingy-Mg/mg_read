/**
 * 数据源的标准公共阅读链路。
 *
 * 职责：收集发现分支/追加入口，再按阶段运行搜索、详情、完整目录和按类型内容抽样。
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

export function collectDiscoveryContinuations(result) {
  const continuations = [];
  const add = (collectionId, continuation) => {
    if (
      typeof collectionId !== 'string'
      || collectionId.length === 0
      || typeof continuation?.target !== 'string'
      || continuation.target.length === 0
      || typeof continuation?.cursor !== 'string'
      || continuation.cursor.length === 0
    ) return;
    if (continuations.some((value) =>
      value.collectionId === collectionId
      && value.target === continuation.target
      && value.cursor === continuation.cursor)) return;
    continuations.push(Object.freeze({
      collectionId,
      target: continuation.target,
      cursor: continuation.cursor,
    }));
  };
  if (result?.kind === 'append') {
    add(result.collectionId, result.continuation);
  } else {
    const visit = (component) => {
      if (component?.type === 'contentCollection') add(component.id, component.continuation);
      for (const child of component?.children ?? []) visit(child);
    };
    for (const component of result?.document?.components ?? []) visit(component);
  }
  return Object.freeze(continuations);
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
    const requests = Array.isArray(searchRequest) ? searchRequest : [searchRequest];
    let foundNonEmpty = false;
    for (let index = 0; index < requests.length; index += 1) {
      const search = await runStage(
        requests.length === 1 ? 'search' : `search.${index + 1}`,
        () => plugin.search(requests[index]),
      );
      const items = Array.isArray(search?.items) ? search.items : [];
      if (items.length === 0) continue;
      foundNonEmpty = true;
      if (contentId === null || items.some((item) => item?.id === contentId)) {
        searchItems = items;
        break;
      }
    }
    if (!foundNonEmpty) requireNonEmpty([], 'source_search_empty', 'search');
    if (searchItems.length === 0) {
      throw new SourceTestFailure('source_search_identity_missing', 'search', {
        expectedId: contentId,
        attempts: requests.length,
      });
    }
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
  const chapters = await runStage('chapters', async () => {
    const options = plugin.deferredGroups === true ? { supportsDeferredGroups: true } : {};
    const initial = await plugin.getChapters({ id: selectedId, ...options });
    if (!initial.groups?.some(group => group.deferred)) return initial;
    if (plugin.deferredGroups !== true || initial.groups.length > 128) throw new SourceTestFailure('source_media_groups_invalid', 'chapters', {});
    // Verification intentionally visits every line. Normal UI never does this.
    const groups = [];
    for (const group of initial.groups) {
      if (!group.deferred) { groups.push(group); continue; }
      if (group.episodes.length !== 0) throw new SourceTestFailure('source_media_groups_invalid', 'chapters', {});
      const result = await plugin.getChapters({ id: selectedId, groupId: group.id, ...options });
      const loaded = result.groups?.find(candidate => candidate.id === group.id && !candidate.deferred);
      if (!loaded || loaded.episodes.length === 0) throw new SourceTestFailure('source_media_groups_invalid', 'chapters', {});
      groups.push(loaded);
    }
    return { ...initial, groups, items: groups.flatMap(group => group.episodes) };
  });
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

  for (const ordered of chapters.groups?.length ? chapters.groups.map(group => group.episodes) : [chapterItems]) {
  for (let index = 1; index < ordered.length; index += 1) {
    const previous = ordered[index - 1]?.order;
    const current = ordered[index]?.order;
    if (Number.isFinite(previous) && Number.isFinite(current) && current < previous) {
      throw new SourceTestFailure('source_chapters_unordered', 'chapters', { index });
    }
  }
  }
  validateMediaGroups(detail, chapters, chapterIds);

  const readableChapters = chapterItems.filter((chapter) => chapter?.isLocked !== true);
  if (readableChapters.length === 0) {
    throw new SourceTestFailure('source_chapters_no_readable_sample', 'content', {
      items: chapterItems.length,
    });
  }
  const sampleIndexes = [...new Set([0, Math.floor((readableChapters.length - 1) / 2), readableChapters.length - 1])];
  const contents = [];
  let contentUnits = 0;
  for (const sampleIndex of sampleIndexes) {
    const chapterId = readableChapters[sampleIndex].id;
    const content = await runStage(
      `content.${sampleIndex}`,
      () => plugin.getContent({ id: selectedId, chapterId }),
    );
    if (content?.chapterId !== chapterId) {
      throw new SourceTestFailure('source_content_chapter_mismatch', 'content', {
        sampleIndex,
      });
    }
    if (detail?.contentKind !== undefined && content?.contentKind !== detail.contentKind) {
      throw new SourceTestFailure('source_content_kind_mismatch', 'content', {
        expected: detail.contentKind,
        actual: content?.contentKind ?? null,
        sampleIndex,
      });
    }
    validateTypedContent(content, sampleIndex);
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
    discoveryItems: Object.freeze(discoveryItems),
    searchItems: Object.freeze(searchItems),
    suggestionItems: Object.freeze(suggestionItems),
    selectedId,
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

function validateTypedContent(content, sampleIndex) {
  if (content?.contentKind === 'manga') {
    const pages = Array.isArray(content.pages) ? content.pages : [];
    const ids = pages.map((page) => page?.id);
    const indexes = pages.map((page) => page?.index);
    if (
      ids.some((id) => typeof id !== 'string' || id.length === 0)
      || new Set(ids).size !== ids.length
      || indexes.some((index) => !Number.isSafeInteger(index))
      || new Set(indexes).size !== indexes.length
      || indexes.some((index, position) => position > 0 && index < indexes[position - 1])
      || pages.some((page) => typeof page?.url !== 'string' || page.url.length === 0)
    ) {
      throw new SourceTestFailure('source_manga_pages_invalid', 'content', { sampleIndex });
    }
  }
  if (content?.contentKind === 'audio' && content?.media?.resourceType !== 'audio') {
    throw new SourceTestFailure('source_audio_media_invalid', 'content', { sampleIndex });
  }
  if (
    content?.contentKind === 'video'
    && content?.media?.resourceType !== 'video'
    && content?.media?.resourceType !== 'hls'
  ) {
    throw new SourceTestFailure('source_video_media_invalid', 'content', { sampleIndex });
  }
}

function validateMediaGroups(detail, chapters, chapterIds) {
  if (detail?.contentKind !== 'audio' && detail?.contentKind !== 'video') return;
  const groups = Array.isArray(chapters?.groups) ? chapters.groups : [];
  const groupIds = groups.map((group) => group?.id);
  const episodeIds = groups.flatMap((group) =>
    Array.isArray(group?.episodes) ? group.episodes.map((episode) => episode?.id) : []
  );
  const chapterSet = new Set(chapterIds);
  if (
    groups.length === 0
    || groupIds.some((id) => typeof id !== 'string' || id.length === 0)
    || new Set(groupIds).size !== groupIds.length
    || episodeIds.length !== chapterIds.length
    || new Set(episodeIds).size !== episodeIds.length
    || episodeIds.some((id) => !chapterSet.has(id))
  ) {
    throw new SourceTestFailure('source_media_groups_invalid', 'chapters', {
      contentKind: detail.contentKind,
      groups: groups.length,
      chapters: chapterIds.length,
      episodes: episodeIds.length,
    });
  }
  for (let index = 1; index < groups.length; index += 1) {
    const previous = groups[index - 1]?.order;
    const current = groups[index]?.order;
    if (Number.isFinite(previous) && Number.isFinite(current) && current < previous) {
      throw new SourceTestFailure('source_media_groups_unordered', 'chapters', { index });
    }
  }
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
