/**
 * 四个公开 IPTV 列表的保守频道聚合，无 IO。
 * 原 zhi35 身份优先保留；新增频道沿用上游 EPG/资源摘要，标题只用于匹配，不作为内容主键。
 * 仅共享资源、标准 EPG、已核实央视/CGTN 别名或同地区完整名称可合并；通用频道名不跨资源合并。
 * 不折叠 CCTV5+、CCTV4 地区版、4K/8K、时移或不同国家的同名频道；保留旧 ID 和检索别名。
 * 完全相同的稳定资源只保留一条线路并汇总来源；授权地址不裁剪，IPv4 优先且组 ID 不依赖顺序。
 */
import { digest } from './playlist.mjs';
const priority = { 'iptv-org': 0, yuechan: 1, 'free-tv': 2, zhi35: 3 };
// 2026-11-05 Windows 实播确认：此资源虽被标为 CCTV1，画面台标实际为“花垣综合”。
// 只排除其 CCTV1 归属；不屏蔽同主机其他资源，亦不猜测/改写上游频道名。
const mislabeledCctv1 = new Set(['stream:4b60b42947402afdf4f89c3d']);
const cctvSuffixes = ['', '综合', '财经', '综艺', '中文国际', '体育', '电影', '国防军事', '电视剧', '纪录', '科教', '戏曲', '社会与法', '新闻', '少儿', '音乐', '奥林匹克', '农业农村'];
const cgtnNames = {
    cgtn: 'english', cgtn英语: 'english', cgtnenglish: 'english',
    cgtn记录: 'documentary', cgtn纪录: 'documentary', cgtndocumentary: 'documentary',
    cgtn西语: 'spanish', cgtn西班牙语: 'spanish', cgtnespanol: 'spanish', cgtnespañol: 'spanish', cgtnspanish: 'spanish',
    cgtn阿语: 'arabic', cgtn阿拉伯语: 'arabic', cgtnarabic: 'arabic',
    cgtn法语: 'french', cgtnfrancais: 'french', cgtnfrançais: 'french', cgtnfrench: 'french',
    cgtn俄语: 'russian', cgtnrussian: 'russian',
};
export function normalizedTitle(value) {
    return value.normalize('NFKC').toLowerCase()
        .replace(/\((?:\d{3,4}[pi](?:\d+)?|full\s*hd|fhd|hd|sd)\)|\[(?:geo-blocked|not 24\/7)\]/gu, '')
        .replace(/(?:高清|超清|标清)(?:频道)?$/u, '').replace(/[ⓢ❌]/gu, '').replace(/\s+/gu, '').trim();
}
function knownChannel(value) {
    const name = normalizedTitle(value);
    if (cgtnNames[name])
        return `cgtn:${cgtnNames[name]}`;
    const cctv = /^cctv-?(1[0-7]|[1-9])(\+)?(.*)$/u.exec(name);
    if (!cctv)
        return null;
    const number = Number(cctv[1]), plus = cctv[2] === '+', suffix = cctv[3];
    if (plus)
        return number === 5 && ['', '体育赛事', '体育赛事频道'].includes(suffix) ? 'cctv:5plus' : null;
    if (number === 4) {
        if (['', '中文国际', '中文国际(亚)', '中文国际(亚洲)', '亚洲', 'asia'].includes(suffix))
            return 'cctv:4asia';
        if (['中文国际(欧)', '中文国际(欧洲)', '欧洲', 'europe'].includes(suffix))
            return 'cctv:4europe';
        if (['中文国际(美)', '中文国际(美洲)', '美洲', 'america'].includes(suffix))
            return 'cctv:4america';
        return null;
    }
    return ['', cctvSuffixes[number], `${cctvSuffixes[number]}频道`, ...(number === 9 ? ['记录', '记录频道'] : [])].includes(suffix) ? `cctv:${number}` : null;
}
function standardEpg(value) {
    const id = value?.normalize('NFKC').toLowerCase().replace(/@(?:sd|hd|fhd|uhd|\d{3,4}[pi])$/u, '') ?? '';
    return /^[\w+-]+\.[a-z]{2,3}(?:@[\w+-]+)?$/u.test(id) ? id : null;
}
function epgChannel(id) {
    if (!id.endsWith('.cn'))
        return null;
    const name = id.slice(0, -3);
    if (name === 'cctv5plus')
        return 'cctv:5plus';
    if (/^cctv4(?:asia|europe|america)$/u.test(name))
        return `cctv:${name.slice(4)}`;
    return knownChannel(name);
}
function eligibleEpg(channel) {
    const epg = standardEpg(channel.epgId);
    const known = knownChannel(channel.title), epgKnown = epg === null ? null : epgChannel(epg);
    return known !== null && epgKnown !== null && known !== epgKnown ? null : epg;
}
function region(member) {
    if (member.provider.id !== 'free-tv')
        return 'chinese';
    const countries = member.channel.categories;
    if (countries.some((value) => /^(?:China|Taiwan|Hong Kong|Macau|Macao)$/iu.test(value)))
        return 'chinese';
    return countries.slice().sort().join('|').toLowerCase();
}
function keys(member) {
    const { channel, provider } = member;
    const result = channel.streams.map((stream) => stream.id);
    const known = knownChannel(channel.title);
    const epg = eligibleEpg(channel);
    const epgKnown = epg === null ? null : epgChannel(epg);
    // A conflicting EPG label must not override an explicit CCTV regional/plus title.
    if (epg !== null && (known === null || epgKnown === null || epgKnown === known))
        result.push(`epg:${epg}`);
    if (known !== null)
        result.push(`known:${known}`);
    else if (epgKnown !== null)
        result.push(`known:${epgKnown}`);
    const title = normalizedTitle(channel.title);
    if (title.length >= 3 && !/^(?:新闻综合|综合新闻|新闻|综合|公共|都市|生活|经济|体育|少儿|影视|电影|news|general|sports|tv)(?:频道|台)?$/u.test(title)) {
        result.push(`name:${region(member)}:${title}`);
    }
    result.push(`local:${provider.id}:${channel.id}`);
    return result;
}
function categories(member) {
    if (member.provider.id === 'iptv-org')
        return [knownChannel(member.channel.title) !== null ? '央视频道' : '国内频道'];
    if (member.provider.id !== 'free-tv')
        return member.channel.categories;
    return [region(member) === 'chinese' ? (member.channel.categories.includes('China') ? '国内频道' : '港台频道') : '国际频道'];
}
export function mergePlaylists(sources) {
    const members = sources.flatMap(({ provider, playlist }) => playlist.channels.flatMap((channel) => {
        const streams = knownChannel(channel.title) === 'cctv:1' ? channel.streams.filter((stream) => !mislabeledCctv1.has(stream.id)) : channel.streams;
        return streams.length ? [{ provider, channel: { ...channel, streams } }] : [];
    }));
    const parent = members.map((_, index) => index), owners = new Map();
    const root = (index) => {
        while (parent[index] !== index) {
            parent[index] = parent[parent[index]];
            index = parent[index];
        }
        return index;
    };
    members.forEach((member, index) => {
        for (const key of keys(member)) {
            const other = owners.get(key);
            if (other === undefined)
                owners.set(key, index);
            else
                parent[root(index)] = root(other);
        }
    });
    const buckets = new Map();
    members.forEach((member, index) => { const key = root(index); const group = buckets.get(key) ?? []; group.push(member); buckets.set(key, group); });
    const channels = [...buckets.values()].map((group) => {
        const originals = group.filter((entry) => entry.provider.id === 'zhi35');
        const anchor = (originals.length ? originals : group).slice().sort((a, b) => a.channel.id.localeCompare(b.channel.id))[0];
        const epg = group.map((member) => eligibleEpg(member.channel)).filter((value) => value !== null).sort()[0];
        const id = originals.length ? anchor.channel.id : epg ? `channel:${digest(`tvg-id:${epg}`)}` : anchor.channel.epgId ? `channel:${digest(`${anchor.provider.id}:${anchor.channel.id}`)}` : anchor.channel.id;
        const streams = new Map();
        for (const member of group.slice().sort((a, b) => (priority[a.provider.id] ?? 9) - (priority[b.provider.id] ?? 9))) {
            for (const stream of member.channel.streams) {
                const existing = streams.get(stream.id);
                if (existing) {
                    if (!existing.providers.includes(member.provider.title))
                        existing.providers.push(member.provider.title);
                }
                else
                    streams.set(stream.id, { ...stream, providers: [member.provider.title] });
            }
        }
        if (streams.size > 64)
            throw new Error('频道备用线路超出大小限制。');
        return {
            ...anchor.channel, id, cover: anchor.channel.cover ?? group.find((entry) => entry.channel.cover !== null)?.channel.cover ?? null,
            categories: [...new Set(group.flatMap(categories))],
            aliases: [...new Set(group.map((entry) => entry.channel.id))],
            searchNames: [...new Set(group.flatMap(({ channel }) => [channel.title, channel.name ?? '']).filter(Boolean))],
            streams: [...streams.values()].sort((a, b) => Number(a.ipv6) - Number(b.ipv6)),
        };
    });
    if (channels.length === 0 || channels.length > 5000)
        throw new Error('IPTV 聚合列表中没有有效频道或超出大小限制。');
    return { channels, revision: digest(JSON.stringify(channels.map(({ id, title, searchNames, categories: values, streams }) => [id, title, searchNames, values, streams.map((stream) => stream.id)]))) };
}
