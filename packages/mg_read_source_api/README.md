# \`@mgread/source-api\`

这是 MgRead 数据源唯一的编译期公开接口声明包。Runtime 负责实现、校验和平台差异；数据源只引用类型，
不导入 Runtime 内部模块，也不在自己的 \`src/\` 中复制 \`MgReadPluginContext\`、\`PluginWebViewPage\` 或
\`PluginWebViewApi\`。

在数据源 \`package.json\` 中加入：

\`\`\`json
{
  "devDependencies": {
    "@mgread/source-api": "file:../../../packages/mg_read_source_api"
  }
}
\`\`\`

入口中引用：

\`\`\`ts
import type { MgReadPluginContext } from '@mgread/source-api';

export async function activate(context: MgReadPluginContext): Promise<void> {
  const page = await context.webview.open({ visible: false });
  await page.cdp('Runtime.evaluate', { expression: 'document.title' });
}
\`\`\`

WebView 全部公开方法和参数以 \`PluginWebViewPage\` 为准。 \`page.cdp\` 是原始命令通道：Windows
WebView2 支持，Android 当前返回 \`unsupported\`。

来源可以把已识别的访问异常安全地交给 App：

\`\`\`ts
context.errors.raise({
  code: 'source_access_blocked',
  message: '访问异常，请稍后再试。',
  annotation: '当前 IP 可能异常，请更换 IP 后重试。',
});
\`\`\`

\`message\` 和 \`annotation\` 由 Runtime 有界校验后透传；它们只用于说明已发生的来源状态，不用于绕过验证或访问限制。
