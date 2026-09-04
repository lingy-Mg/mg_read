export const rankingRules = Object.freeze([
    Object.freeze({ id: 'day', title: '本日排行', path: '/other/rank_hits/order/hits_day.html', icon: 'dailyRanking' }),
    Object.freeze({ id: 'week', title: '本周排行', path: '/other/rank_hits/order/hits_week.html', icon: 'weeklyRanking' }),
    Object.freeze({ id: 'month', title: '本月排行', path: '/other/rank_hits/order/hits_month.html', icon: 'monthlyRanking' }),
    Object.freeze({ id: 'total', title: '总排行', path: '/other/rank_hits/order/hits.html', icon: 'allTimeRanking' }),
]);
export const discoveryListingHtmlCachePolicy = Object.freeze({ namespace: 'listing', staleAfterMs: 60 * 60 * 1000, serveStaleWhileRevalidate: true });
export const searchListingHtmlCachePolicy = Object.freeze({ namespace: 'search', staleAfterMs: 10 * 60 * 1000 });
export const detailHtmlCachePolicy = Object.freeze({ namespace: 'detail', staleAfterMs: 60 * 60 * 1000, allowStaleOnError: false });
export const discoveryDetailHtmlCachePolicy = Object.freeze({ namespace: 'detail', staleAfterMs: 60 * 60 * 1000, serveStaleWhileRevalidate: true });
export const detailProjectionCachePolicy = Object.freeze({ namespace: 'detail-projection-v1', staleAfterMs: 60 * 60 * 1000, allowStaleOnError: false });
export const discoveryDetailProjectionCachePolicy = Object.freeze({ namespace: 'detail-projection-v1', staleAfterMs: 60 * 60 * 1000, serveStaleWhileRevalidate: true });
export const catalogProjectionCachePolicy = Object.freeze({ namespace: 'catalog-projection-v1', staleAfterMs: 60 * 60 * 1000, allowStaleOnError: false });
export const catalogHtmlCachePolicy = Object.freeze({ namespace: 'catalog', staleAfterMs: 60 * 60 * 1000, allowStaleOnError: false });
export const hotSearchHtmlCachePolicy = Object.freeze({ namespace: 'hot-search', staleAfterMs: 24 * 60 * 60 * 1000 });
export const discoveryHomeHtmlCachePolicy = Object.freeze({ namespace: 'discovery-home', staleAfterMs: 60 * 60 * 1000, serveStaleWhileRevalidate: true });
export const rankingDescriptionMaxCharacters = 80;
export const rankingTagLimit = 4;
export const rankingAttributeLimit = 2;
