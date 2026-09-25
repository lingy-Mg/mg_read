# 快速检查与实际检查

## 先固定名词

| 名称 | 唯一入口 | 能证明什么 | 不能代替什么 |
| --- | --- | --- | --- |
| 快速检查 | 仓库固定 Node 直接运行 `packages/mg_read_source_testkit/bin/mgread-source-test.mjs` | 来源 build、公开导出、临时宿主与有界 live 内容/资源链路 | 真实 App 启动、已安装/已启用插件、Runtime Facade 校验和主程序资源代理 |
| 实际检查 | 当前真实 MgRead 主程序 EXE 的 `--source-check` / `--source-check-all` | 生产 `SourceContentGateway -> Runtime Facade -> Runtime -> 已启用插件` 链路；视频还验证生产 MediaKit 首帧与进度推进 | 人工交互、Android 真机播放或长时稳定性 |

不要再把 Node CLI 称为“正式验收”，也不要用 `flutter test`、`integration_test`、Runtime 私有端口、
mock 或单独 build 替代主程序 EXE CLI。两层都可访问真站，“快速”指它绕过 Flutter/主程序宿主，
不表示只做静态检查。

## 全链路通过标准

快速检查和实际检查都按同一业务矩阵记录证据，只是宿主不同：

1. `discover.root`：根发现文档可解码，组件、target、collection 和 continuation 合法。
2. `discover.target.*`：有界遍历根页暴露的 tab/category target，不得在找到第一个非空列表后就假定其他子列表正常。
3. `discover.append.*`：对响应真实暴露 continuation 的代表列表至少验证一次追加，核对 target/cursor/collectionId
   和稳定 ID；没有下一页链接/cursor 的落地页不得因条目数达到 pageSize 而合成追加请求。
4. `search`：从当前发现标题生成少量有界查询，搜索结果必须找回同一稳定 ID，不能无条件取首项。
5. `detail`：使用上述稳定 ID，校验标题、`contentKind`、访问性和关键元数据。
6. `chapters`：读取完整目录，校验非空 ID、唯一性、顺序、锁定语义；音频/视频还要校验 `groups[]` 与扁平 items 对应。
7. `content.first|middle|last`：从可读项抽取去重的首/中/末样本，核对 chapterId、`contentKind` 和真实正文/页图/媒体描述。
8. 资源组：封面、漫画页图、音频、视频/HLS 分组验证，只读格式识别所需前缀并立即取消。

封面不是一个聚合“有一张能打开”的检查。至少分开记录 `discover.root`、每个已抽样
`discover.target`、`search` 和 `detail` 的封面候选数、已登记数、探测数和结果。某个发现子列表封面全部失效时，
不能因详情封面可达而通过。

严格通过需要内容链路和全部适用资源子组均为 `passed`。适用子组为 `notRegistered`、`notTested`、
`unverified` 或当前工具只做了聚合探测时，整个来源最多只能记为 `partial`。详细类型标准读取
[content-validation-matrix.md](content-validation-matrix.md)。

## 快速检查：直接 Node

从仓库根目录使用当前平台对应的仓库固定 Node，不回退系统 Node。Windows 单源：

```text
packages\mg_read_node_runtime\tools\node-v26.10.0-win-x64\node.exe --use-env-proxy packages\mg_read_source_testkit\bin\mgread-source-test.mjs --source aisishuwu --report artifacts\source-tests\quick-aisishuwu.json
```

全源：

```text
packages\mg_read_node_runtime\tools\node-v26.10.0-win-x64\node.exe --use-env-proxy packages\mg_read_source_testkit\bin\mgread-source-test.mjs --all --report artifacts\source-tests\quick-all.json
```

`--source` 接受来源目录、package 名或 pluginId。默认先执行来源声明的 build，然后从 `dist` 装载。
`--skip-build` 只用于已证明 dist 与源码一致的重复诊断。`test/acceptance.json.searchQuery` 只是无法从当前发现/建议
派生查询时的后备，不得固定 `contentId` 绕过发现与搜索。

CLI 退出码：`0` 所有来源严格通过、`1` 已完成但存在 `failed/partial`、`2` 参数或启动失败。全源必须
遇错继续到最后一个来源。源码项目缺 `node_modules` 导致的 build `127` 先按 lock 恢复开发依赖，
不记为来源代码失败。安装或同步发布产物时不得恢复依赖；两种 artifact 都运行单个已打包 JS。

testkit 自身变化时运行固定 Node 的离线直接测试：

```text
packages\mg_read_node_runtime\tools\node-v26.10.0-win-x64\node.exe --test packages\mg_read_source_testkit\test\*.test.mjs
```

## 实际检查：真实主程序 EXE CLI

使用用户指定或当前要交付的真实 `mg_read.exe`；报告必须记录 EXE 绝对路径、产品版本与报告时间。
如任务包含 App、Runtime、Facade 或发布产物改动，先生成与交付一致的 Windows Release；否则不为了“测试”偷换成
临时 Debug 宿主。

```text
build\windows\x64\runner\Release\mg_read.exe --source-check=org.mgread.aisishuwu --source-check-report=artifacts\source-tests\actual-aisishuwu.json
build\windows\x64\runner\Release\mg_read.exe --source-check-all --source-check-report=artifacts\source-tests\actual-all.json
```

Windows Release 是 GUI 子系统进程；自动化用 `Start-Process -WindowStyle Hidden -Wait -PassThru` 等待真实退出，
再读取 JSON 报告和 `ExitCode`。单源修复先跑单源；全源审计、testkit/Runtime/宿主公共逻辑变化再跑全源。

当前 App CLI 退出码：`0` 引擎内阶段通过、`1` 完成但有失败/取消、`2` 内部或报告错误、`3` 需要交互、
`4` 参数错误或平台不支持。读取报告后还要按本文矩阵重新归一化；如 EXE 报告仍只有聚合
`resource.cover/resource.content`，没有发现表面和类型子组，调用方必须降级为 `partial` 并列出缺失项；
不得因 EXE 返回 `0` 就宣称全链路通过。

视频来源还必须有 `playback.video` 阶段。CLI 在真实 Flutter 视频表面上用生产 Runtime URL、headers、视频代理和
MediaKit 静音打开样本；只有取得首帧、进入 playing 且 position 前进才通过。报告按样本保留线路序号、解析/播放
阶段、`video_backend_initialization_failed`、`video_backend_open_failed`、`video_stream_error`、`video_runtime_resource_unavailable`、
`video_proxy_unavailable` 或 `video_first_frame_timeout`，以及 buffering/position/duration/bufferedPosition。
缺少该阶段、探针不可用或样本因上限未测试时，视频来源不得通过。

## 漫画、音频和视频的额外检查

- 漫画：除封面外，首/中/末可读章节都要有 pages；按不同章节和页位分层抽样页图，校验 page id/index、
  登记描述、MIME、文件签名与非空前缀。
- 音频/音乐：校验曲目顺序、锁定项、groups 对应、`media.resourceType=audio`、headers、Range、媒体 MIME/签名；
  每个实际 group/线路至少探测一个可读样本；有时效签名时重新 `getContent` 验证刷新语义，稳定 ID 不得包含
  `token/sign/livekey` 等临时参数。直播首块可能从帧中间开始，格式识别可在有界前缀内寻找连续有效帧，不能只认
  第一个字节。封面仍是独立子组。
- 视频：校验扁平 episodes 与 `groups[]`、稳定 `groupId + episodeId`、`media.resourceType=video|hls`。直链检查有界 Range、
  MIME 与容器签名；每个实际 group/线路至少取一个样本，不能由健康线路掩盖另一条 404/错误线路。HLS 检查
  `#EXTM3U`、主/媒体 playlist、基址解析，并有界探测一个 variant、key 或 segment；随后由实际检查验证真实解复用、
  解码、视频表面首帧和播放时钟推进。

上述额外检查不得被“详情可读”“有 media URL”或“封面可达”替代。

## 判读与停止条件

先看 `status/totals`，再按 `pluginId -> stages -> resource groups/surfaces` 定位首错：

- 快速/实际同阶段失败：优先检查来源解析、网络或公开返回值。
- 快速过、实际为 `invalid_format`：检查 Runtime/Facade 公开校验。
- 快速过、实际在资源失败：检查 proxy 描述、headers 与 Runtime 数据面。
- Node 临时宿主无法执行任意脚本、CDP、动态等待或可见交互时，来源结果记为 `partial`，并在
  `limitation.kind=testkitWebViewCapability` 下保留能力、阶段和稳定错误码；不得记为普通来源代码失败。
  EXE 的 `plugin_damaged/source_not_found/source_list_empty` 仍分别记录为安装/启用状态，不能与 Node 能力边界合并。
- WebView/人工交互受限：记录 `source_webview_interaction_required`，不归为普通解析缺陷；浏览器页面可访问也不能
  替代 App 可见 WebView 交互。
- 单次 live 失败：保留首次报告，只有界复跑一次，不无限重试到绿。

全源必须遇错继续、保留每源首错和中间报告。最终将快速检查、实际检查、各封面表面、正文、漫画页图、
音频、视频/HLS、Windows/Android 实机、外部阻塞和未执行项分开报告。
