// Owns the Flutter window and forwards registered file drops to LocalImportBridge.
// NSWindow does not implement the Swift NSDraggingDestination methods; declare
// protocol conformance so AppKit can dispatch them without an invalid override.
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSDraggingDestination {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    LocalImportBridge.install(messenger: flutterViewController.engine.binaryMessenger)
    registerForDraggedTypes([.fileURL])

    super.awakeFromNib()
  }

  func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    LocalImportBridge.acceptsDrop(sender) ? .copy : []
  }

  func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    LocalImportBridge.handleDrop(sender)
  }
}
