# zhi35 IPTV

MgRead 的视频直播数据源，来源为 [zhi35/iptv](https://github.com/zhi35/iptv)。
提供频道分类、频道名/别名检索、完整分页、频道详情、直播线路选择和播放列表刷新。
频道名称、分类、台标及播放地址都读取上游列表。

## 安装

在 MgRead「数据源」中导入构建生成的
`artifacts/org.mgread.zhi35-iptv-1.0.0.mgplugin.js`。
插件 ID 为 `org.mgread.zhi35-iptv`，独立单文件运行，不需要安装 npm 依赖。
仓库中的桌面主程序也可通过开发数据源目录识别这个项目。

列表优先读取 `https://live.zhi35.com/iptv.m3u`，失败后回退到同仓库的 GitHub Raw 文件。
`iptv.m3u` 已经包含「直播中国」，因此不重复加载 `live-china.m3u`。
不混入 `radio.m3u`，也不根据 EPG 地址生成未经验证的回看节目。

部分频道只有 IPv6 地址，需要设备和网络支持 IPv6。上游的 `❌` 标记照实显示。
重复资源去重；重复的 `tvg-name` 不会把 CCTV-5 与 CCTV-5+ 合并。
带有同一 `tvg-id` 的多个地址作为线路分组展示。
频道身份不包含临时授权参数，实际播放地址保留原参数并在播放时重新获取列表。
没有 `tvg-id` 的频道依赖稳定资源地址；上游更换资源路径会产生新身份。

元数据在内存缓存五分钟；并发刷新合并。请求失败时可读取 24 小时内的已有快照，失败不会延长缓存有效期。
普通 HLS/FLV/MP4 仅登记 Runtime 代理；无扩展名入口有界识别格式后立即取消响应。
不缓存直播流，不读取用户账户或主应用数据库。

## 开发与验证

使用仓库固定 Node 26.10.0 / npm 11.19.1。PowerShell 在本目录执行：

```powershell
$nodeDirectory = (Resolve-Path '../../../packages/mg_read_node_runtime/tools/node-v26.10.0-win-x64').Path
$env:Path = "$nodeDirectory;$env:Path"
& "$nodeDirectory/node.exe" "$nodeDirectory/node_modules/npm/bin/npm-cli.js" ci --no-audit --no-fund
& "$nodeDirectory/node.exe" "$nodeDirectory/node_modules/npm/bin/npm-cli.js" run verify
& "$nodeDirectory/node.exe" "$nodeDirectory/node_modules/npm/bin/npm-cli.js" run test:live
```

`verify` 包含类型检查、离线 fixture、Runtime 返回值校验、发布包确定性/哈希/隔离加载及打包。
`test:live` 遍历全部分类和分页，从每类首/中/末频道抽样目录与线路，并单独验证封面、HLS 清单和视频分片。
报告位于忽略目录 `artifacts/live-report.json`；资源失败时保留报告并以非零状态退出。
图片与 HLS 抽样不等于 MgRead 播放器已取得首帧，也不代表全部频道可播。

2026-11-05 的检查结果：

- 离线 12 项测试、类型检查、确定性打包和独立加载通过。
- 真实列表遍历六个分类，392 条记录去重后得到 387 个频道，搜索、详情和抽样目录通过。
- 在线抽取 16 个频道：CGTN阿语、七台河新闻综合、永嘉新闻综合、龙游生活娱乐通过 HLS/分片探测；其余请求出现 403/502 等失败。
- 封面按发现根页、各分类、搜索和详情分别验证；电影频道、港澳台的抽样通过，其他表面有失效或不可达台标。
- 真实 Windows 主程序 `0.14.8+497` 识别本插件，发现、搜索、详情、目录和内容描述通过；
  台标阶段返回 502，检查在视频播放前停止。因此真实首帧/进度和 Android 播放尚未验证，整体验证为 `partial`。

## 上游许可

图标来自上游 `logo.png`，授权文本见 [LICENSE.upstream](LICENSE.upstream)，并随单文件发布包内嵌。
直播地址由上游维护，其使用说明见上游仓库；本插件不重新分发媒体内容。
