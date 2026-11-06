# 手机辅助 TV 增量规则

根 `AGENTS.md` 适用。本模块管理手机与接收端的控制关系，不拥有播放后端、来源资源或文件传输。

- 手机辅助 TV 从普通模式的“我的 → 内容与存储”和 TV 设置的“工具”进入，不挂载全局常驻悬浮入口。
  视频“在电视上播放”使用播放器顶部图标入口；设备选择弹层统一深色圆角卡片，短屏可滚动并保留底部安全区。
- `CompanionController` 为应用生命周期服务；页面仅持有发现订阅。关闭页面、断开手机和租约过期均不停止 TV 播放。
  Android 退后台关闭接收连接；桌面接收可保留，但不因此开启原有书架/插件自动同步。
- 复用 `LanPeerService` 的 HTTP 宿主与发现，不增加第二个发现宿主，不改变原有同步协议和配对策略。
  手机与 TV 在同一私有 IPv4 局域网可直接建立 companion 会话；此通道不要求配对、确认码、逐设备授权或持久密钥。
  `/companion/v1/ws` 使用临时 X25519 交换和新随机数派生方向独立的 AES-GCM 密钥；保留旧 PSK 握手兼容。
  发现信息和 `/companion/v1/identity` 仅用于定位身份，不构成授权。地址只驻内存，不保存新的信任记录。
- 手机默认不接收；TV 应用角色通过 `CompanionController.setTvMode(true)` 自动开启接收，离开 TV 角色时关闭。
  旧 companion PSK 会话仍受原控制/浏览策略约束；LAN 会话可直接控制及浏览普通视频收藏、历史。
  私密书架内容、本地文件、设置和来源 URL、Cookie、密钥、本地路径不得经目录、快照、历史或 LAN 浏览返回。
- 关闭接收和后台切换必须先使执行上下文失效，不能只关 UI。命令保留 host epoch、控制代次、播放代次、序号、
  截止时间和命令 ID 等全部过期栅栏。新的手机可自动接管旧控制租约并使旧 token 失效；TV 本地操作仍优先，
  本地优先期内远端不能接管。显式接管不再要求 TV 批准。
- TV 是播放状态唯一权威。命令同时携带 host epoch、控制代次、播放代次、序号、截止时间和命令 ID。
  重连只刷新状态，禁止自动重放变更。触摸、长按、音量防抖和文字编辑使用开始时的 interaction token；
  不得在迟到回调中重新申请控制权。TV 本地输入优先；本地优先期结束后手机可直接申请接管。
- `CompanionHandoffLauncher` 通过主应用注入，package 不得依赖本模块。TV 独立解析来源和目录，保留分组与集数身份，
  来源版本不一致须明确失败。候选取得真实首帧后才进入可见切换；实际播放与平台激活完成后才回复 started。
  取消、超时和失败要释放候选、保留/恢复原播放及其进度，不得把准备过程写成已观看。
- 视频历史由 ContentLibrary 公开端口保存。每个本地会话只分配一次持久 generation；迟到的旧会话不能刷新为新代次。
  远端保存必须携带本机 revision 做 CAS；冲突保留设备分支，禁止盲覆本机续播指针。
  当前会话的进度推送不等于授予普通收藏或完整历史访问权。
- 来源搜索使用已有 BatchSearchCoordinator，搜索不切 TV 路由；变体、分组、集数、收藏和历史分批返回，
  保持来源身份与失败结果。受限页面、私密内容和导入/安装确认不得由通用远端导航绕过。
- 手机中文输入只同步完成的全文和递增 revision；IME 组词留在手机。取消、断线和闲置超时恢复 TV 原草稿；
  TV 本地编辑使旧输入会话失效。只允许明确挂载的搜索编辑器，禁止通用键盘注入。

直接测试位于 `test/features/tv_companion/`、`test/core/content_library/video_history*_test.dart` 和
`test/features/lan_sync/data/companion_pairing_test.dart`。播放器准备/接管测试属于视频 package 与应用 media 测试。
根 Flutter 并发检查需串行，避免 Windows native-assets DLL 被另一测试进程锁住；不要终止其他任务的进程。
模拟后端、真实加密 loopback、Android 构建和实体双设备验收必须分别报告。
Windows/MuMu 原生入口与验收证据边界见 [`companion_native_qa.md`](../../../integration_test/companion_native_qa.md)。
