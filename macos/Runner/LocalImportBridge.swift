import Cocoa
import FlutterMacOS

/// macOS file-open relay for the path-free Dart ingress adapter. The AppDelegate
/// should call install(messenger:) after engine creation and handleOpen(urls:)
/// from application(_:open:); file_selector handles the in-app document picker.
final class LocalImportBridge {
  private struct ScopedURL {
    let url: URL
    let didStartAccess: Bool
  }

  private static var channel: FlutterMethodChannel?
  private static var pendingPayloads: [[String: String]] = []
  private static var scopedURLs: [String: ScopedURL] = [:]
  private static let lock = NSLock()

  static func install(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "mg_read/local_import", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { call, result in
      if call.method == "release" {
        guard let token = (call.arguments as? [String: Any])?["token"] as? String else { result(nil); return }
        lock.lock()
        let url = scopedURLs.removeValue(forKey: token)
        lock.unlock()
        if url?.didStartAccess == true { url?.url.stopAccessingSecurityScopedResource() }
        result(nil)
        return
      }
      guard call.method == "drainPending" else {
        result(FlutterMethodNotImplemented)
        return
      }
      lock.lock()
      let payload = pendingPayloads
      pendingPayloads.removeAll()
      lock.unlock()
      result(payload)
    }
  }

  static func acceptsDrop(_ sender: NSDraggingInfo) -> Bool { !fileURLs(sender).isEmpty }

  @discardableResult
  static func handleDrop(_ sender: NSDraggingInfo) -> Bool {
    let urls = fileURLs(sender)
    guard !urls.isEmpty else { return false }
    handleOpen(urls: urls)
    return true
  }

  static func handleOpen(urls: [URL]) {
    let readable = urls.filter { $0.isFileURL }
    guard !readable.isEmpty else { return }
    let payload = readable.prefix(100).map { url -> [String: String] in
      let token = UUID().uuidString
      let didStartAccess = url.startAccessingSecurityScopedResource()
      lock.lock()
      scopedURLs[token] = ScopedURL(url: url, didStartAccess: didStartAccess)
      lock.unlock()
      return ["path": url.path, "name": url.lastPathComponent, "securityToken": token]
    }
    lock.lock()
    let space = max(0, 100 - pendingPayloads.count)
    let accepted = Array(payload.prefix(space))
    pendingPayloads.append(contentsOf: accepted)
    let discarded = payload.dropFirst(space).compactMap { $0["securityToken"] }
    let urlsToRelease = discarded.compactMap { scopedURLs.removeValue(forKey: $0) }
    lock.unlock()
    urlsToRelease.filter(\.didStartAccess).forEach { $0.url.stopAccessingSecurityScopedResource() }
    channel?.invokeMethod("filesOpened", arguments: accepted)
  }

  private static func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
    guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return [] }
    return items.filter(\.isFileURL)
  }
}
