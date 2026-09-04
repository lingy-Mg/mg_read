/**
 * 艾西书屋网页解析工具。
 *
 * 职责：
 * - 解析数据源页面中的稳定展示字段与分页信息。
 * - 校验并规范化向宿主暴露的文本、ID 与 URL。
 *
 * 注意：
 * - 不执行网络请求或写入缓存。
 * - 仅返回不可变、已校验的插件契约数据。
 *
 */
import * as cheerio from 'cheerio/slim';
import { nonBlank } from './utils.js';
export function mergeDiscoverySummary(summary, detail) {
    return Object.freeze({
        ...summary,
        author: summary.author ?? detail.author,
        coverUrl: summary.coverUrl ?? detail.coverUrl,
        description: summary.description ?? detail.description,
        status: summary.status === 'unknown' ? detail.status : summary.status,
        access: summary.access === 'unknown' ? detail.access : summary.access,
        wordCount: summary.wordCount ?? detail.wordCount,
        chapterCount: summary.chapterCount ?? detail.chapterCount,
        updatedAt: summary.updatedAt ?? detail.updatedAt,
        latestChapter: summary.latestChapter ?? detail.latestChapter,
        categories: summary.categories.length === 0
            ? detail.categories
            : summary.categories,
        tags: summary.tags.length === 0 ? detail.tags : summary.tags,
        attributes: summary.attributes.length === 0
            ? detail.attributes
            : summary.attributes,
    });
}
export function discoveryMetric(content) {
    const heat = content.attributes.find((attribute) => attribute.key === 'heat');
    if (heat === undefined)
        return null;
    return Object.freeze({ label: heat.label, value: displayCount(heat.value) });
}
export function requiredText(value) {
    const text = textOrNull(value);
    if (text === null)
        throw new Error('A required source field was empty.');
    return text;
}
export function textOrNull(value) {
    return nonBlank(value);
}
export function novelIdFromUrl(url) {
    return /^\/novel\/(\d+)\.html$/u.exec(url.pathname)?.[1] ?? null;
}
export function decodeNovelId(id) {
    const match = /^novel:(\d+)$/u.exec(id);
    if (match?.[1] === undefined)
        throw new Error('Novel ID is invalid.');
    return match[1];
}
export function decodePageCursor(cursor, scope) {
    if (cursor === null)
        return 1;
    const match = new RegExp(`^${scope}:(\\d+)$`, 'u').exec(cursor);
    const value = match?.[1] === undefined ? Number.NaN : Number(match[1]);
    if (!Number.isSafeInteger(value) || value < 1)
        throw new Error('Cursor is invalid.');
    return value;
}
export function encodePageCursor(scope, value) {
    return `${scope}:${value}`;
}
export function boundedPageSize(value) {
    if (!Number.isSafeInteger(value) || value < 1) {
        throw new Error('Chapter page size is invalid.');
    }
    return Math.min(value, 100);
}
export function parseDetailStats($info) {
    const rows = new Map();
    $info.find('p').each((_, element) => {
        const raw = compactSourceText($info.find(element).text());
        const separator = raw.indexOf('：');
        if (separator <= 0)
            return;
        rows.set(raw.slice(0, separator), raw);
    });
    const heatAndFavorites = rows.get('热度') ?? '';
    const wordAndChapters = rows.get('字数') ?? '';
    const heat = parseLabeledCount(heatAndFavorites, '热度');
    const favorites = parseLabeledCount(heatAndFavorites, '收藏');
    const wordCount = parseLabeledCount(wordAndChapters, '字数');
    const chapterCount = parseLabeledCount(wordAndChapters, '章节');
    const attributes = [];
    if (heat !== null) {
        attributes.push(Object.freeze({ key: 'heat', label: '热度', value: String(heat) }));
    }
    if (favorites !== null) {
        attributes.push(Object.freeze({ key: 'favorites', label: '收藏', value: String(favorites) }));
    }
    return Object.freeze({
        wordCount,
        chapterCount,
        status: parseContentStatus(rows.get('状态')),
        attributes: Object.freeze(attributes),
    });
}
export function parseTags($) {
    const tags = $('.tags_list a[href*="f=tag"], .tags_list a[href*="f%3Dtag"]')
        .toArray()
        .flatMap((element) => {
        const tag = textOrNull($(element).clone().find('em, span').remove().end().text());
        return tag === null ? [] : [tag];
    });
    return Object.freeze([...new Set(tags)].slice(0, 20));
}
export function parseSourceDate(value) {
    const match = /(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2})/u.exec(value);
    if (match === null)
        return null;
    const iso = `${match[1]}-${match[2]}-${match[3]}T${match[4]}:${match[5]}:00+08:00`;
    return Number.isNaN(Date.parse(iso)) ? null : new Date(iso).toISOString();
}
export function parseCatalogTotalCount($) {
    const text = compactSourceText($('.book_newchap .tit, .mulu_title, .catalog_title').first().text());
    const match = /全(\d+)章/u.exec(text);
    if (match?.[1] === undefined)
        return null;
    const count = Number(match[1]);
    return Number.isSafeInteger(count) && count >= 0 ? count : null;
}
export function findNextCatalogPage($, catalogUrl, novelId, currentPage) {
    const next = $('.pagination a[href], .page a[href], .pages a[href], a[rel="next"]')
        .toArray()
        .find((element) => /^(?:下一页|下页|next|›|»|>)$/iu.test(compactSourceText($(element).text())) || $(element).attr('rel') === 'next');
    const href = next === undefined ? undefined : $(next).attr('href');
    if (href === undefined)
        return null;
    try {
        const url = new URL(href, catalogUrl);
        if (url.origin !== catalogUrl.origin || !url.pathname.endsWith(`/id/${novelId}.html`)) {
            return null;
        }
        const value = Number(url.searchParams.get('page') ?? url.searchParams.get('p'));
        return Number.isSafeInteger(value) && value > currentPage ? value : null;
    }
    catch {
        return null;
    }
}
export function publicHttpUrl(value, base) {
    try {
        const url = new URL(value, base);
        if ((url.protocol !== 'http:' && url.protocol !== 'https:') ||
            url.username.length !== 0 ||
            url.password.length !== 0) {
            return null;
        }
        return url.toString();
    }
    catch {
        return null;
    }
}
export function publicCoverUrl(value, base) {
    const normalized = textOrNull(value);
    return normalized === null ? null : publicHttpUrl(normalized, base);
}
function displayCount(value) {
    const count = Number(value);
    if (!Number.isFinite(count))
        return value;
    if (count >= 100000000)
        return `${trimCount(count / 100000000)}亿`;
    if (count >= 10000)
        return `${trimCount(count / 10000)}万`;
    return String(Math.round(count));
}
function trimCount(value) {
    return value.toFixed(1).replace(/\.0$/u, '');
}
function parseContentStatus(value) {
    const normalized = compactSourceText(value ?? '');
    if (/(?:连载|更新中)/u.test(normalized))
        return 'ongoing';
    if (/(?:已)?完结/u.test(normalized))
        return 'completed';
    if (/(?:暂停|断更|停更)/u.test(normalized))
        return 'hiatus';
    return 'unknown';
}
function parseLabeledCount(value, label) {
    const match = new RegExp(`${label}[：:]?([0-9]+(?:\\.[0-9]+)?)([万亿]?)`, 'u').exec(compactSourceText(value));
    if (match?.[1] === undefined)
        return null;
    const number = Number(match[1]);
    const multiplier = match[2] === '万' ? 10000 : match[2] === '亿' ? 100000000 : 1;
    const result = Math.round(number * multiplier);
    return Number.isSafeInteger(result) && result >= 0 ? result : null;
}
export function compactSourceText(value) {
    return value.replace(/\s+/gu, '').trim();
}
