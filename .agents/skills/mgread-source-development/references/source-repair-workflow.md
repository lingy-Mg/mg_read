# 真实数据源批量修复

## 适用范围与清单

本参考用于修复已有真实来源、批量检查同类来源、整顿来源简介，或补齐封面、正文图片和媒体资源链路。
先建立明确目标清单：结合 `package.json.mgread`、公开 origin、当前站点内容和解析入口判断范围，不能仅凭
`contentKind`、目录名或展示名推断内容类别。记录目标路径和其中已有改动，只拥有本次明确修改的文件。

把两种“简介”分开：

- 插件 descriptor 简介描述来源覆盖的真实内容和能力，来自 `package.json.mgread.description`；
- 作品简介属于 discover/search/detail 返回值，只能来自来源内容，不能拿站点说明或插件简介填充。

批量整顿 descriptor 时，通过 Runtime 当前项目读取/校验入口枚举所有已跟踪来源，核对预期总数、非空值和
当前长度限制；不要用手写 JSON 读取器代替公开校验，也不要把暂时可达性、未经证实的分类或营销语写进简介。

## 先分类失败

修改代码前，用仓库固定 Node 对目标来源分别运行声明的 typecheck、离线测试、`verify`、必要的 live smoke 和
Node source-test CLI，记录首个失败阶段，再按下列类别处理：

1. 环境或构建：退出码 `127`、缺少 `tsc`、npm CLI、依赖或 PATH。先核对固定 Node/npm、lock 和本地依赖；
   这类失败不能证明解析器有错，也不能通过改来源代码掩盖。
2. 站点或传输：DNS/TLS、超时、重定向、挑战页、HTTP `403/429`、上游资源 `404`。记录最终地址、状态、
   响应大小和耗时；只有当前页面证据改变了解析事实时才改选择器或 URL。
3. 解析或契约：成功响应中入口、选择器、分页、稳定 ID、分组或返回形状与当前站点不符。用真实页面和最小
   fixture 同时确认后修复。
4. 资源代理：内容链路成功但 `resource.*` 失败。检查来源登记的上游 URL、kind、Referer/Accept 等 headers
   和 Runtime 数据面；不要把 loopback proxy URL 当成上游地址诊断。

一次 live 失败后保留首次报告，只允许有界单源复跑一次来区分瞬时波动。若站点确实很慢，可依据实测延迟设置
有明确上限的超时，但不能放宽结构断言或把延长等待当成解析修复。

## 按真实链路修复

需要确认路由、DOM、脚本渲染结果、选择器或分页时，同时读取
[real-page-browser-probing.md](real-page-browser-probing.md)。内置浏览器无法访问时，CLI 只能证明传输状态，
不能据此猜页面结构；保留已有 fixture 并把线上复核列为未完成项。

沿 `discover -> search -> detail -> catalog -> content -> resource` 定位首个断点。live 测试从当前发现结果提取
搜索词，并用稳定 ID 找回同一条目后继续链路；不要使用固定的 `test`、硬编码内容 ID、标题、条目数或章节数
制造脆弱通过。搜索与发现若共享列表页面，应复用同一解析器，并按真实路由实现分页和有界 cursor。

图片与媒体修复至少核对：

- 页面真实候选字段，例如 `currentSrc`、`src`、`data-src`、`data-original` 或站点 manifest；
- 相对地址归一化、协议和来源 allowlist、去重与顺序；
- `ctx.resource.proxy` 登记的资源 kind 和来源要求的 Referer/Accept；
- 上游响应状态、MIME、非空主体，以及图片或媒体格式是否与声明一致。

只有页面必须渲染或执行脚本才能取得资源时才使用最小 WebView 操作。若修复暴露出 testkit 缺少某个公开宿主
行为，补齐该行为的最小模拟并运行 testkit 自测和所有受影响来源；不得给单个插件增加绕过契约的专用成功路径。

对确认的访问限制，按当前公开错误契约把 `403/429` 等映射为稳定的访问受阻错误。上游对象不存在、挑战页、
临时超时和解析失败必须分别报告；没有新的线上证据时，不得靠替换文件名、域名或 Referer 把资源 `404`
伪装成已修复。

## 回归与收尾

fixture 测试应固定本次修复的真实入口、请求参数、分页、解析规则、资源描述和错误分支；live smoke 证明当前站点
仍可完成同一公开链路。来源自身的 typecheck、离线测试、`verify` 和 artifact 构建都通过后，再按
[source-testing-workflow.md](source-testing-workflow.md)运行 Node 单源和 Windows 正式 App CLI。

测试库、公共契约或跨来源逻辑有修改时，追加 testkit 自测、所有受影响来源和全源模式。最终把结果分为稳定
通过、复跑后判定的瞬时波动、仍存在的外部阻塞、平台未验证四类；不能用离线通过替代 live，也不能用 Node
通过替代 Windows App CLI。提交前只暂存本次清单中的文件并复核 staged 文件列表。
