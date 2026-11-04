# 手机辅助 TV 增量规则

根 `AGENTS.md` 适用。本模块管理手机与接收端的控制关系，不拥有播放后端、来源资源或文件传输。

- `CompanionController` 为应用生命周期服务；页面仅持有发现订阅。关闭页面、断开手机和租约过期均不停止 TV 播放。
  Android 退后台关闭接收连接；桌面接收可保留，但不因此开启原有书架/插件自动同步。
- 复用 LAN 配对设备和 PSK，通过 `LanPeerService` 共用 HTTP 宿主与发现。不要增加第二个发现宿主，
  不改变原有同步协议和默认网络资格。本地文件仍走 local-document 的导入/受控传输边界。
- 接收默认关闭；控制和普通收藏/完整历史浏览各自显式授权。授权绑定当前 PSK 的摘要；重新配对相同设备 ID
  不恢复旧授权。撤销设备、关闭接收和后台切换必须先使执行上下文失效，不能只关 UI。
- `/companion/v1/ws` 自己完成相互认证，新随机数握手后派生方向独立的 AES-GCM 密钥；递增序号拒绝重放。
  发现信息不构成信任，地址仅驻内存。禁止将来源 URL、Cookie、密钥、本地路径加入目录、快照和历史。
- TV 是播放状态唯一权威。命令同时携带 host epoch、控制代次、播放代次、序号、截止时间和命令 ID。
  重连只刷新状态，禁止自动重放变更。触摸、长按、音量防抖和文字编辑使用开始时的 interaction token；
  不得在迟到回调中重新申请控制权。TV 本地输入优先，显式接管只能由 TV 本地确认。
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
