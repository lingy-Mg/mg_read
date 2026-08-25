/**
 * 爱丽丝书源缓存策略与排行常量。
 *
 * 职责：定义 HTML/解析投影的 TTL、过期行为和稳定排行入口。
 * 注意：发现详情可以过期即返并后台刷新；显式详情和目录必须严格刷新。
 * TODO: - 无。
 */
import type { HtmlCachePolicy } from './html-cache.js';

export interface RankingRule { readonly id: string; readonly title: string; readonly path: string; }
export const rankingRules = Object.freeze([
  Object.freeze({ id: 'day', title: '本日排行', path: '/other/rank_hits/order/hits_day.html' }),
  Object.freeze({ id: 'week', title: '本周排行', path: '/other/rank_hits/order/hits_week.html' }),
  Object.freeze({ id: 'month', title: '本月排行', path: '/other/rank_hits/order/hits_month.html' }),
  Object.freeze({ id: 'total', title: '总排行', path: '/other/rank_hits/order/hits.html' }),
] satisfies readonly RankingRule[]);
export const discoveryListingHtmlCachePolicy = Object.freeze({ namespace: 'listing', staleAfterMs: 60 * 60 * 1000, serveStaleWhileRevalidate: true } satisfies HtmlCachePolicy);
export const searchListingHtmlCachePolicy = Object.freeze({ namespace: 'search', staleAfterMs: 10 * 60 * 1000 } satisfies HtmlCachePolicy);
export const detailHtmlCachePolicy = Object.freeze({ namespace: 'detail', staleAfterMs: 60 * 60 * 1000, allowStaleOnError: false } satisfies HtmlCachePolicy);
export const discoveryDetailHtmlCachePolicy = Object.freeze({ namespace: 'detail', staleAfterMs: 60 * 60 * 1000, serveStaleWhileRevalidate: true } satisfies HtmlCachePolicy);
export const detailProjectionCachePolicy = Object.freeze({ namespace: 'detail-projection-v1', staleAfterMs: 60 * 60 * 1000, allowStaleOnError: false } satisfies HtmlCachePolicy);
export const discoveryDetailProjectionCachePolicy = Object.freeze({ namespace: 'detail-projection-v1', staleAfterMs: 60 * 60 * 1000, serveStaleWhileRevalidate: true } satisfies HtmlCachePolicy);
export const catalogProjectionCachePolicy = Object.freeze({ namespace: 'catalog-projection-v1', staleAfterMs: 60 * 60 * 1000, allowStaleOnError: false } satisfies HtmlCachePolicy);
export const catalogHtmlCachePolicy = Object.freeze({ namespace: 'catalog', staleAfterMs: 60 * 60 * 1000, allowStaleOnError: false } satisfies HtmlCachePolicy);
export const hotSearchHtmlCachePolicy = Object.freeze({ namespace: 'hot-search', staleAfterMs: 24 * 60 * 60 * 1000 } satisfies HtmlCachePolicy);
export const discoveryHomeHtmlCachePolicy = Object.freeze({ namespace: 'discovery-home', staleAfterMs: 60 * 60 * 1000, serveStaleWhileRevalidate: true } satisfies HtmlCachePolicy);
export const rankingDescriptionMaxCharacters = 80;
export const rankingTagLimit = 4;
export const rankingAttributeLimit = 2;
