import { parsePlaylist } from './playlist.mjs';
export const homepage = 'https://github.com/zhi35/iptv';
export const playlistUrls = [
    'https://live.zhi35.com/iptv.m3u',
    'https://raw.githubusercontent.com/zhi35/iptv/master/iptv.m3u',
];
const maximumBytes = 2 * 1024 * 1024;
export function createPlaylistStore(context, now = Date.now) {
    let cached;
    let pending;
    return { load };
    async function load(refresh = false) {
        if (!refresh && cached !== undefined && now() - cached.time < 5 * 60_000)
            return cached.playlist;
        if (pending !== undefined)
            return pending;
        const current = fetchPlaylist().catch((error) => {
            if (cached !== undefined && now() - cached.time < 24 * 60 * 60_000) {
                context.log.warn('iptv_playlist_stale');
                return cached.playlist;
            }
            throw error;
        });
        pending = current;
        try {
            return await current;
        }
        finally {
            if (pending === current)
                pending = undefined;
        }
    }
    async function fetchPlaylist() {
        for (let index = 0; index < playlistUrls.length; index += 1) {
            try {
                const response = await context.http.fetch(playlistUrls[index], {
                    headers: { Accept: 'application/vnd.apple.mpegurl,audio/x-mpegurl,text/plain,*/*' },
                    signal: AbortSignal.timeout(12_000),
                });
                if (!response.ok) {
                    await response.body?.cancel();
                    throw new Error('playlist_http_failed');
                }
                const playlist = parsePlaylist(await readBoundedText(response));
                cached = { playlist, time: now() };
                context.log.info(`iptv_playlist_loaded channels=${playlist.channels.length} endpoint=${index + 1}`);
                return playlist;
            }
            catch {
                context.log.warn(`iptv_playlist_request_failed endpoint=${index + 1}`);
            }
        }
        throw new Error('IPTV 播放列表暂时无法获取，请稍后重试。');
    }
}
async function readBoundedText(response) {
    if (Number(response.headers.get('content-length')) > maximumBytes) {
        await response.body?.cancel();
        throw new Error('playlist_too_large');
    }
    if (response.body === null)
        throw new Error('playlist_empty');
    const reader = response.body.getReader();
    const chunks = [];
    let size = 0;
    try {
        while (true) {
            const chunk = await reader.read();
            if (chunk.done)
                break;
            size += chunk.value.byteLength;
            if (size > maximumBytes)
                throw new Error('playlist_too_large');
            chunks.push(chunk.value);
        }
        return Buffer.concat(chunks).toString('utf8');
    }
    finally {
        await reader.cancel().catch(() => { });
        reader.releaseLock();
    }
}
