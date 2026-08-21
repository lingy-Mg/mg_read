/**
 * MgRead Runtime 在 activate 时一次性提供的公开能力边界。
 *
 * 这只是模板为类型检查保留的最小投影：使用 Node 标准库无需 SDK 包装；不要依赖 Runtime 的端口、
 * HTTP/WS 协议或未声明的私有字段。安装目录不可写，dataDir/cacheDir 才是可变文件位置。
 */
export interface MgReadPluginContext {
  readonly dataDir: string;
  readonly cacheDir: string;
  readonly http: {
    fetch(input: string | URL, init?: RequestInit): Promise<Response>;
  };
  readonly log: {
    debug(event: string): void;
    info(event: string): void;
    warn(event: string): void;
    error(event: string): void;
  };
  readonly app: {
    readonly runtimeVersion: string;
    readonly nodeVersion: string;
    readonly pluginApi: number;
  };
  readonly plugin: {
    readonly id: string;
    readonly version: string;
  };
}

export type ContentKind = 'novel' | 'manga';
export type ContentStatus = 'ongoing' | 'completed' | 'hiatus' | 'unknown';
export type AccessKind = 'free' | 'paid' | 'mixed' | 'unknown';
export type DiscoveryContentLayout =
  | 'featured'
  | 'carousel'
  | 'ranking'
  | 'list';
export type DiscoveryCategoryLayout = 'grid' | 'list';
export type DiscoveryGroupLayout = 'vertical' | 'horizontal' | 'grid';

export interface ContentAttribute {
  readonly key: string;
  readonly label: string;
  readonly value: string;
}

export interface LatestChapter {
  /** 可空来源章节 ID；有值时必须可传给 getContent。 */
  readonly id: string | null;
  readonly title: string;
  readonly url: string | null;
  readonly updatedAt: string | null;
}

/**
 * 搜索、发现和详情共用的固定富内容摘要。
 *
 * 可空字段的键也必须存在并显式返回 null。不要用缺键、undefined、空字符串、0 或“未知”文字
 * 代替 null；categories/tags/attributes 永远返回数组，没有值时使用 []。
 */
export interface ContentSummary {
  /** 稳定来源 ID；必须可传回 getDetail/getChapters，不能用 URL、页码或瞬时对象代替。 */
  readonly id: string;
  readonly title: string;
  readonly contentKind: ContentKind;
  readonly author: string | null;
  /** 来源详情 URL，只作元数据，不作为内容身份。 */
  readonly url: string | null;
  readonly coverUrl: string | null;
  readonly description: string | null;
  readonly language: string | null;
  readonly status: ContentStatus;
  readonly access: AccessKind;
  /** 0 是已知零值；未知或不适用必须为 null。 */
  readonly wordCount: number | null;
  readonly chapterCount: number | null;
  readonly publishedAt: string | null;
  readonly updatedAt: string | null;
  readonly latestChapter: LatestChapter | null;
  readonly categories: readonly string[];
  readonly tags: readonly string[];
  /** 来源特有元数据的有界强类型扩展，不能替换成任意 Map。 */
  readonly attributes: readonly ContentAttribute[];
}

export interface SearchRequest {
  readonly query: string;
  readonly cursor: string | null;
  readonly pageSize: number;
}

export interface SearchResult {
  readonly items: readonly ContentSummary[];
  readonly nextCursor: string | null;
  readonly totalCount: number | null;
}

export interface DiscoverRequest {
  /** 首次发现为 null；tab/分类返回的 target 只回传给当前插件。 */
  readonly target: string | null;
  readonly cursor: string | null;
  /** 仅 continuation 请求填写，定位需要追加的内容集合。 */
  readonly collectionId: string | null;
  readonly pageSize: number;
}

export interface DiscoveryTab {
  readonly id: string;
  readonly label: string;
  readonly target: string;
}

export interface DiscoveryMetric {
  readonly label: string;
  readonly value: string;
}

export interface DiscoveryContentItem {
  readonly content: ContentSummary;
  readonly rank: number | null;
  readonly metric: DiscoveryMetric | null;
  readonly recommendation: string | null;
}

export interface DiscoveryCategory {
  readonly id: string;
  readonly title: string;
  readonly target: string;
  readonly count: number | null;
  readonly url: string | null;
}

export interface DiscoveryContinuation {
  readonly target: string;
  readonly cursor: string;
}

export interface DiscoveryTabs {
  readonly type: 'tabs';
  readonly id: string;
  readonly tabs: readonly DiscoveryTab[];
  readonly selectedTabId: string | null;
}

export interface DiscoverySection {
  readonly type: 'section';
  readonly id: string;
  readonly title: string;
  readonly subtitle: string | null;
  readonly children: readonly DiscoveryComponent[];
}

export interface DiscoveryGroup {
  readonly type: 'group';
  readonly id: string;
  readonly layout: DiscoveryGroupLayout;
  readonly children: readonly DiscoveryComponent[];
}

export interface DiscoveryContentCollection {
  readonly type: 'contentCollection';
  readonly id: string;
  readonly layout: DiscoveryContentLayout;
  readonly items: readonly DiscoveryContentItem[];
  readonly continuation: DiscoveryContinuation | null;
}

export interface DiscoveryCategoryCollection {
  readonly type: 'categoryCollection';
  readonly id: string;
  readonly layout: DiscoveryCategoryLayout;
  readonly categories: readonly DiscoveryCategory[];
}

export interface DiscoveryText { readonly type: 'text'; readonly id: string; readonly text: string; }
export interface DiscoveryDivider { readonly type: 'divider'; readonly id: string; }
export type DiscoveryComponent = DiscoveryTabs | DiscoverySection | DiscoveryGroup | DiscoveryContentCollection | DiscoveryCategoryCollection | DiscoveryText | DiscoveryDivider;
export interface DiscoveryDocument { readonly components: readonly DiscoveryComponent[]; }

export type DiscoverResult =
  | { readonly kind: 'document'; readonly document: DiscoveryDocument }
  | {
      readonly kind: 'append';
      readonly collectionId: string;
      readonly items: readonly DiscoveryContentItem[];
      readonly continuation: DiscoveryContinuation | null;
    };

export interface ContentReferenceRequest {
  readonly id: string;
}

export interface ContentDetail extends ContentSummary {
  readonly aliases: readonly string[];
  readonly catalogUrl: string | null;
}

export interface ChaptersRequest {
  readonly id: string;
  readonly cursor: string | null;
  readonly pageSize: number;
}

export interface ChapterSummary {
  /** 稳定章节 ID；必须可传回 getContent。 */
  readonly id: string;
  readonly title: string;
  readonly order: number;
  readonly url: string | null;
  readonly volumeTitle: string | null;
  readonly wordCount: number | null;
  readonly updatedAt: string | null;
  readonly isLocked: boolean | null;
  readonly attributes: readonly ContentAttribute[];
}

export interface ChaptersResult {
  readonly items: readonly ChapterSummary[];
  readonly nextCursor: string | null;
  readonly totalCount: number | null;
}

export interface ContentRequest {
  readonly id: string;
  readonly chapterId: string;
}

export interface MangaPage {
  readonly id: string;
  readonly index: number;
  readonly url: string;
  readonly mimeType: string | null;
  readonly width: number | null;
  readonly height: number | null;
}

export interface ChapterContent {
  /** 与请求的 chapterId 对应，供调用方校验内容归属。 */
  readonly chapterId: string;
  readonly contentKind: ContentKind;
  readonly title: string | null;
  readonly updatedAt: string | null;
  /** 小说为正文（允许空正文），漫画必须为 null。 */
  readonly text: string | null;
  /** 漫画为非空有序页，小说必须为 []。 */
  readonly pages: readonly MangaPage[];
}
