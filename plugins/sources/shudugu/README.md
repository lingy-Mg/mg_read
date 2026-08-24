# 速读谷 MgRead 书源

这是按 MgRead Plugin API v1 实现的标准 Node.js 24 小说书源，覆盖速读谷的分类发现、搜索、详情、目录和正文。
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
这不替代 Android 的正式 `.mgplugin` 验收。分类和搜索 HTML 使用插件私有的 10 分钟缓存，详情和目录使用 1 小时缓存，首页“阅读排行”热门搜索使用 24 小时缓存并在请求时惰性刷新；正文不落盘。
