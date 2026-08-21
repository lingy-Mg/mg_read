import assert from 'node:assert/strict';
import test from 'node:test';

import { PluginContentValidationError, validateDiscoverResult } from '../dist/plugin-content.js';

const content = {
  id: 'book:1', title: '验证书籍', contentKind: 'novel', author: null, url: null,
  coverUrl: null, description: null, language: null, status: 'unknown', access: 'unknown',
  wordCount: null, chapterCount: 0, publishedAt: null, updatedAt: null,
  latestChapter: null, categories: [], tags: [], attributes: [],
};

test('recursive discovery document accepts bounded semantic components', () => {
  const result = validateDiscoverResult('org.example.tree', '树书源', {
    kind: 'document',
    document: { components: [{
      type: 'tabs', id: 'tabs', tabs: [{ id: 'all', label: '全部', target: 'all' }], selectedTabId: 'all',
    }, {
      type: 'section', id: 'section', title: '标题', subtitle: null, children: [{
        type: 'group', id: 'group', layout: 'vertical', children: [{
          type: 'contentCollection', id: 'books', layout: 'list', continuation: { target: 'all', cursor: 'more' },
          items: [{ content, rank: null, metric: null, recommendation: null }],
        }],
      }],
    }] },
  });
  assert.equal(result.kind, 'document');
  assert.equal(result.document.components[1].type, 'section');
});

test('discovery document rejects unknown, duplicate, and misplaced components', () => {
  for (const components of [
    [{ type: 'unknown', id: 'x' }],
    [{ type: 'section', id: 'same', title: 'A', subtitle: null, children: [] }, { type: 'divider', id: 'same' }],
    [{ type: 'section', id: 'outer', title: 'A', subtitle: null, children: [{ type: 'tabs', id: 'tabs', tabs: [], selectedTabId: null }] }],
  ]) {
    assert.throws(
      () => validateDiscoverResult('org.example.tree', '树书源', { kind: 'document', document: { components } }),
      PluginContentValidationError,
    );
  }
});

test('append response keeps only a declared collection payload', () => {
  const append = validateDiscoverResult('org.example.tree', '树书源', {
    kind: 'append', collectionId: 'books', continuation: null,
    items: [{ content, rank: null, metric: null, recommendation: null }],
  });
  assert.equal(append.kind, 'append');
  assert.equal(append.collectionId, 'books');
});
