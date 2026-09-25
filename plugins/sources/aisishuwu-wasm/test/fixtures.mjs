/** Neutral synthetic HTML matching Alice's selectors; no downloaded books are persisted. */
export const id = 'org.mgread.aisishuwu.wasm';
export const chapterId = (n) => `chapter:${Buffer.from(`/book/1/${n}.html`).toString('base64url')}`;
export function detailHtml(n = '1') {
  return `<h1 class="novel_title">测试图书${n}</h1><div class="pic"><img src="https://img.321cdn.com/cover.jpg"></div>
    <div class="novel_info"><p>作者：<a href="/search.html?f=author">测试作者</a></p><p>字数：1.2万 章节：3</p>
    <p>状态：连载</p><p>热度：3万 收藏：20</p><a href="/lists/71.html">科幻</a></div><div class="jianjie"><p>测试简介</p></div>`;
}
export const listHtml = `${Array.from({length:50},(_,n)=>`<a href="/lists/${n+1}.html">分类${n+1}</a>`).join('')}<div class="list-group-item"><a href="/novel/1.html">测试图书1</a></div>
  <div class="list-group-item"><a href="/novel/2.html">测试图书2</a></div><a rel="next" href="?page=2">下一页</a>`;
export const catalogHtml = (second = false) => `<div class="book_newchap"><div class="tit">全3章</div></div><div class="mulu_list">${
  (second ? [2, 3] : [1, 2]).map((n) => `<a href="/book/1/${n}.html">第${n}章</a>`).join('')}</div>${
  second ? '' : '<a rel="next" href="?page=2">下一页</a>'}`;
export function fixtureFetch(input) {
  const url = new URL(input);
  let body;
  if (url.pathname.startsWith('/novel/')) body = detailHtml(url.pathname.match(/\d+/)[0]);
  else if (url.pathname.startsWith('/other/chapters/')) body = catalogHtml(url.searchParams.get('page') === '2');
  else if (url.pathname.startsWith('/book/')) body = '<h1>测试章节</h1><div class="read-content"><p>第一段。</p><script>广告脚本</script><p>第二段。</p></div>';
  else body = listHtml;
  return Promise.resolve(new Response(body, { headers: { 'content-type': 'text/html' } }));
}
