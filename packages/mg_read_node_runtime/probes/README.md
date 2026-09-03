# Runtime probes

本目录存放只能由真实依赖、平台或最终 bundle 证明的 Runtime 探针。当前固定版本、平台选择和待验证项见
[`docs/runtime-version-matrix.md`](../docs/runtime-version-matrix.md)。

Probe 必须断言可观察结果，不复制 Runtime 契约或实现说明。Windows、Android 和 macOS 分别记录；一个平台
的通过不能替代另一平台。新增或修改 probe 时按 [Runtime 增量规则](../AGENTS.md)运行目标平台的直接检查。
