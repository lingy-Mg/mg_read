/// The only Flutter-facing entrypoint for MgRead plugin Runtime capabilities.
///
/// The Runtime owns its desktop child process, readiness gates and internal
/// wire protocol. Flutter application code calls [PluginRuntime.invoke] with a
/// typed [PluginInvocation]; it never receives a PID, port or WebSocket.
library mgread_plugin_runtime;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'src/windows_job_object.dart';

part 'src/desktop_supervisor.dart';
part 'src/plugin_invocation.dart';
part 'src/plugin_runtime.dart';
part 'src/runtime_error.dart';
part 'src/wire_connection.dart';
