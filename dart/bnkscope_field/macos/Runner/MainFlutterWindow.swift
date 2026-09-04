import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    // Open wide enough for the sidebar and two chart panels beside it: the
    // split folds the sidebar away below 900 points, and a window that
    // opens narrower than that starts life looking collapsed.
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 480, height: 400)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    // After the nib has restored whatever frame it saved: a window that was
    // last closed narrow is still opened wide enough for the sidebar.
    if self.frame.width < 1180 {
      var wide = self.frame
      wide.size = NSSize(width: 1180, height: 780)
      self.setFrame(wide, display: true)
    }
  }
}
