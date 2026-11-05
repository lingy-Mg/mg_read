import { resolveMedia } from './media.mjs';
export function createPlaybackResolver(context) {
    const preferred = new Map();
    return { resolve };
    async function resolve(channel, selected) {
        if (selected) {
            const media = await resolveMedia(context, selected.url, channel.title);
            remember(channel.id, selected.id);
            return media;
        }
        const last = preferred.get(channel.id);
        const candidates = channel.streams.flatMap((stream) => [
            { stream, proxyMode: undefined }, { stream, proxyMode: 'direct' },
        ]).sort((a, b) => Number(`${b.stream.id}:${b.proxyMode ?? 'default'}` === last) - Number(`${a.stream.id}:${a.proxyMode ?? 'default'}` === last)).slice(0, 8);
        const deadline = AbortSignal.timeout(10_000);
        let attempted = 0;
        for (const { stream, proxyMode } of candidates) {
            if (deadline.aborted)
                break;
            attempted += 1;
            try {
                const media = await resolveMedia(context, stream.url, channel.title, AbortSignal.any([deadline, AbortSignal.timeout(4000)]), proxyMode);
                remember(channel.id, stream.id, proxyMode);
                context.log.info(`iptv_auto_line_resolved attempts=${attempted} direct=${proxyMode === 'direct'}`);
                return { ...media, ...(proxyMode ? { proxyMode } : {}) };
            }
            catch {
                context.log.warn(`iptv_auto_line_failed attempt=${attempted}`);
            }
        }
        return context.errors.raise({
            code: 'source_media_resolution_failed', message: `${channel.title}：已尝试 ${attempted} 次线路连接，暂时无法打开直播。`,
            annotation: '请在“选集 / 线路”中手动选择其他线路，或稍后刷新；自动选择只检查打开前的直播清单。',
        });
    }
    function remember(channelId, streamId, proxyMode) {
        preferred.delete(channelId);
        preferred.set(channelId, `${streamId}:${proxyMode ?? 'default'}`);
        if (preferred.size > 512)
            preferred.delete(preferred.keys().next().value);
    }
}
