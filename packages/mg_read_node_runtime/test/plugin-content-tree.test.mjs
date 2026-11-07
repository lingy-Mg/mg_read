import assert from 'node:assert/strict';
import test from 'node:test';

import { PluginContentValidationError, validateDiscoverResult } from '../dist/plugin-content.js';
import { assertInlineBudget } from '../dist/plugin-content-validation.js';
import { MAX_INLINE_RESULT_BYTES } from '../dist/plugin-content-types.js';

const content = {
  id: 'book:1', title: '验证书籍', contentKind: 'novel', author: null, url: null,
  coverUrl: null, description: null, language: null, status: 'unknown', access: 'unknown',
  wordCount: null, chapterCount: 0, publishedAt: null, updatedAt: null,
  latestChapter: null, categories: [], tags: [], attributes: [],
};

test('filter groups keep selected source targets and permit a full 45-option genre row', () => {
  const options = Array.from({ length: 45 }, (_, index) => ({ id: `genre:${index}`, label: `剧情 ${index}`, target: `filter:${index}` }));
  const component = { type: 'filters', id: 'library-filters', resetTarget: 'library', groups: [
    { id: 'genre', label: '剧情', selectedOptionId: 'genre:20', options },
  ] };
  const validate = value => validateDiscoverResult('org.example.filters', '筛选来源', { kind: 'document', document: { components: [value] } });
  const result = validate(component).document.components[0];
  assert.equal(result.groups[0].options.length, 45);
  assert.equal(result.groups[0].selectedOptionId, 'genre:20');
  assert.equal(result.resetTarget, 'library');
  for (const invalid of [
    { ...component, resetTarget: null },
    { ...component, groups: [...component.groups, ...component.groups] },
    { ...component, groups: [{ ...component.groups[0], selectedOptionId: 'missing' }] },
    { ...component, groups: [{ ...component.groups[0], options: [...options, options[0]] }] },
    { ...component, groups: [{ ...component.groups[0], options: Array.from({ length: 65 }, (_, i) => ({ id: `${i}`, label: `${i}`, target: `${i}` })) }] },
  ]) assert.throws(() => validate(invalid), PluginContentValidationError);
});

test('inline discovery search validates required bounded labels', () => {
  const input = { type: 'searchInput', id: 'link', label: '视频链接', placeholder: 'BV…', submitLabel: '读取音频' };
  const validate = (component) => validateDiscoverResult('org.example.input', '输入来源', {
    kind: 'document', document: { components: [component] },
  });
  assert.deepEqual(validate(input).document.components[0], input);
  for (const field of ['label', 'placeholder', 'submitLabel']) {
    for (const value of [undefined, null, '', 'x'.repeat(10000)]) {
      assert.throws(() => validate({ ...input, [field]: value }), PluginContentValidationError);
    }
  }
});

test('recursive discovery document accepts bounded semantic components', () => {
  const result = validateDiscoverResult('org.example.tree', '树数据源', {
    kind: 'document',
    document: { components: [{
      type: 'tabs', id: 'tabs', tabs: [{ id: 'all', label: '全部', target: 'all', icon: 'explore' }], selectedTabId: 'all',
    }, {
      type: 'section', id: 'section', title: '标题', subtitle: null, icon: 'recommendation', children: [{
        type: 'group', id: 'group', layout: 'vertical', children: [{
          type: 'contentCollection', id: 'books', layout: 'coverGrid', continuation: { target: 'all', cursor: 'more' },
          items: [{ content, rank: null, metric: null, recommendation: null }],
        }, {
          type: 'categoryCollection', id: 'categories', layout: 'chips', categories: [
            { id: 'category:1', title: '视频', target: 'category:1', count: null, url: null, icon: 'video' },
          ],
        }],
      }],
    }] },
  });
  assert.equal(result.kind, 'document');
  assert.equal(result.document.components[0].tabs[0].icon, 'explore');
  assert.equal(result.document.components[1].icon, 'recommendation');
  assert.equal(result.document.components[1].type, 'section');
  assert.equal(result.document.components[1].children[0].children[0].layout, 'coverGrid');
  assert.equal(result.document.components[1].children[0].children[1].layout, 'chips');
  assert.equal(result.document.components[1].children[0].children[1].categories[0].icon, 'video');
  assert.equal(result.document.components[1].children[0].children[0].items[0].content.coverOrientation, 'portrait');
});

test('profile card accepts bounded account details and rejects unsafe avatar URLs', () => {
  const profile = {
    type: 'profileCard', id: 'profile', name: '番茄读者', subtitle: '喜欢阅读', badge: '已登录',
    avatarUrl: 'http://127.0.0.1/avatar', details: [{ label: '用户 ID', value: '12345' }],
  };
  const validate = (component) => validateDiscoverResult('org.example.account', '账号数据源', {
    kind: 'document', document: { components: [component] },
  });
  const result = validate(profile);
  assert.deepEqual(result.document.components[0].details, [{ label: '用户 ID', value: '12345' }]);
  assert.throws(() => validate({ ...profile, avatarUrl: 'file:///secret.png' }), PluginContentValidationError);
  assert.throws(() => validate({ ...profile, details: [{ label: '用户 ID' }] }), PluginContentValidationError);
});

test('cover orientation accepts every host composition and rejects unknown component families', () => {
  const landscape = validateDiscoverResult('org.example.tree', '树数据源', {
    kind: 'document',
    document: { components: [{
      type: 'contentCollection', id: 'landscape', layout: 'coverGrid', continuation: null,
      items: [{ content: { ...content, coverOrientation: 'landscape' }, rank: null, metric: null, recommendation: null }],
    }] },
  });
  assert.equal(landscape.document.components[0].items[0].content.coverOrientation, 'landscape');
  const square = validateDiscoverResult('org.example.tree', '树数据源', {
    kind: 'document',
    document: { components: [{
      type: 'contentCollection', id: 'square', layout: 'coverGrid', continuation: null,
      items: [{ content: { ...content, coverOrientation: 'square' }, rank: null, metric: null, recommendation: null }],
    }] },
  });
  assert.equal(square.document.components[0].items[0].content.coverOrientation, 'square');
  assert.throws(
    () => validateDiscoverResult('org.example.tree', '树数据源', {
      kind: 'document',
      document: { components: [{
        type: 'contentCollection', id: 'invalid', layout: 'coverGrid', continuation: null,
        items: [{ content: { ...content, coverOrientation: 'panorama' }, rank: null, metric: null, recommendation: null }],
      }] },
    }),
    PluginContentValidationError,
  );
});

test('discovery document rejects unknown, duplicate, and misplaced components', () => {
  for (const components of [
    [{ type: 'unknown', id: 'x' }],
    [{ type: 'section', id: 'same', title: 'A', subtitle: null, children: [] }, { type: 'divider', id: 'same' }],
    [{ type: 'section', id: 'outer', title: 'A', subtitle: null, children: [{ type: 'tabs', id: 'tabs', tabs: [], selectedTabId: null }] }],
    [{ type: 'section', id: 'bad-icon', title: 'A', subtitle: null, icon: 'arbitrary-material-icon', children: [] }],
  ]) {
    assert.throws(
      () => validateDiscoverResult('org.example.tree', '树数据源', { kind: 'document', document: { components } }),
      PluginContentValidationError,
    );
  }
});

test('append response keeps only a declared collection payload', () => {
  const append = validateDiscoverResult('org.example.tree', '树数据源', {
    kind: 'append', collectionId: 'books', continuation: null,
    items: [{ content, rank: null, metric: null, recommendation: null }],
  });
  assert.equal(append.kind, 'append');
  assert.equal(append.collectionId, 'books');
});

test('discovery accepts responses above the old budgets and rejects more than 10 MiB', () => {
  const largeContent = {
    ...content,
    description: '详'.repeat(32_000),
  };
  const document = count => ({ kind: 'document', document: {
    components: Array.from({ length: Math.ceil(count / 50) }, (_, part) => ({
      type: 'contentCollection', id: `large:${part}`, layout: 'list', continuation: null,
      items: Array.from({ length: Math.min(50, count - part * 50) }, (_, index) => ({
        content: { ...largeContent, id: `book:${part * 50 + index}` },
        rank: null, metric: null, recommendation: null,
      })),
    })),
  } });
  const result = validateDiscoverResult('org.example.tree', '树数据源', document(100));
  const bytes = Buffer.byteLength(JSON.stringify(result), 'utf8');
  assert.ok(bytes > 4 * 1024 * 1024 && bytes < 10 * 1024 * 1024);
  assert.throws(
    () => validateDiscoverResult('org.example.tree', '树数据源', document(110)),
    error => error instanceof PluginContentValidationError &&
      /Response validation failed at the inline payload budget: \d+ bytes exceeds the 10485760-byte limit\./.test(error.message),
  );
});

test('inline result budget accepts exactly 10 MiB of UTF-8 JSON and rejects one byte more', () => {
  assert.equal(MAX_INLINE_RESULT_BYTES, 10 * 1024 * 1024);
  const overhead = Buffer.byteLength(JSON.stringify({ text: '' }));
  const text = '详'.repeat(Math.floor((MAX_INLINE_RESULT_BYTES - overhead) / 3));
  const padding = MAX_INLINE_RESULT_BYTES - overhead - Buffer.byteLength(text);
  const exact = { text: text + 'x'.repeat(padding) };
  assert.doesNotThrow(() => assertInlineBudget(exact));
  assert.throws(() => assertInlineBudget({ text: exact.text + 'x' }), /10485761 bytes exceeds the 10485760-byte limit/u);
});
