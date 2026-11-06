# B站视频数据源增量规则

- 本目录拥有独立视频插件 `org.mgread.bilibili-video`；音频插件不共享实现或状态。
- 搜索、链接解析和分 P 目录沿用 B站音频源的公开 API 结构；发现页只声明用户输入，不伪造推荐作品。
- 播放请求使用 HTML5 单文件 MP4 响应，由 Runtime 代理媒体；不读取视频主体、不复用 DASH 裸视频轨道，
  不把多段 `durl` 的第一段当作完整分 P。暂不支持登录、会员、DASH 合流或多段拼接。
- 详情缓存最多 16 项、60 秒，激活时清空、失败不缓存。稳定身份只包含 BVID/CID，不包含媒体签名。
- 媒体和封面登记前校验 B站 CDN 主机、端口、协议、凭据和路径；不保存账号 Cookie 或伪造浏览器 UA。
- 固定 Node/npm 执行 `verify`、`test:live`；快速检查使用 source-testkit 的 `--source bilibili-video`。
- `test/acceptance.json` 只为没有推荐条目的输入式发现页提供显式诊断查询；主程序自动自检仍可能返回
  `source_input_required`，不得把资源前缀可达描述为播放器首帧或进度验证通过。
