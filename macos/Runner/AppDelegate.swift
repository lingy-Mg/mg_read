import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func application(_ application: NSApplication, open urls: [URL]) {
    let books = urls.filter { $0.isFileURL && ["txt", "epub"].contains($0.pathExtension.lowercased()) }
    if !books.isEmpty { LocalImportBridge.handleOpen(urls: books) }
    let other = urls.filter { !books.contains($0) }
    if !other.isEmpty { super.application(application, open: other) }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
