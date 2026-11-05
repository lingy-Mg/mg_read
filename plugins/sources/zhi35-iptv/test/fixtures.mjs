/** 最小 M3U fixture；涵盖真实上游的 tvg-name 重复、空台标、IPv6、授权查询、FLV 和多线路。 */
export const playlist = `\uFEFF#EXTM3U x-tvg-url="https://epg.example/list.xml" catchup="append"
#EXTINF:-1 tvg-name="CCTV5" tvg-logo="https://img.example/cctv5.png" group-title="央视频道",CCTV-5体育
http://[2409:8087:8:21::18]:6610/PLTV/224/5001/1.m3u8?accountinfo=first&GuardEncType=2
#EXTINF:-1 tvg-name="CCTV5" tvg-logo="https://img.example/cctv5plus.png" group-title="央视频道",CCTV-5+体育赛事
http://[2409:8087:8:21::18]:6610/PLTV/224/5002/1.m3u8
#EXTINF:-1 tvg-id="channel-hd" tvg-name="测试卫视" tvg-logo="https://img.example/hd.png" group-title="卫视频道",测试卫视
https://media.example/hd/index.m3u8?token=first
#EXTINF:-1 tvg-id="channel-hd" tvg-name="测试卫视" tvg-logo="" group-title="卫视频道",测试卫视
http://[2409:8087:8:21::18]/hd/index.m3u8?sign=first
#EXTINF:-1 tvg-id="scenic-001" tvg-name="风景原名" tvg-logo="" group-title="直播中国",❌ 风景,全景
https://media.example/scenic/index.m3u8
#EXTINF:-1 tvg-logo="https://img.example/local.png" group-title="地方频道",地方电视
https://media.example/local.flv
`;

export const hlsManifest = '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:1\n#EXTINF:6,\nsegment.ts\n';

export function contextFixture(fetch) {
  const resources = [], logs = [];
  return {
    resources, logs,
    context: {
      http: { fetch },
      errors: { raise(value) { const error = new Error(value.message); error.code = value.code; error.annotation = value.annotation; throw error; } },
      resource: { proxy(request) { resources.push(request); return `http://127.0.0.1:1234/v1/source-resource/fixture-resource-${resources.length}`; } },
      log: Object.fromEntries(['info', 'warn', 'debug', 'error'].map((level) => [level, (event) => logs.push({ level, event })])),
    },
  };
}

export const discoveryRequest = { target: null, cursor: null, collectionId: null, pageSize: 2 };
