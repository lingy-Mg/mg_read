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
import { createLocalExampleSource } from './source.js';
import { requireActivated } from './utils.js';

let context: MgReadPluginContext | undefined;
let source: ReturnType<typeof createLocalExampleSource> | undefined;

/**
 * Runtime 对此不可变插件版本冷激活时调用一次。
 *
 * 可在这里保存 ctx、校验随包资源并创建可复用状态；入口模块本身不能假定 ctx 已存在。插件目录
 * 只读，后续需要可变数据时只能使用 ctx.dataDir 或 ctx.cacheDir。
 */
export async function activate(nextContext: MgReadPluginContext): Promise<void> {
  context = nextContext;
  const rules = JSON.parse(
    await readFile(new URL('../assets/rules.json', import.meta.url), 'utf8'),
  ) as { readonly titlePrefix?: unknown };
  if (typeof rules.titlePrefix !== 'string' || rules.titlePrefix.length === 0) {
    throw new Error('Template rules are invalid.');
  }
  source = createLocalExampleSource(rules.titlePrefix);
  context.log.info('plugin_activated');
}

/**
 * 发现返回 tab、受控分区和富内容摘要，才能被宿主发现页稳定映射。target/cursor 都是不透明值，
 * 只能回传给当前插件；不要让 Flutter 解析来源 URL 或网页结构。
 */
export async function discover(request: DiscoverRequest): Promise<DiscoverResult> {
  requireActivated(context);
  return requireActivated(source).discover(request);
}

/**
 * 搜索使用完整请求对象并返回显式分页结果。所有 nullable 字段必须保留键并返回具体值或 null；
 * 不能用 undefined、空字符串或 0 冒充未知值。
 */
export async function search(request: SearchRequest): Promise<SearchResult> {
  requireActivated(context);
  return requireActivated(source).search(request);
}

export async function getDetail(
  request: ContentReferenceRequest,
): Promise<ContentDetail> {
  // id 来自搜索/发现结果或已保存绑定；详情只投影元信息，不承担正文传输。
  return requireActivated(source).getDetail(request);
}

export async function getChapters(
  request: ChaptersRequest,
): Promise<ChaptersResult> {
  // 使用与详情一致的内容 ID 返回稳定章节 ID；阅读位置仍应由 Runtime 的语义锚点能力管理。
  return requireActivated(source).getChapters(request);
}

export async function getContent(request: ContentRequest): Promise<ChapterContent> {
  // chapterId 必须来自 getChapters；返回值中的 chapterId 用于防止异步结果与请求章节错配。
  return requireActivated(source).getContent(request);
}
