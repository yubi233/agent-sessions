import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    RegisterGeneratedPlugins(registry: flutterViewController)
    super.awakeFromNib()

    // AppKit 会在 awakeFromNib 返回前应用 XIB frame，因此把手机竖屏尺寸放到下一次主循环；
    // 不锁定 min/max，确保 Flutter integration_test 仍可协商自己的测试 surface。
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.setContentSize(NSSize(width: 480, height: 960))
      self.center()
    }
  }
}
