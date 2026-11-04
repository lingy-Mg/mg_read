/// Orders LAN discovery and peer services so first time visitors advertise a
/// host even when they have no paired devices.
library;

typedef DiscoveryStartupAction = Future<void> Function();

Future<bool> startCompanionDiscovery({
  required DiscoveryStartupAction discover,
  required DiscoveryStartupAction ensurePeerServices,
  required bool Function() isMounted,
  required DiscoveryStartupAction stopDiscovery,
  required void Function() onDiscoveryStarted,
}) async {
  await discover();
  if (!isMounted()) {
    await stopDiscovery();
    return false;
  }
  onDiscoveryStarted();
  await ensurePeerServices();
  return isMounted();
}
