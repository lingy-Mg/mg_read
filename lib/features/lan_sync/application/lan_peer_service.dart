/// Optional foreground peer service hosted beside LAN sync. A service owns its
/// own authentication, authorization, bounded payloads and cancellation; this
/// port does not grant access to sync sessions or the Runtime.
library;

import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';

abstract interface class LanPeerService {
  bool get requiresHost;
  Future<bool> canUseNetwork();
  Map<String, Object?> get advertisement;
  Future<bool> handleRequest(HttpRequest request);
  void discovered({
    required String deviceId,
    required String label,
    required String address,
    required int port,
    required Duration lifetime,
    required Map<String, Object?> services,
  });
  void hostChanged(int? port);
  void trustRevoked(String deviceId);
}

final lanPeerServiceProvider = Provider<LanPeerService?>((ref) => null);
