import assert from 'node:assert/strict';
import test from 'node:test';

import * as plugin from '../dist/index.mjs';

test('home discovery combines real video topics with rich host layouts', async () => {
  const requests = [];
  await plugin.activate(createContext({
    onTopic(payload) {
      requests.push(payload);
      return {
        items: Array.from({ length: 10 }, (_, index) => ({
          vodId: payload.vodTopicId * 100 + index,
          vodName: `专题 ${payload.vodTopicId} 视频 ${index + 1}`,
          coverImg: `https://img.example/${payload.vodTopicId}-${index}.jpg`,
          remark: index === 0 ? '更新至 12 集' : '已完结',
          flags: '2026 / 视频 / 大陆',
        })),
        totalPages: 1,
      };
    },
  }));

  const home = await plugin.discover({
    target: null,
    cursor: null,
    collectionId: null,
    pageSize: 20,
  });

  assert.equal(home.kind, 'document');
  assert.deepEqual(
    home.document.components.map((component) => component.id),
    [
      'juzi-home-short-section',
      'juzi-home-navigation',
      'juzi-home-movie-section',
      'juzi-home-series-section',
    ],
  );
  assert.deepEqual(
    home.document.components
      .filter((component) => component.type === 'section')
      .map((section) => section.children[0].layout),
    ['carousel', 'coverGrid', 'shelf'],
  );

  const shortItems = home.document.components[0].children[0].items;
  assert.equal(shortItems.length, 8);
  assert.equal(shortItems[0].content.contentKind, 'video');
  assert.equal(shortItems[0].content.coverOrientation, 'portrait');
  assert.deepEqual(shortItems[0].metric, { label: '更新', value: '更新至 12 集' });

  const navigation = home.document.components[1];
  assert.equal(navigation.layout, 'vertical');
  const categories = navigation.children[0].children[0];
  assert.equal(categories.layout, 'grid');
  assert.deepEqual(
    categories.categories.map((category) => category.target),
    [
      'channel:short',
      'channel:netflix',
      'channel:movie',
      'channel:series',
      'channel:anime',
      'channel:variety',
      'channel:korea',
      'channel:sports',
    ],
  );
  assert.deepEqual(
    categories.categories.map((category) => category.icon),
    ['video', 'globe', 'video', 'ongoing', 'manga', 'star', 'globe', 'sports'],
  );
  assert.deepEqual(
    requests.map(({ vodTopicId, pageIndex, pageSize }) =>
      ({ vodTopicId, pageIndex, pageSize })),
    [
      { vodTopicId: 47, pageIndex: 1, pageSize: 8 },
      { vodTopicId: 67, pageIndex: 1, pageSize: 8 },
      { vodTopicId: 68, pageIndex: 1, pageSize: 8 },
    ],
  );
  await assert.rejects(
    plugin.discover({
      target: null,
      cursor: 'unexpected',
      collectionId: null,
      pageSize: 20,
    }),
    /Home discovery continuation is invalid/u,
  );
});

test('Juzi TV source signs requests, keeps ep IDs and proxies HLS', async () => {
  const proxied = [];
  await plugin.activate(createContext({ proxied }));

  const listing = await plugin.discover({
    target: 'channel:short',
    cursor: null,
    collectionId: null,
    pageSize: 5,
  });
  const item = listing.document.components[0].children[0].items[0].content;
  assert.equal(item.id, 'vod:10');

  const chapters = await plugin.getChapters({ id: item.id });
  assert.equal(chapters.items[0].id, 'vod:10:99');
  assert.equal(chapters.groups[1].episodes[0].id, 'vod:10:100');
  assert.equal(chapters.groups[1].episodes[0].order, 0);

  const content = await plugin.getContent({
    id: item.id,
    chapterId: chapters.items[0].id,
  });
  assert.equal(content.media.resourceType, 'hls');
  assert.equal(proxied.at(-1).kind, 'hls');
  assert.equal(content.media.mimeType, 'application/vnd.apple.mpegurl');
  assert.equal(proxied.at(-1).url, 'https://media.example/1.m3u8');
});

function createContext({ onTopic, proxied = [] } = {}) {
  return {
    log: { info() {}, warn() {} },
    resource: {
      proxy(value) {
        proxied.push(value);
        return `http://127.0.0.1/r/${proxied.length}`;
      },
    },
    http: {
      async fetch(input, init = {}) {
        const url = String(input);
        if (url.includes('getVodList')) {
          const payload = JSON.parse(init.body);
          return Response.json({
            result: true,
            data: onTopic?.(payload) ?? {
              items: [{
                vodId: 10,
                vodName: '测试视频',
                coverImg: 'https://img.example/c.jpg',
              }],
              totalPages: 1,
            },
          });
        }
        if (url.includes('vodInfo/index')) {
          return Response.json({
            result: true,
            data: {
              vodId: 10,
              vodName: '测试视频',
              playerList: [{
                playerName: '线路',
                epList: [{ epId: 99, epName: '第一集' }],
              }, {
                playerName: '备用线路',
                epList: [{ epId: 100, epName: '第一集' }],
              }],
            },
          });
        }
        if (url.includes('epDetail')) {
          return Response.json({
            result: true,
            data: [{ vodResolution: 3, canPlay: true }],
          });
        }
        if (url.includes('playUrl')) {
          return Response.json({
            result: true,
            data: { playUrl: 'https://media.example/1.m3u8' },
          });
        }
        return Response.json({ result: true, data: { items: [] } });
      },
    },
  };
}
