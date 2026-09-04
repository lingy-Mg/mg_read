import { discoveryMetric } from './source-parsing.js';
import { rankingRules } from './source-cache-policy.js';
export function buildHomeDiscoveryComponents(home, categories) {
    const components = [];
    if (home.featured.length !== 0) {
        components.push(section('source-featured-section', '重磅推荐', null, 'recommendation', Object.freeze([Object.freeze({
                type: 'contentCollection',
                id: 'source-featured-books',
                layout: 'carousel',
                items: discoveryItems(home.featured),
                continuation: null,
            })])));
    }
    if (home.originals.length !== 0) {
        components.push(section('source-originals-section', '原创新作', '来自官网原创专区', 'newRelease', Object.freeze([Object.freeze({
                type: 'contentCollection',
                id: 'source-original-books',
                layout: 'coverGrid',
                items: discoveryItems(home.originals),
                continuation: null,
            })])));
    }
    components.push(Object.freeze({
        type: 'group',
        id: 'source-navigation-group',
        layout: 'vertical',
        children: Object.freeze([
            section('source-categories-section', '按题材找书', '快速筛选感兴趣的小说类型', 'category', Object.freeze([Object.freeze({
                    type: 'categoryCollection',
                    id: 'source-categories',
                    layout: 'chips',
                    categories: Object.freeze(categories.map((category) => Object.freeze({
                        id: `category:${category.id}`,
                        title: category.title,
                        target: `category:${category.id}`,
                        count: null,
                        url: null,
                        icon: categoryIcon(category.title),
                    }))),
                })])),
            section('source-rankings-section', '热门榜单', '按时段查看站内热度排行', 'ranking', Object.freeze([Object.freeze({
                    type: 'categoryCollection',
                    id: 'source-rankings',
                    layout: 'grid',
                    categories: Object.freeze(rankingRules.map((ranking) => Object.freeze({
                        id: `ranking:${ranking.id}`,
                        title: ranking.title,
                        target: `ranking:${ranking.id}`,
                        count: null,
                        url: null,
                        icon: ranking.icon,
                    }))),
                })])),
        ]),
    }));
    if (home.popular.length !== 0) {
        components.push(section('source-popular-section', '热门推荐小说', '官网读者正在关注', 'hot', Object.freeze([Object.freeze({
                type: 'contentCollection',
                id: 'source-popular-books',
                layout: 'compact',
                items: discoveryItems(home.popular),
                continuation: null,
            })])));
    }
    return Object.freeze(components);
}
function section(id, title, subtitle, icon, children) {
    return Object.freeze({ type: 'section', id, title, subtitle, icon, children });
}
function categoryIcon(title) {
    if (title.includes('科幻'))
        return 'scienceFiction';
    if (title.includes('经典'))
        return 'classic';
    if (title.includes('奇幻') || title.includes('玄幻'))
        return 'fantasy';
    if (title.includes('系统'))
        return 'system';
    if (title.includes('武侠'))
        return 'wuxia';
    if (title.includes('都市'))
        return 'urban';
    if (title.includes('乡村'))
        return 'rural';
    if (title.includes('同人'))
        return 'fanFiction';
    if (title.includes('校园'))
        return 'school';
    if (title.includes('穿越'))
        return 'timeTravel';
    if (title.includes('纯爱') || title.includes('言情') || title.includes('百合') || title.includes('耽美'))
        return 'romance';
    if (title.includes('明星'))
        return 'star';
    if (title.includes('其他'))
        return 'other';
    return 'category';
}
function discoveryItems(contents) {
    return Object.freeze(contents.map((content) => Object.freeze({
        content,
        rank: null,
        metric: discoveryMetric(content),
        recommendation: null,
    })));
}
