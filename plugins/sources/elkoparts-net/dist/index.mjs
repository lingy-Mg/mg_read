/**
 * MgRead Plugin API v1 entry for the Elkoparts source.
 * Activation stores only the public Runtime context and creates one reusable source parser.
 */
import { ElkopartsSource } from './source.js';
let context;
let source;
export async function activate(nextContext) {
    context = nextContext;
    source = new ElkopartsSource(nextContext);
    nextContext.log.info('plugin_activated');
}
export async function discover(request) {
    return invoke('discover', (activeSource) => activeSource.discover(request));
}
export async function search(request) {
    return invoke('search', (activeSource) => activeSource.search(request));
}
export async function searchSuggestions(request) {
    return invoke('search_suggestions', async (activeSource) => activeSource.searchSuggestions(request));
}
export async function getDetail(request) {
    return invoke('get_detail', (activeSource) => activeSource.getDetail(request));
}
export async function getChapters(request) {
    return invoke('get_chapters', (activeSource) => activeSource.getChapters(request));
}
export async function getContent(request) {
    return invoke('get_content', (activeSource) => activeSource.getContent(request));
}
async function invoke(operation, action) {
    const activeContext = requireActivated(context);
    const activeSource = requireActivated(source);
    activeContext.log.info(`source_${operation}_started`);
    try {
        const result = await action(activeSource);
        activeContext.log.info(`source_${operation}_completed`);
        return result;
    }
    catch {
        activeContext.log.warn(`source_${operation}_failed`);
        throw new Error('Source operation failed.');
    }
}
function requireActivated(value) {
    if (value === undefined)
        throw new Error('Source is not activated.');
    return value;
}
