/** 站内身份与 URL 边界；旧套图 ID 保持不变，执行请求使用当前规范路由。 */
export const base = 'https://xchina001.ink';
export const clean = (s) => s.replace(/\s+/gu, ' ').trim();
export const encode = (s) => Buffer.from(s).toString('base64url');
export function entry(path) {
    const m = /^\/(photo|fiction|video)\/(?:id-)?([a-zA-Z0-9_-]+?)(?:\.html)?$/u.exec(path);
    if (!m)
        throw new Error('Content path is invalid.');
    const kind = m[1] === 'photo' ? 'manga' : m[1] === 'fiction' ? 'novel' : 'video';
    return { path: `/${m[1]}/${m[2]}`, kind, nativeId: m[2] };
}
export function idOf(e) {
    return `${e.kind}:${encode(e.kind === 'manga' ? `/photo/id-${e.nativeId}.html` : e.path)}`;
}
export function fromId(id) {
    const m = /^(manga|novel|video):([A-Za-z0-9_-]+)$/u.exec(id);
    if (!m)
        throw new Error('Content ID is invalid.');
    const e = entry(Buffer.from(m[2], 'base64url').toString('utf8'));
    if (e.kind !== m[1] || idOf(e) !== id)
        throw new Error('Content ID is invalid.');
    return e;
}
export function sitePath(value) {
    const u = new URL(value, base);
    if (u.origin !== base || u.username || u.password || u.hash)
        throw new Error('Source URL is invalid.');
    return u.pathname + u.search;
}
export function resource(value) {
    const u = new URL(value, base);
    if (u.protocol !== 'https:' || u.username || u.password || u.port ||
        ![new URL(base).hostname, 'img.xchina.io', 'upload.xchina.io', 'r2.xchina.download'].includes(u.hostname)) {
        throw new Error('Resource URL is invalid.');
    }
    return u.href;
}
