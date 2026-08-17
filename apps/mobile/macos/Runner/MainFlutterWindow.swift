import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var appliedInitialPhoneSize = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    RegisterGeneratedPlugins(registry: flutterViewController)
    super.awakeFromNib()
  }

  override func makeKeyAndOrderFront(_ sender: Any?) {
    super.makeKeyAndOrderFront(sender)
    guard !appliedInitialPhoneSize else { return }
    appliedInitialPhoneSize = true

    // 等窗口完成状态恢复并真正显示后再设置初始手机画布，避免 XIB/restoration 覆盖 480x960。
    // 不锁定 min/max，确保用户和 Flutter integration_test 仍可协商后续 surface。
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.setContentSize(NSSize(width: 480, height: 960))
      self.center()
    }
  }
}
