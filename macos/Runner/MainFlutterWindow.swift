import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // Smallest usable window (the terminal plus the host list side by side).
    self.contentMinSize = NSSize(width: 900, height: 600)
    self.title = "Conductore"
    // Remembers the window's size and position between runs.
    self.setFrameAutosaveName("ConductoreMainWindow")

    RegisterGeneratedPlugins(registry: flutterViewController)

    // conductore/window: setTitle(String), the focused session's name.
    let windowChannel = FlutterMethodChannel(
      name: "conductore/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    windowChannel.setMethodCallHandler { [weak self] call, result in
      if call.method == "setTitle", let title = call.arguments as? String {
        self?.title = title
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
