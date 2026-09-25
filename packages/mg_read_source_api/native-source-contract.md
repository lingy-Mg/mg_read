# 独立原生来源公开边界

此文件拥有原生来源与既有内容语义的映射；生命周期、内存布局和宿主实现由 native ABI/Runtime 拥有。
ABI v1 唯一定义在 `../mg_read_native_runtime/abi/lib.rs`，消费端必须引用该 crate，不能复制结构体布局。

来源入口接收 `{method, request}` 并返回 `{ok:true,value}` 或 `{ok:false,error:{code,message}}`。
六个方法与现有来源一致：`discover/search/searchSuggestions/getDetail/getChapters/getContent`。
`id/target/cursor/chapterId` 均由来源定义并保持稳定；网络 URL 不能当作 Flutter 的 Runtime 私有协议。

- Runtime 校验大小、深度、身份、重复目录及能力，再补充 `pluginId/sourceName`，由既有 Dart 强类型 Facade
  完成内容解码。数据只有经过这些公开边界才能交给主应用持久化。
- 原生 v1 承载小说；单章 UTF-8 文本上限 1 MiB，总 JSON 上限 8 MiB，目录上限 5000。正文不截断。
  这些预算属于原生引擎；旧 Node 引擎的已有预算保持不变，不将不同引擎视为相同执行能力。
- 私有 Host API 使用原生函数表；`http`、`storage.read/write/remove`、`cancelled`、`log` 由原生宿主实现。
  Storage 只接受 `data/cache` 和相对路径；SDK 规则不构成针对恶意原生代码的权限沙箱。
- 封面结果中的 `{$resource: descriptor}` 由宿主替换成资源 URL；缓存保存 descriptor，不能缓存进程相关的
  临时地址。原生 v1 未实现的 WebView、Browser Profile、漫画和音视频能力必须明确报 `unsupported`。
- Rust 来源在 worker 上以同步 C ABI 被调用；宿主 HTTP 使用可取消的异步 I/O。指针、输入和上下文只在
  调用内借用，所有输出由原分配方释放；不得跨 ABI 传递 Rust Future、trait 或容器，也不得保留宿主指针。

参考来源位于 `../../plugins/sources/aisishuwu-native/`。语言实现、设备平台和真实 App 的通过证据分别记录。
