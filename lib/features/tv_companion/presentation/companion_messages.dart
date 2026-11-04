/// User-readable states. Stable error codes remain available for diagnostics;
/// raw transport exceptions, source URLs and credentials never enter this UI.
library;

String companionErrorText(String? code) => switch (code) {
  null => '操作完成',
  'not_paired' => '连接记录已失效，请重新选择局域网 TV。',
  'local_network_permission_required' => '需要本地网络权限。请允许后重试，也可以在系统设置中重新授权。',
  'local_network_unavailable' => '未找到可用局域网。请确认手机和 TV 在可以互访的同一网络中。',
  'connection_or_authorization_failed' => '无法连接 TV。请确认接收端已进入 TV 模式，并检查局域网和防火墙。',
  'invalid_lan_endpoint' => '请填写有效的局域网 IPv4 地址和端口。',
  'remote_identity_unavailable' || 'invalid_remote_identity' => '该地址不是可用的 TV 接收端，请核对 TV 上显示的地址和端口。',
  'connection_lost' || 'connection_timeout' => '连接已中断，TV 的播放会继续。正在重新发现设备。',
  'connection_lost_result_unknown' || 'command_result_unknown' => '连接中断，操作结果尚未确认。重连后先查看 TV 状态，请勿重复发送。',
  'state_unavailable' || 'not_connected' => '尚未取得 TV 的实时状态，请连接后重试。',
  'control_owned' => 'TV 控制状态已变化，请查看最新状态后重新操作。',
  'local_control_active' => 'TV 正在本地操作，请稍后再操作手机遥控。',
  'control_required' || 'not_control_owner' => '请先取得控制权。',
  'stale_control_generation' ||
  'execution_invalidated' ||
  'stale_playback_generation' ||
  'interaction_changed' => 'TV 状态已变化，旧操作已取消。请查看最新状态后重试。',
  'source_unavailable' || 'video_source_unavailable' => 'TV 没有可用的对应来源。请在 TV 数据源管理中安装或启用，也可使用局域网插件传输。',
  'source_version_mismatch' => '手机与 TV 的来源版本不同，请统一版本，或直接使用“搜索 TV 来源”选片。',
  'phone_source_unavailable' => '本机未安装或启用记录对应的来源，请先在来源管理中安装，也可连接 TV 后继续。',
  'group_unavailable' || 'episode_unavailable' || 'video_episode_unavailable' => 'TV 目录中没有对应分组或集数，请重新选集。',
  'video_detail_load_failed' || 'video_catalog_load_failed' || 'video_episode_resource_missing' => 'TV 无法取得播放内容。请在 TV 检查来源、登录或验证，然后重试。',
  'candidate_not_ready' ||
  'prepare_failed' ||
  'prepared_first_frame_timeout' ||
  'play_failed' ||
  'video_activation_failed' => '候选内容未能准备好，当前播放已保留。可检查来源、网络或 TV 解码资源后重试。',
  'library_permission_required' => '当前会话无法读取 TV 收藏，请重新连接。',
  'no_active_playback' => 'TV 当前没有视频播放。先找片或从 TV 收藏中选择。',
  'seek_unavailable' => '当前内容没有可跳转的已知时长。',
  'text_context_changed' => 'TV 已切页或本地修改了输入，旧输入会话已结束。请重新打开手机输入。',
  'text_revision_invalid' => '文字超过 256 字符或输入版本已失效，请缩短后重试。',
  'system_volume_unavailable' || 'system_volume_not_applied' => '设备不支持此系统音量操作，请使用 TV 实体遥控器。',
  'local_content_unsupported' => '本地内容需要先在 TV 导入；本入口只发送可由 TV 独立解析的视频来源。',
  'deadline_expired' || 'execution_timeout' => '操作已超时并失效，请查看 TV 当前状态后重试。',
  'navigation_unavailable' => '当前页面不允许远端导航，请在 TV 本地操作。',
  _ => '操作未完成，请检查 TV 上的提示后重试。错误：$code',
};
