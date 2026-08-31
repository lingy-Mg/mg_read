/// MgRead 插件 Runtime 的 Flutter 入口库。
///
/// 职责：
/// - 暴露版本化、强类型的 Runtime Facade 与插件内容调用模型。
/// - 统一管理 desktop/Android Runtime 的生命周期和内部 wire 协议。
///
/// 注意：
/// - Flutter 只能调用 [PluginRuntime.invoke]，不得获得 PID、端口或 WebSocket。
/// - 每个进程只能有一个 Node Runtime/VM，插件协议错误必须经 typed Facade 返回。
///
library mgread_plugin_runtime;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';

import 'src/windows_job_object.dart';
import 'src/windows_browser_session_host.dart';

part 'src/windows_system_proxy.dart';
part 'src/system_proxy.dart';
part 'src/desktop_supervisor.dart';
part 'src/desktop_plugin_artifact_io.dart';
part 'src/desktop_development_synchronization.dart';
part 'src/desktop_supervisor_bundle.dart';
part 'src/desktop_supervisor_support.dart';
part 'src/development_plugin_change.dart';
part 'src/android_supervisor.dart';
part 'src/plugin_content_invocation.dart';
part 'src/plugin_content_decoder.dart';
part 'src/runtime_initialization.dart';
part 'src/plugin_invocation.dart';
part 'src/plugin_transfer_invocation.dart';
part 'src/plugin_runtime.dart';
part 'src/runtime_error.dart';
part 'src/wire_connection.dart';
