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
WebView2 支持，Android 当前返回 \`unsupported\`；它不能用于提取或回放挑战 token，也不能绕过人工验证。
