import AppKit
import SwiftUI

/// 保留主窗口及其编辑状态，让红叉和快捷键只收起窗口。
@MainActor
final class WindowLifecycle {
    static let shared = WindowLifecycle()
    weak var mainWindow: NSWindow?

    func hideMainWindow() {
        NSApp.hide(nil)
    }

    func showMainWindow() {
        NSApp.unhide(nil)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class TimetableAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowLifecycle.shared.showMainWindow()
        return false
    }
}

/// 将未处理的窗口代理事件继续交给 SwiftUI 的原始代理。
private final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        WindowLifecycle.shared.hideMainWindow()
        return false
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if original?.responds(to: selector) == true { return original }
        return super.forwardingTarget(for: selector)
    }
}

struct MainWindowObserver: NSViewRepresentable {
    final class Coordinator {
        fileprivate let proxy = WindowDelegateProxy()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { attach(view: view, coordinator: context.coordinator) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { attach(view: view, coordinator: context.coordinator) }
    }

    private func attach(view: NSView, coordinator: Coordinator) {
        guard let window = view.window else { return }
        WindowLifecycle.shared.mainWindow = window
        if window.delegate !== coordinator.proxy {
            coordinator.proxy.original = window.delegate
            window.delegate = coordinator.proxy
        }
    }
}
