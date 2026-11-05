# zhi35 IPTV

MgRead 的视频直播数据源，来源为 [zhi35/iptv](https://github.com/zhi35/iptv)。
提供频道分类、频道名/别名检索、完整分页、频道详情、直播线路选择和播放列表刷新。
频道名称、分类及播放地址读取上游列表；台标在保持原图身份的前提下修复已核实的失效地址。

## 安装

在 MgRead「数据源」中导入构建生成的
`artifacts/org.mgread.zhi35-iptv-1.0.2.mgplugin.js`。
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
HLS 在播放前最多检查 8 KiB 清单元数据；FLV/MP4 不预读。通过检查的媒体只登记 Runtime 代理，
无扩展名入口有界识别格式后立即取消响应。
不缓存直播流，不读取用户账户或主应用数据库。

## 直播失败诊断

1.0.2 在打开播放器之前检查 HLS 请求状态和清单结构。401/403/451 作为来源访问受限上报，
其他 HTTP 错误、HTML 错误页、错误的 IPTV 总列表或连接失败作为来源媒体解析失败上报。
提示包含频道名、HTTP 状态及适用的 IPv6 说明，不包含播放 URL、授权参数或响应主体。
原始上游地址仍由 Runtime 独立执行重定向，避免复用预检得到的临时会话地址。

2026-11-05 对 Windows 上的 CCTV1 做了对照：系统具备 IPv6 地址和默认路由；
当前仓库线路经默认路由返回 502，curl 直连跟随 302 后返回 403，因此尚未取得可播放的清单。
该失败发生在得到有效视频之前，不能据此认定为播放器解码问题，也不能把关闭代理视为必然修复。
本版本明确报告线路失败，尚未恢复这条仓库线路的实际播放；没有擅自替换频道或引入其他播放源。

1.0.2 的 26 项离线测试、类型检查和确定性打包通过。快速检查和真实 Windows 主程序均在
`content.first` 阶段报告来源媒体解析失败，播放器首帧/进度仍未验证。
全分类在线抽样仍有 4 个频道通过 HLS/分片检查，其他 12 个样本失败，来源整体验证为 `partial`。

## 台标修复

发现根页、分类分页、搜索和详情共用同一套台标处理：

- `live.fanmingming.cn/com/tv/` 改为 [fanmingming/live 官方仓库](https://github.com/fanmingming/live/tree/main/tv)中同路径原图。
- 播放列表中 `ghproxy.zhi35.com`、`ghp.ci` 包装的图片解包至对应原仓库；中天娱乐的 `CTI3.pngg`
  修正为实际存在的 [CTI3.png](https://github.com/wanglindl/TVlogo/blob/main/img/CTI3.png)。
- 地方台先通过 HEAD 保留正常原址。确认 404/410 或 HTML 错误页后，在现有提供方的
  [公开台标目录](https://upload.112114.xyz/logo/)中精确查找同名文件，核实为图片后回退。
- 确认没有可恢复图片时输出空台标，由应用显示占位，频道仍可浏览和播放；连接超时等暂时故障保留原址。

图片主体仍由 Runtime 转发。HEAD 最多四路并发、同地址单飞；有效结果缓存 24 小时，缺图缓存五分钟，
连接故障缓存一分钟。目录 HTML 最多 3 MiB、单飞缓存 24 小时；不生成台标、不模糊匹配其他频道。

## 开发与验证

使用仓库固定 Node 26.10.0 / npm 11.19.1。PowerShell 在本目录执行：

```powershell
$nodeDirectory = (Resolve-Path '../../../packages/mg_read_node_runtime/tools/node-v26.10.0-win-x64').Path
$env:Path = "$nodeDirectory;$env:Path"
& "$nodeDirectory/node.exe" "$nodeDirectory/node_modules/npm/bin/npm-cli.js" ci --no-audit --no-fund
& "$nodeDirectory/node.exe" "$nodeDirectory/node_modules/npm/bin/npm-cli.js" run verify
& "$nodeDirectory/node.exe" "$nodeDirectory/node_modules/npm/bin/npm-cli.js" run test:logos
& "$nodeDirectory/node.exe" "$nodeDirectory/node_modules/npm/bin/npm-cli.js" run test:live
```

`verify` 包含类型检查、离线 fixture、Runtime 返回值校验、发布包确定性/哈希/隔离加载及打包。
`test:logos` 遍历全部分类和分页，逐个验证已登记的唯一图片 MIME/文件签名，保留各表面的声明数、缺图数及结果；
报告位于 `artifacts/live-logo-report.json`。没有提供台标的页面记录为 `notRegistered`。
`test:live` 遍历全部分类和分页，从每类首/中/末频道抽样目录与线路，并单独验证封面、HLS 清单和视频分片。
报告位于忽略目录 `artifacts/live-report.json`；资源失败时保留报告并以非零状态退出。
图片与 HLS 抽样不等于 MgRead 播放器已取得首帧，也不代表全部频道可播。

2026-11-05，插件 1.0.1 的检查结果：

- 离线 21 项测试、类型检查、确定性打包和独立加载通过。
- 真实列表遍历六个分类，392 条记录去重后得到 387 个频道，搜索、详情和抽样目录通过。
- 台标专项检查覆盖全部已登记图片：199 个频道有台标，198 张唯一图片全部通过 MIME/签名检查。
  其余 188 个频道没有可用原图，以空台标保留；这包含上游原本未提供台标的频道。
- 修复了 61 个频道使用的连接失败镜像、14 个包装/笔误地址，并从公开目录恢复 9 个原先 404 的地方台台标。
- 在线抽取 16 个频道：CGTN阿语、七台河新闻综合、永嘉新闻综合、龙游生活娱乐通过 HLS/分片探测；其余请求出现 403/502 等失败。
- 快速检查和在线检查的发现根页、各分类首批、搜索、详情台标组通过；没有台标的后续页面单独记录为未登记。
- 真实 Windows 主程序 `0.14.8+497` 识别本插件，发现、搜索、详情、目录和内容描述通过；
  台标阶段从 502 恢复为 200。当前首个 IPv6 直播样本在媒体资源阶段仍返回 502，检查尚未进入实际视频播放。
  真实首帧/进度和 Android 播放未验证，来源整体验证仍为 `partial`；台标专项通过不等于全部频道可播。

## 上游许可

图标来自上游 `logo.png`，授权文本见 [LICENSE.upstream](LICENSE.upstream)，并随单文件发布包内嵌。
直播地址由上游维护，其使用说明见上游仓库；本插件不重新分发媒体内容。
