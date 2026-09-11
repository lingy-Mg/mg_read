# 批量检测与整顿

## 建立可复核清单

用于同类来源健康检查、全源回归、批量修复和 descriptor 简介整顿。通过 Git 跟踪的来源目录与 Runtime 当前
项目读取/校验入口建立清单，记录目录、pluginId、版本、contentKinds、artifact 模式、origin、测试命令和初始
状态。按元数据、当前站点能力和解析入口界定分组，不能只凭 `contentKind`、目录名或展示名推断类别。

先冻结基线与文件归属。每个来源只记录首个失败阶段和稳定错误码；批量任务不能在首错后停止，也不能先统一
改模板再判断各来源是否同因。

## 分层执行

1. 元数据与构建：descriptor、入口、公开导出、固定 Node/npm、build、typecheck、离线测试、artifact。
2. 内容链路：根发现、有限 target、搜索、详情、完整目录、按 `contentKind` 选择的有界内容样本。
3. 资源链路：封面、漫画页图、音频、视频/HLS 分组独立探测；一个健康资源组不能代表其他组通过。
4. 宿主链路：Node CLI 后再跑正式 Windows App CLI；WebView/人工交互来源单列能力边界。

具体样本和通过标准读取 [content-validation-matrix.md](content-validation-matrix.md)，命令和报告语义读取
[source-testing-workflow.md](source-testing-workflow.md)。批量运行输出结构化报告，至少包含总数、通过/失败/跳过、
每来源阶段、contentKind、样本数、各资源组状态、耗时和未验证平台。

## 简介整顿

把两种简介分开：

- `package.json.mgread.description` 描述来源覆盖的真实内容和能力；
- discover/search/detail 的作品简介只能来自来源内容，不能拿站点说明或 descriptor 填充。

通过 Runtime 公开项目读取器校验所有 descriptor 的非空值、当前长度限制和预期总数；不要用手写 JSON 读取器
替代公开校验。简介应简洁、事实化，不写暂时可达性、未经证实的分类或营销语。元数据改动仍按来源版本和
artifact 规则处理。

## 判定与收尾

结果分为：稳定通过、单次有界复跑后判定的瞬时波动、可复现代码缺陷、外部站点阻塞、环境缺失、平台未验证。
批量修复只合并证实为同因的最小改动；共享 testkit、公开契约或跨来源逻辑变化时，运行 testkit 自测、所有
受影响来源和全源模式。

提交前核对清单总数、报告总数和 staged 文件列表一致。最终逐项列出仍失败来源和原因，不能把“批处理完成”
写成“所有来源通过”。
