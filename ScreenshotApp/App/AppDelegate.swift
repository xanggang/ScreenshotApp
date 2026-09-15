import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private var developmentWindow: NSWindow?
    private let permissionService = ScreenCapturePermissionService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        coordinator.start()
        updateLaunchPresentation()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Covers returning from System Settings after the user grants access.
        updateLaunchPresentation()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }

    private func showDevelopmentWindow() {
        guard developmentWindow == nil else {
            developmentWindow?.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 230),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "轻截（开发中）"
        window.center()
        window.isReleasedWhenClosed = false

        let title = NSTextField(labelWithString: "轻截正在运行")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let detail = NSTextField(wrappingLabelWithString: "这是开发阶段的启动窗口。点击下方按钮会请求“屏幕与系统音频录制”权限；正式版将只保留菜单栏入口。")
        detail.textColor = .secondaryLabelColor

        let permissionButton = NSButton(title: "请求屏幕权限", target: self, action: #selector(requestScreenCapturePermission))
        permissionButton.bezelStyle = .rounded
        let quitButton = NSButton(title: "退出", target: self, action: #selector(quitApplication))
        quitButton.bezelStyle = .rounded

        let stack = NSStackView(views: [title, detail, permissionButton, quitButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28)
        ])

        developmentWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func requestScreenCapturePermission() {
        if permissionService.refresh() == .notDetermined {
            _ = permissionService.requestAccess()
        } else if permissionService.status == .denied {
            permissionService.openSystemSettings()
        }
        updateLaunchPresentation()
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    private func updateLaunchPresentation() {
        if permissionService.refresh() == .authorized {
            developmentWindow?.orderOut(nil)
            developmentWindow = nil
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
            showDevelopmentWindow()
        }
    }
}

@main
@MainActor
final class ScreenshotAppLauncher: NSObject {
    private static let appDelegate = AppDelegate()

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.delegate = appDelegate
        application.run()
    }
}
