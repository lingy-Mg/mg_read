import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
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

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    LocalImportBridge.acceptsDrop(sender) ? .copy : []
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    LocalImportBridge.handleDrop(sender)
  }
}
