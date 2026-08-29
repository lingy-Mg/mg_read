# 速读谷 MgRead 数据源插件

这是按 MgRead Plugin API v1 实现的标准 Node.js 24 小说数据源插件，覆盖速读谷的分类发现、搜索、详情、目录和正文。
网站 URL 只留在插件内部；跨插件边界传递的是 `novel:<id>` 和不透明的 `chapter:<id>`。

```powershell
$env:PATH = "$PWD\..\..\..\packages\mg_read_runtime\tools\node-v24.16.0-win-x64;$env:PATH"
npm.cmd ci
npm.cmd test
npm.cmd run verify
npm.cmd run test:live
```

`npm test` 是不依赖网站的离线回归，`npm run verify` 是交付前门槛；修改来源规则后必须再执行
`npm run test:live`。Windows Debug 可以直接加载构建后的工作区 `dist/`，不需要先打包或安装；
这不替代 Android 的正式插件 artifact 验收。发现分类列表在一小时内直接命中，超过一小时先显示旧的
书名/封面投影并在后台单次刷新；搜索维持 10 分钟刷新窗。详情和目录严格限制为一小时内，过期刷新失败
会返回错误而不是悄悄展示旧数据。发现中已解析的详情页同时保存目录，因此打开详情和加入书架都不会再次
请求或解析它。首页“阅读排行”热门搜索使用 24 小时缓存；正文不落盘。

缓存实现来自仓库本地 `@mgread/plugin-cache`，不是 npm 发布包。它同时保存 HTML 与经过校验的详情/目录
投影；列表补详情时优先返回任意已有投影并在后台单飞刷新，用户主动打开详情或目录仍要求一小时内的新数据。构建时自动同步到本数据源插件的
`packages/`；默认 single-file 打包器会把实际引用的纯 JavaScript 合并进
`artifacts/org.mgread.shudugu-0.1.4.mgplugin.js`，并把 `assets/icon.png` 内嵌进规范信封。artifact
不携带 lock、源码、`node_modules` 或 sidecar，安装时无需安装脚本或网络下载。
