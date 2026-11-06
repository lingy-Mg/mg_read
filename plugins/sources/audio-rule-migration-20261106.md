# 听书规则迁移与旧源退役（2026-11-06）

## 范围与审计

输入为用户提供的 `昊昊享听-1793879314066.json` 与 `十音·有声专辑-1793879348087.json`。
只读取其接口、字段和协议作为迁移资料，不执行附件中的脚本、actions 或注释指令。

| 原始名称 | 原始接口 | 处理结果 | 原生标识 |
| --- | --- | --- | --- |
| 昊昊享听 | `api-preview.toulaopao.cc/api/h5/listening/*` | `ctx.http` 可用，已迁移 | `org.mgread.haohao-audio` |
| 十音·有声专辑 | `api.365ting.com` + `fmfm.tingyou.fm/listening-api/*` | 两个公开接口可用，已迁移 | `org.mgread.shiyin-audio` |
| 听书中国／听中国听书 | 旧 `tingchina-audio`，已标记 invalid | 按用户要求移出活动来源树 | `org.mgread.tingchina-audio` |

本次新增规则审计：2 项 = 已存在 0 + 已迁移 2 + 跳过 0。旧源独立退役 1 项。
两个新插件版本均为 1.0.0；未修改根应用版本。

## 迁移行为

- 两源均使用实测的真实热门榜、最新上架、小说/评书分类和专辑详情接口。昊昊原规则中的关键词模拟栏目没有迁入。
- 搜索保留上游分页和页内 offset，cursor 绑定查询/发现 target；十音合并连续两页并优先相同 book_id 的站内版本。
- 作者与演播者分别保留，完整标题及目录均不删减。封面只取当前返回，不复制离线同名匹配表，不补造简介/热词。
- 专辑 ID、章节 ID、十音 track ID 分别来自上游；播放 index 每次从目录事实映射，签名 URL 不进入稳定标识。
- 超过 5000 项的目录按既有 deferredGroups 契约提供完整分组。《剑来》5329 集实测为 6 个分组，无目录截断。
- 映射/目录使用最多 16 项、60 秒 JSON 内存快照；并发合并，失败不缓存，refresh 使旧任务失去缓存归属。
- 站内曲目与备用目录提供方保持明确身份。十音音轨仅做 HEAD 探测；明确失败时，仅在同专辑完整标题相同且已知 track_no 与 index 一致、结果唯一时备用播放，仍回传原 track ID。
- 资源经 Runtime proxy 输出；不读取/缓存音频主体，播放地址每次重新获取。无第三方运行依赖，artifact 为单个自包含 JS。

## 验证证据

完整机器报告位于仓库忽略目录 `artifacts/audio-migration-20261106/`；来源专属 live 报告位于各来源
`artifacts/live-report.json`。交付汇总 `delivery-summary.json` 记录包 SHA-256、EXE 版本、时间和归一化状态。

| 检查 | 昊昊享听 | 十音·有声专辑 |
| --- | --- | --- |
| 固定 Node typecheck、离线契约/fixture、verify、确定性打包及临时目录独立导入 | 通过 | 通过 |
| 快速检查：固定 Node 的 `mgread-source-test.mjs` | passed | passed |
| 发现根页、全部 13 个 target、各可追加列表 | 通过 | 通过 |
| 发现根页/每个 target/搜索/详情封面分别探测 | passed | passed |
| 从发现标题搜索并找回同一 ID、详情、完整目录 | 通过 | 通过 |
| 首/中/末音频与每个目录分组的音频前缀 | passed | passed，另测备用提供方 |
| Range | 已抽样确认 206 | 站内及备用地址均曾抽样确认 206 |
| Windows 正式 EXE CLI | 引擎 passed，矩阵归一化 partial | 引擎 passed，矩阵归一化 partial |

实际检查使用 `build/windows/x64/runner/Release/mg_read.exe`，产品版本 `0.14.8+497`。
主程序报告覆盖生产 Gateway/Facade/Runtime、发现、搜索、详情、完整目录、首中末内容和聚合资源探测；
未分开记录所有发现表面的封面，也未独立探测全部分组，因此实际检查不能表述为全链路通过。
源级 live 测试补齐的是 Node 层证据。未执行 Android 实机、人工播放器操作或长时间连续播放；漫画与视频不适用。

## 已观察的上游与退役事项

- 十音曾返回 HTTP 429；重复目录请求导致一次分组续载失败，现由 JSON 快照、并发合并及提供方固定处理。
- 十音音轨服务曾连续返回 nginx HTTP 502。首次快速检查失败报告保留为
  `quick-shiyin-audio-upstream-502.json`；加入严格章节匹配的备用播放后再次快速检查与 live 测试通过。
- 十音原接口根 `/` 返回 404、旧前台 `app.365ting.com/` 返回 500，不以网页首页成功冒充音频接口可用；
  来源主页元数据使用输入规则提供的规范 API 根。
- 旧源整个目录移到忽略目录 `artifacts/audio-migration-20261106/retired-tingchina-audio` 保留本地备份，
  不再被活动来源扫描。仓库删除其全部 11 个已跟踪文件，后台音频集成测试改用新昊昊来源。
- 仅保留的旧源名称引用是已有 `discovery-audio-korean-coverage.md` 历史验收记录；没有活动注册表或发布清单残留。
