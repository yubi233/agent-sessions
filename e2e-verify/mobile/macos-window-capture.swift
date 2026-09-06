import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

// v0.9.0 B7：窗口级截图工具（macOS 15+）。
// `screencapture -l <id>` 在 macOS 26 上报 "could not create image from window"
// 且 CGWindowListCreateImage 已废弃；按系统要求改用 ScreenCaptureKit。
// 用法：swift macos-window-capture.swift <windowId> <out.png>
// 仍受屏幕录制 TCC 约束；只输出指定 CGWindowNumber 的单窗口图像。
let arguments = CommandLine.arguments
guard arguments.count == 3, let windowID = UInt32(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: capture <windowId> <out.png>\n".utf8))
    exit(2)
}
let outputURL = URL(fileURLWithPath: arguments[2]) as CFURL
let semaphore = DispatchSemaphore(value: 0)

// CLI 进程需先初始化 App 应用上下文，否则 ScreenCaptureKit 访问窗口服务时
// 会在 SkyLight CGS_REQUIRE_INIT 断言崩溃。
_ = NSApplication.shared
let semaphoreTimeout = DispatchTime.now() + .seconds(30)

Task {
    defer { semaphore.signal() }
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            FileHandle.standardError.write(Data("window not found\n".utf8))
            exit(1)
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            FileHandle.standardError.write(Data("could not create destination\n".utf8))
            exit(1)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            FileHandle.standardError.write(Data("could not finalize png\n".utf8))
            exit(1)
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}
if semaphore.wait(timeout: semaphoreTimeout) == .timedOut {
    FileHandle.standardError.write(Data("capture timed out\n".utf8))
    exit(1)
}
