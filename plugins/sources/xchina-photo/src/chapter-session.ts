/**
 * 章节入口返回继续访问页时，用宿主 WebView 正常建立站点会话。
 * 每源唯一页面串行复用；不读取 Cookie/令牌，不持有正文缓存，不处理登录或验证码。
 */
import type { MgReadPluginContext } from '@mgread/source-api';
import { base } from './identity.js';
let queue: Promise<unknown> = Promise.resolve();
export function resetChapterSession() { queue = Promise.resolve(); }
export function readSessionChapter(context: MgReadPluginContext, path: string): Promise<string> {
  const run = queue.then(async () => {
    const page = await context.webview.open({ visible: false, timeoutMs: 15000 });
    await page.navigate(base + path, { timeoutMs: 20000 });
    const ready = await page.executeJavaScript(`return (async()=>{
      for(let i=0;i<20;i++){
        if(document.querySelector('article.reader .font-serif')?.textContent.trim())return true;
        if(document.querySelector('iframe[src*="captcha"],input[type="password"]'))return false;
        await new Promise(r=>setTimeout(r,250));
      }return false;
    })()`, { timeoutMs: 7000 });
    if (ready !== true) {
      await page.show({ timeoutMs: 5000 });
      context.errors.raise({code:'source_access_blocked',message:'小黄书章节需要在来源页面完成访问验证后重试。'});
    }
    return page.getHtml({ timeoutMs: 10000 });
  });
  queue = run.catch(() => undefined); return run;
}
