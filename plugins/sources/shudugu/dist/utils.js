/**
 * 速读谷无副作用字符串规范化工具。
 *
 * 职责：把来源文本折叠为空白规范的非空字符串或 null。
 * 注意：不执行网络、日志或缓存 IO。
 */
export function nonBlank(value) {
    const normalized = value?.replace(/\u00a0/g, ' ').replace(/\s+/g, ' ').trim();
    return normalized === undefined || normalized.length === 0 ? null : normalized;
}
