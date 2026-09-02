import type {
  MgReadPluginContext,
  PluginJsonObject,
  PluginWebViewPage,
} from '@mgread/source-api';

export async function exercisePublicSourceApi(
  context: MgReadPluginContext,
): Promise<void> {
  const page: PluginWebViewPage = await context.webview.open({ visible: false });
  await page.navigate('https://example.com');
  await page.executeJavaScript<string>('document.title');
  await page.cdp<PluginJsonObject>('Runtime.evaluate', {
    expression: 'document.title',
  });
  await page.click({ x: 1, y: 1 });
  await page.inputText('example');
  await page.key({ key: 'Enter', modifiers: ['control'] });
  await page.waitForText({ text: 'Example', timeoutMs: 1_000 });
  await page.getHtml();
  await page.getUrl();
  await page.show();
  await page.hide();
  await page.close();
}
