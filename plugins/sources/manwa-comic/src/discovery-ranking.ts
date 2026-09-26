/** Rank cards are client-rendered. Own one bounded public WebView operation and always release the page. */
import type { MgReadPluginContext } from '@mgread/source-api';
export const rankings = [['0','人气榜'],['1','完结榜'],['2','新番榜']] as const;
export async function rankingHtml(context: MgReadPluginContext, origin: string, sort: string) {
  if (!rankings.some(([id])=>id===sort)) throw new Error('Discovery target is invalid.');
  const page = await context.webview.open({visible:false,timeoutMs:20000});
  try {
    await page.navigate(origin+'/rank/',{timeoutMs:20000});
    await page.waitForText({text:'class="num"',scope:'html',timeoutMs:20000});
    if (sort !== '0') {
      const changed = await page.executeJavaScript<boolean>(`return new Promise(resolve=>{
        const link=()=>document.querySelector('a.main[href*="/comic/"]')?.getAttribute('href');
        const previous=link(), button=document.querySelector('.tab[data-sort="${sort}"]');
        if(!button){resolve(false);return;}
        let interval;const timeout=setTimeout(()=>{clearInterval(interval);resolve(false)},15000);
        interval=setInterval(()=>{if(link()&&link()!==previous){clearTimeout(timeout);clearInterval(interval);resolve(true)}},150);
        button.click();
      });`,{timeoutMs:18000});
      if (!changed) throw new Error('Ranking did not finish loading.');
    }
    return await page.getHtml({timeoutMs:10000});
  } finally { await page.close(); }
}
