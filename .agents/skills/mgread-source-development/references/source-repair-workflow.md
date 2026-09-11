# 失效来源修复

## 先定位首个断点

先运行目标来源的声明检查、离线测试、必要的 live smoke 和 Node 单源 CLI，沿
`discover -> search -> detail -> catalog -> content -> resource` 记录首个失败阶段。修改前先分类：

1. 环境/构建：退出码 `127`、缺少 `tsc`、npm CLI、依赖或 PATH。核对固定 Node/npm、lock 和本地依赖；
   不能通过改解析器掩盖。
2. 站点/传输：DNS/TLS、超时、重定向、挑战页、`403/429`、上游资源 `404`。记录最终地址、状态、响应大小
   和耗时；这类证据本身不证明选择器有错。
3. 解析/契约：成功响应中的入口、选择器、分页、稳定 ID、分组或返回形状不符。用当前网页与最小 fixture
   同时确认后修。
4. 资源代理：内容链路成功但封面、漫画页图或媒体失败。检查登记的上游 URL、kind、headers 和 Runtime
   数据面；不要把 loopback proxy URL 当作上游地址。

一次 live 失败后保留首次报告，只允许有界单源复跑一次判断波动。站点确实很慢时可依据实测延迟设置有上限的
超时，但不能放宽结构断言，也不能把延长等待当成修复。

## 用当前事实修复

涉及路由、DOM、脚本渲染、选择器或分页时读取
[real-page-browser-probing.md](real-page-browser-probing.md)。浏览器不可达时，CLI 只能证明传输状态；保留已有
fixture 并将线上结构标为待复核，不猜入口或替换域名。

- live 搜索从当前发现结果派生有界查询，并用稳定 ID 找回同一条目后继续详情与目录；不要用固定 `test`、
  硬编码内容 ID、标题、条目数或章节数制造通过。
- 搜索和发现若共享列表页，复用同一解析器，并按真实路由实现分页和有界 cursor。
- 图片候选只取页面真实字段，完成 URL 归一化、origin allowlist、去重、顺序和 Referer/Accept 登记。
- 对确认的访问限制使用当前公开错误契约；`403/429`、挑战页、资源 `404`、瞬时超时和解析失败分别报告。
  没有新证据时不得靠猜文件名、域名或 headers 把外部失败伪装成修复。

## 固化与验证

fixture 固定本次确认的入口、请求参数、分页、解析规则、资源描述和错误分支；live smoke 证明当前站点仍能完成
同一公开链路。按 [content-validation-matrix.md](content-validation-matrix.md)验证受影响的内容与资源类型，
再按 [source-testing-workflow.md](source-testing-workflow.md)完成来源自身、Node CLI 和 Windows App CLI 分层验证。

若修复暴露 testkit 缺少公开宿主行为，只补齐最小通用模拟并运行 testkit 自测、受影响来源和全源模式；
不得给单个插件增加绕过契约的专用成功路径。
