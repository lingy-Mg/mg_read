import { safeHttpUrl } from './playlist.mjs';
export async function resolveMedia(context, url) {
    const path = new URL(url).pathname;
    if (/\.m3u8?$/iu.test(path))
        return { url, resourceType: 'hls', mimeType: 'application/vnd.apple.mpegurl' };
    if (/\.flv$/iu.test(path))
        return { url, resourceType: 'video', mimeType: 'video/x-flv' };
    if (/\.mp4$/iu.test(path))
        return { url, resourceType: 'video', mimeType: 'video/mp4' };
    const response = await context.http.fetch(url, {
        headers: { Accept: '*/*', Range: 'bytes=0-1023' },
        signal: AbortSignal.timeout(10_000),
    });
    const finalUrl = safeHttpUrl(response.url || url);
    const reader = response.body?.getReader();
    try {
        if (!response.ok || reader === undefined || finalUrl === null)
            throw new Error('直播线路暂时无法解析。');
        const chunks = [];
        let size = 0;
        while (size < 1024) {
            const chunk = await reader.read();
            if (chunk.done)
                break;
            const prefix = chunk.value.subarray(0, 1024 - size);
            chunks.push(prefix);
            size += prefix.byteLength;
            if (size >= 8)
                break;
        }
        const bytes = Buffer.concat(chunks);
        if (bytes.toString('utf8').replace(/^\uFEFF/u, '').trimStart().startsWith('#EXTM3U')) {
            return { url: finalUrl, resourceType: 'hls', mimeType: 'application/vnd.apple.mpegurl' };
        }
        if (bytes.subarray(0, 3).toString('ascii') === 'FLV')
            return { url: finalUrl, resourceType: 'video', mimeType: 'video/x-flv' };
        if (bytes.subarray(4, 8).toString('ascii') === 'ftyp')
            return { url: finalUrl, resourceType: 'video', mimeType: 'video/mp4' };
        const mime = (response.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase();
        if (bytes.length > 0 && /^video\//u.test(mime))
            return { url: finalUrl, resourceType: 'video', mimeType: mime };
        throw new Error('直播线路没有返回可识别的视频或 HLS。');
    }
    finally {
        if (reader !== undefined) {
            await reader.cancel().catch(() => { });
            reader.releaseLock();
        }
    }
}
