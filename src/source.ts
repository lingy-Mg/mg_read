// 此依赖展示可随插件交付的 packages/ 内 file: 包；不要替换为 Git、native addon 或安装期构建依赖。
import { formatExampleTitle } from '@mgread-plugin/example-parser';

import type {
  ChapterContent,
  ChaptersRequest,
  ChaptersResult,
  ContentDetail,
  ContentReferenceRequest,
  ContentRequest,
  ContentSummary,
  DiscoverRequest,
  DiscoverResult,
  SearchRequest,
  SearchResult,
} from './mgread-api.js';
import { stableExampleId } from './utils.js';

export function createLocalExampleSource(prefix: string) {
  // 这是确定性的离线替身，供 verify 验证标准导出、多个编译文件和本地包均可被 Runtime 使用。
  // 开发真实来源时替换其内部逻辑，保留各方法的稳定 ID 输入/输出契约。
  return Object.freeze({
    discover(_request: DiscoverRequest): DiscoverResult {
      const featured = createSummary(prefix, '发现示例');
      return Object.freeze({
        tabs: Object.freeze([
          Object.freeze({ id: 'recommend', label: '推荐', target: 'recommend' }),
          Object.freeze({ id: 'completed', label: '完本', target: 'completed' }),
        ]),
        selectedTabId: 'recommend',
        sections: Object.freeze([
          Object.freeze({
            id: 'featured',
            title: '编辑精选',
            subtitle: null,
            layout: 'featured',
            items: Object.freeze([
              Object.freeze({
                content: featured,
                rank: null,
                metric: null,
                recommendation: '模板离线推荐语',
              }),
            ]),
            categories: Object.freeze([]),
          }),
          Object.freeze({
            id: 'ranking',
            title: '排行榜',
            subtitle: null,
            layout: 'ranking',
            items: Object.freeze([
              Object.freeze({
                content: createSummary(prefix, '排行示例'),
                rank: 1,
                metric: Object.freeze({ label: '热度', value: '12345' }),
                recommendation: null,
              }),
            ]),
            categories: Object.freeze([]),
          }),
          Object.freeze({
            id: 'categories',
            title: '分类榜单',
            subtitle: null,
            layout: 'categories',
            items: Object.freeze([]),
            categories: Object.freeze([
              Object.freeze({
                id: 'template',
                title: '模板分类',
                target: 'category:template',
                count: 1,
                url: null,
              }),
            ]),
          }),
        ]),
        nextCursor: null,
      });
    },

    search(request: SearchRequest): SearchResult {
      return Object.freeze({
        items: Object.freeze([createSummary(prefix, request.query)]),
        nextCursor: null,
        totalCount: 1,
      });
    },

    getDetail(request: ContentReferenceRequest): ContentDetail {
      return Object.freeze({
        ...createSummary(prefix, request.id),
        id: request.id,
        aliases: Object.freeze([]),
        catalogUrl: null,
      });
    },

    getChapters(request: ChaptersRequest): ChaptersResult {
      return Object.freeze({
        items: Object.freeze([
          Object.freeze({
            id: `${request.id}:chapter-1`,
            title: '模板章节',
            order: 0,
            url: null,
            volumeTitle: null,
            wordCount: 12,
            updatedAt: '2026-08-15T00:00:00Z',
            isLocked: false,
            attributes: Object.freeze([]),
          }),
        ]),
        nextCursor: null,
        totalCount: 1,
      });
    },

    getContent(request: ContentRequest): ChapterContent {
      return Object.freeze({
        chapterId: request.chapterId,
        contentKind: 'novel',
        title: '模板章节',
        updatedAt: '2026-08-15T00:00:00Z',
        text: '这是离线模板正文，不会访问网络。',
        pages: Object.freeze([]),
      });
    },
  });
}

function createSummary(prefix: string, value: string): ContentSummary {
  const id = stableExampleId(value);
  return Object.freeze({
    id,
    title: formatExampleTitle(prefix, value),
    contentKind: 'novel',
    author: '请替换为真实作者投影',
    url: `https://example.invalid/books/${encodeURIComponent(id)}`,
    coverUrl: null,
    description: '这是离线模板数据，请替换为真实来源实现。',
    language: 'zh-CN',
    status: 'ongoing',
    access: 'free',
    wordCount: 12000,
    chapterCount: 1,
    publishedAt: null,
    updatedAt: '2026-08-15T00:00:00Z',
    latestChapter: Object.freeze({
      id: `${id}:chapter-1`,
      title: '模板章节',
      url: null,
      updatedAt: '2026-08-15T00:00:00Z',
    }),
    categories: Object.freeze(['模板分类']),
    tags: Object.freeze([]),
    attributes: Object.freeze([]),
  });
}
