/// 局域网同步的端点地址约束。
///
/// 职责：为临时传输、首次配对和已配对发现提供同一组私有 IPv4 与候选数量规则。
///
/// 注意：本层不解析任何二维码或网络帧，避免让某个具体协议成为其他协议的依赖。
library;

const int lanSyncMaxCandidateAddresses = 16;

bool isLanSyncPrivateIpv4(String address) {
  final parts = address.split('.').map(int.tryParse).toList(growable: false);
  if (parts.length != 4 || parts.any((part) => part == null || part < 0 || part > 255)) {
    return false;
  }
  final a = parts[0]!;
  final b = parts[1]!;
  return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
}

List<String> normalizeLanSyncAddresses(Iterable<String> addresses) {
  final normalized = addresses.toSet().toList(growable: false);
  if (normalized.isEmpty ||
      normalized.length > lanSyncMaxCandidateAddresses ||
      normalized.any((address) => !isLanSyncPrivateIpv4(address))) {
    throw ArgumentError.value(addresses, 'addresses', 'Invalid private LAN IPv4 addresses.');
  }
  return List<String>.unmodifiable(normalized);
}
