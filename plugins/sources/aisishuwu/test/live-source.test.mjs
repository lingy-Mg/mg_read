import assert from 'node:assert/strict';
import test from 'node:test';

import {
  assertInlineJsonSize,
  createSourceTestHarness,
  probeReachableResource,
  runReadingSourceFlow,
} from '@mgread/source-testkit';
import * as plugin from '../dist/index.mjs';

// Explicit, opt-in online acceptance. It never writes pages or source content
// to disk, and asserts only stable structural facts about the public Plugin API.
test('live source completes category, search, detail, catalog, and content flow', { timeout: 60000 }, async (t) => {
  const harness = await createSourceTestHarness({
    plugin,
    pluginId: 'org.mgread.aisishuwu',
    version: '0.2.12',
    fetch,
    prefix: 'mgread-aisishuwu-live-',
    runtimeVersion: 'live-test',
  });
  t.after(harness.cleanup);
  const { resourceRequests } = harness;

  const categories = await plugin.discover({ target: null, cursor: null, collectionId: null, pageSize: 20 });
  assert.equal(categories.kind, 'document');
  assertInlineJsonSize(categories, { maximumBytes: 52 * 1024, stage: 'discover.home' });
  const featured = categories.document.components.find((component) => component.id === 'source-featured-section');
  assert.equal(featured?.type, 'section');
  assert.equal(featured?.children[0].layout, 'carousel');
  assert.ok(featured?.children[0].items.length > 1);
  const originals = categories.document.components.find((component) => component.id === 'source-originals-section');
  assert.equal(originals?.children[0].layout, 'coverGrid');
  assert.ok(originals?.children[0].items.length > 0);
  assert.ok(originals?.children[0].items.every((item) => item.content.coverUrl?.startsWith('http://127.0.0.1:1234/v1/source-resource/')));
  const popular = categories.document.components.find((component) => component.id === 'source-popular-section');
  assert.equal(popular?.children[0].layout, 'compact');
  assert.ok(popular?.children[0].items.length > 0);
  const navigation = categories.document.components.find((component) => component.id === 'source-navigation-group');
  assert.equal(navigation?.type, 'group');
  assert.ok(resourceRequests.length > 0);
  const categorySection = navigation.children.find((component) => component.id === 'source-categories-section');
  assert.equal(categorySection?.type, 'section');
  assert.equal(categorySection.children[0].layout, 'chips');
  const target = categorySection.children[0].categories[0].target;
  const reachableCover = await probeReachableResource({
    requests: resourceRequests,
    fetch,
    maximumAttempts: 4,
  });
  assert.match(reachableCover.contentType, /^image\//u);

  const discovery = await plugin.discover({ target, cursor: null, collectionId: null, pageSize: 5 });
  assert.equal(discovery.kind, 'document');
  const book = discovery.document.components[0].children[0].items[0].content;
  assert.match(book.id, /^novel:\d+$/u);
  assert.match(book.coverUrl ?? '', /^https?:\/\//u);

  for (const rankingTarget of ['ranking:day', 'ranking:week', 'ranking:month', 'ranking:total']) {
    const ranking = await plugin.discover({
      target: rankingTarget,
      cursor: null,
      collectionId: null,
      pageSize: 5,
    });
    assert.equal(ranking.kind, 'document');
    const collection = ranking.document.components[0].children[0];
    assert.equal(collection.layout, 'list');
    assert.ok(collection.items.length > 0);
    assert.ok(collection.items.every((item) => item.rank === null));
    assert.match(collection.items[0].content.coverUrl ?? '', /^https?:\/\//u);
    assert.ok((collection.items[0].content.description ?? '').trim().length > 0);
  }

  const flow = await runReadingSourceFlow({
    plugin,
    contentId: book.id,
    searchRequest: { query: '修仙', cursor: null, pageSize: 5 },
    suggestionsRequest: { cursor: null, pageSize: 5 },
  });
  const { detail, chapters, content } = flow;
  assert.equal(detail.id, book.id);
  assert.ok(detail.title.length > 0);
  assert.notEqual(detail.wordCount, null);
  assert.notEqual(detail.chapterCount, null);
  assert.notEqual(detail.status, 'unknown');

  const fixtureDetail = await plugin.getDetail({ id: 'novel:52801' });
  assert.equal(fixtureDetail.author, '喜欢老虎');
  assert.deepEqual(fixtureDetail.categories, ['科幻']);
  assert.equal(fixtureDetail.wordCount, 1859600);
  assert.equal(fixtureDetail.chapterCount, 733);
  assert.equal(fixtureDetail.status, 'ongoing');
  assert.ok(fixtureDetail.tags.length >= 5);

  const fixtureChapters = await plugin.getChapters({
    id: 'novel:52801',
  });
  assert.equal(fixtureChapters.items.length, 733);
  assert.equal(new Set(fixtureChapters.items.map((chapter) => chapter.id)).size, 733);
  assert.deepEqual(
    fixtureChapters.items.map((chapter) => chapter.order),
    Array.from({ length: 733 }, (_, index) => index),
  );

  assert.equal(content.chapterId, chapters.items[0].id);
  assert.equal(content.contentKind, 'novel');
  assert.ok((content.text ?? '').length > 0);
});
