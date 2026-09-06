import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var appliedInitialPhoneSize = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    // Assigning the Flutter view controller can adopt its intrinsic size.
    // Restore the XIB frame before the window is ordered so the macOS debug
    // shell cannot collapse to the view's 1x32 fallback size.
    self.setFrame(windowFrame, display: true)
    RegisterGeneratedPlugins(registry: flutterViewController)
    // v0.9.0 B7：headed 可见验收的窗口尺寸通道。dart-define 无法从 Swift 读取
    // （flutter run 不透传进程 env），由 Dart 侧读取编译期常量后经本通道调用。
    let visualGateChannel = FlutterMethodChannel(
      name: "v090/visual_gate",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    visualGateChannel.setMethodCallHandler { call, result in
      if call.method == "resize",
         let arguments = call.arguments as? [String: NSNumber],
         let width = arguments["w"]?.doubleValue,
         let height = arguments["h"]?.doubleValue {
        DispatchQueue.main.async {
          self.setContentSize(NSSize(width: width, height: height))
          self.center()
        }
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    super.awakeFromNib()
  }

  override func makeKeyAndOrderFront(_ sender: Any?) {
    super.makeKeyAndOrderFront(sender)
    guard !appliedInitialPhoneSize else { return }
    appliedInitialPhoneSize = true

    // 等窗口完成状态恢复并真正显示后再设置初始手机画布，避免 XIB/restoration 覆盖 480x960。
    // 不锁定 min/max，确保用户和 Flutter integration_test 仍可协商后续 surface。
    // v0.9.0 B7：headed 可见验收 runner 经 V090_WINDOW_W/H 注入代表性视口
    // （360x800 / 430x932 / 1280x800）；未注入时保持 480x960 既有口径。
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.setContentSize(NSSize(width: 480, height: 960))
      self.center()
    }
  }
}
