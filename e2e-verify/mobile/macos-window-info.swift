import CoreGraphics
import Foundation

// 此工具只接收固定的 Flutter 应用进程名，输出屏幕上可见窗口的最小元数据。
let arguments = CommandLine.arguments
guard arguments.count == 3,
      arguments[1] == "--process-name",
      arguments[2] == "agent_sessions_mobile" else {
  FileHandle.standardError.write(Data("invalid arguments\n".utf8))
  exit(2)
}

let targetProcessName = arguments[2]
let windowList = CGWindowListCopyWindowInfo(
  [.optionOnScreenOnly, .excludeDesktopElements],
  kCGNullWindowID,
) as? [[String: Any]] ?? []

var visibleWindows: [[String: Int]] = []
for window in windowList {
  guard (window[kCGWindowOwnerName as String] as? String) == targetProcessName,
        (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0,
        let identifier = (window[kCGWindowNumber as String] as? NSNumber)?.intValue,
        let processID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.intValue,
        let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary else {
    continue
  }

  var bounds = CGRect.zero
  // 只计入具有实际可见面积的主层窗口，排除隐藏或零尺寸的辅助窗口。
  guard CGRectMakeWithDictionaryRepresentation(boundsDictionary, &bounds),
        bounds.width > 1,
        bounds.height > 1 else {
    continue
  }
  visibleWindows.append([
    "height": Int(bounds.height.rounded()),
    "id": identifier,
    "pid": processID,
    "width": Int(bounds.width.rounded()),
  ])
}

let payload: [String: Any] = [
  "count": visibleWindows.count,
  "windows": visibleWindows,
]
let output = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
FileHandle.standardOutput.write(output)
FileHandle.standardOutput.write(Data("\n".utf8))
