/// 局域网同步专用 HTTP 客户端工厂。
///
/// 局域网端点必须始终直连，不能继承应用的系统或自定义上游代理；连接建立使用
/// 有界超时，业务阶段自己的等待时间由各会话协议继续控制。
library;

import 'dart:io';

const Duration lanSyncHttpConnectionTimeout = Duration(seconds: 5);

HttpClient createLanSyncHttpClient() => HttpClient()
  ..connectionTimeout = lanSyncHttpConnectionTimeout
  ..findProxy = (_) => 'DIRECT';
