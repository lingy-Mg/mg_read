import { ShuduguSource } from './source.js';
let context;
let source;
const sourceRules = Object.freeze({
    origin: 'https://www.shudugu.org',
    categories: Object.freeze([
        { id: 'dushi', title: '都市小说' },
        { id: 'xuanhuan', title: '玄幻小说' },
        { id: 'qing', title: '轻小说' },
        { id: 'xianxia', title: '仙侠小说' },
        { id: 'lishi', title: '历史小说' },
        { id: 'kehuan', title: '科幻小说' },
        { id: 'zhutianwuxian', title: '诸天无限' },
        { id: 'youxi', title: '游戏小说' },
        { id: 'qihuan', title: '奇幻小说' },
        { id: 'xuanyi', title: '悬疑小说' },
        { id: 'tiyu', title: '体育小说' },
        { id: 'guanchang', title: '官场小说' },
        { id: 'junshi', title: '军事小说' },
        { id: 'wuxia', title: '武侠小说' },
        { id: 'xiangcun', title: '乡村小说' },
        { id: 'xianshi', title: '现实小说' },
        { id: 'yanqing', title: '言情小说' },
    ]),
});
export async function activate(nextContext) {
    context = nextContext;
    source = new ShuduguSource(nextContext, sourceRules);
    nextContext.log.info('source_activated');
}
export async function discover(request) { return invoke('discover', () => requireSource().discover(request)); }
export async function search(request) { return invoke('search', () => requireSource().search(request)); }
export async function searchSuggestions(request) { return invoke('search_suggestions', () => requireSource().searchSuggestions(request)); }
export async function getDetail(request) { return invoke('get_detail', () => requireSource().getDetail(request)); }
export async function getChapters(request) { return invoke('get_chapters', () => requireSource().getChapters(request)); }
export async function getContent(request) { return invoke('get_content', () => requireSource().getContent(request)); }
function requireSource() { if (source === undefined)
    throw new Error('Source is not activated.'); return source; }
async function invoke(operation, action) {
    const activeContext = context;
    if (activeContext === undefined)
        throw new Error('Source is not activated.');
    activeContext.log.info(`source_${operation}_started`);
    try {
        activeContext.log.debug(`source_${operation}_validated`);
        const result = await action();
        activeContext.log.debug(`source_${operation}_parsed`);
        activeContext.log.info(`source_${operation}_result_ready`);
        activeContext.log.info(`source_${operation}_completed`);
        return result;
    }
    catch {
        activeContext.log.warn(`source_${operation}_failed`);
        throw new Error('Source operation failed.');
    }
}
