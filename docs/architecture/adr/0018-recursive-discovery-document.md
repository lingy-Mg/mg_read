# ADR-0018：预发布发现组件树

- 状态：Accepted
- 日期：2026-08-21
- 决策者：MgRead 项目
- 替代：[ADR-0017](0017-versioned-plugin-content-contract.md)

## 背景

当前尚未发布任何第三方书源，且只有开发期测试书源。原发现 API 把内容限制为平铺的 tab 和
section/layout，不能表达多组数据、嵌套分类或复杂的受控排版；根级 cursor 也不能准确追加指定
集合。

## 决策

1. 保持 `source.discover.v1` 与 Plugin API `1` 名称，直接以递归 `DiscoveryDocument` 替换旧
   `tabs/sections/nextCursor` 形状；不保留旧对象、探测或双轨兼容。
2. 文档节点只能是 `tabs`、`section`、`group`、`contentCollection`、`categoryCollection`、
   `text`、`divider`。`section/group` 可递归；tabs 至多一个且只能是根首节点。
3. 布局枚举只表达宿主支持的语义展示：group 为 vertical/horizontal/grid；内容集合为
   featured/carousel/ranking/list；分类集合为 grid/list。插件不能下发 Flutter Widget、脚本、
   颜色、尺寸、网络动作或任意样式。
4. 分类和 tab 只携带当前插件的不透明 target。tab 替换当前树；分类进入下一棵树。主应用保存
   成功树栈并在返回时复用，不把 Runtime 或网页状态泄漏到 Widget。
5. 分页属于 `contentCollection` 的 nullable `{target,cursor}` continuation。续页请求带
   `target/cursor/collectionId`，返回 `append` 片段；宿主只能追加同 ID 的集合。聚合树没有
   continuation 时不得展示加载更多。
6. Runtime 与 Flutter Facade 都严格校验 union、显式 null、唯一 ID、tabs 位置、集合内容、深度、
   节点/条目/响应字节上限。未知键可丢弃，未知节点或不一致 append 统一拒绝为稳定错误。
7. 搜索、详情、目录、正文的富摘要、显式 null、opaque ID/cursor、单 Runtime/VM、数据权威和
   默认脱敏诊断规则延续 ADR-0017，不作放宽。

## 后果

- 书源可声明复杂但受控的发现排版，宿主仍统一主题、可访问性、响应式和交互。
- 所有 Runtime fixture、官方模板、内置书源和 Flutter adapter 必须一次性迁移；旧 v1 发现响应被
  视为 `plugin_invalid_response`。
- 不在本决策中加入视觉编辑器、布局持久化、远程样式、任意代码或 WebView。
