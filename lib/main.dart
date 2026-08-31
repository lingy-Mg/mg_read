import 'package:flutter/widgets.dart';

import 'package:mg_read/app/bootstrap.dart';
import 'package:mg_read/features/network_proxy/application/flutter_network_proxy_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await installSystemProxyHttpOverrides();
  await bootstrapMgReadApp();
}
