import AppKit
import OSLog
import SwiftUI

@MainActor
final class AppCoordinator {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ScreenshotApp", category: "App")
    private let shortcutService: ShortcutRegistering
    private let shortcutStore = ShortcutStore()
    private let permissionService = ScreenCapturePermissionService()
    private let captureService: ScreenCapturing = ScreenCaptureService()
    private let settings = SettingsStore()
    private lazy var exportService = ImageExportService(
        settings: settings,
        directoryStore: DefaultSaveDirectoryStore()
    )
    private lazy var pinManager = PinWindowManager(defaultOpacity: settings.pinOpacity)
    private let overlayController = CaptureOverlayController()
    private var statusBarController: StatusBarController?
    private var availableContent: AvailableCaptureContent?
    private var settingsWindow: NSWindow?

    init(shortcutService: ShortcutRegistering = NativeShortcutService()) {
        self.shortcutService = shortcutService
        overlayController.delegate = self
    }

    func start() {
        let statusBarController = StatusBarController(
            onInteractiveCapture: { [weak self] in self?.beginCapture(.interactive) },
            onDisplayCapture: { [weak self] in self?.beginCapture(.display) },
            onOpenSettings: { [weak self] in self?.openSettings() },
            onQuit: { NSApp.terminate(nil) }
        )
        self.statusBarController = statusBarController

        registerShortcuts()
    }

    private func registerShortcuts() {
        shortcutService.unregisterAll()
        do {
            try shortcutService.register(.interactiveCapture, configuration: shortcutStore.interactiveCapture) { [weak self] in
                Task { @MainActor in self?.beginCapture(.interactive) }
            }
            try shortcutService.register(.displayCapture, configuration: shortcutStore.displayCapture) { [weak self] in
                Task { @MainActor in self?.beginCapture(.display) }
            }
        } catch {
            logger.error("Unable to register a default shortcut: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        shortcutService.unregisterAll()
        statusBarController = nil
    }

    private func beginCapture(_ mode: CaptureMode) {
        guard ensureScreenCapturePermission() else { return }

        switch mode {
        case .interactive:
            beginInteractiveCapture()
        case .display:
            beginDisplayCapture()
        }
    }

    private func openSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(store: settings) {
            ShortcutSettingsContent(store: self.shortcutStore) { [weak self] in
                self?.registerShortcuts()
            }
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "轻截设置"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: settingsView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    private func ensureScreenCapturePermission() -> Bool {
        switch permissionService.refresh() {
        case .authorized:
            return true
        case .notDetermined:
            if permissionService.requestAccess() { return true }
        case .denied:
            break
        }

        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "请在系统设置中允许“轻截”录制屏幕，然后再试一次。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            permissionService.openSystemSettings()
        }
        return false
    }

    private func beginInteractiveCapture() {
        Task { [weak self] in
            guard let self else { return }
            do {
                availableContent = try await captureService.availableContent()
                overlayController.present()
            } catch {
                present(error)
            }
        }
    }

    private func beginDisplayCapture() {
        guard let displayID = NSScreen.main.flatMap(Self.displayID(for:)) else {
            present(ScreenshotAppError.contentUnavailable)
            return
        }
        capture(target: .display(displayID: displayID))
    }

    private func capture(target: CaptureTarget, action: CaptureCompletionAction? = nil) {
        overlayController.dismiss()
        Task { [weak self] in
            guard let self else { return }
            do {
                // Give the WindowServer one frame to remove the overlay before capture.
                try await Task.sleep(for: .milliseconds(80))
                let result = try await captureService.capture(target)
                try await handleCaptureResult(result, action: action)
            } catch {
                present(error)
            }
        }
    }

    private func present(_ error: Error) {
        logger.error("\(error.localizedDescription, privacy: .public)")
        NSAlert(error: error).runModal()
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    private func handleCaptureResult(
        _ result: CaptureResult,
        action: CaptureCompletionAction? = nil
    ) async throws {
        switch action ?? settings.completionAction {
        case .copy:
            try await exportService.copyToPasteboard(result.image)
        case .save:
            try await exportService.save(result.image)
        case .pin:
            pinManager.createPin(for: result.image)
        case .annotate:
            // The annotation editor will take ownership of the result in the next milestone.
            try await exportService.copyToPasteboard(result.image)
            showAnnotationPlaceholder()
        }
        if settings.playCaptureSound {
            NSSound(named: "Tink")?.play()
        }
    }

    private func showAnnotationPlaceholder() {
        let alert = NSAlert()
        alert.messageText = "截图已复制"
        alert.informativeText = "标注编辑器正在接入；当前截图已安全复制到剪贴板。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

extension AppCoordinator: CaptureOverlayControllerDelegate {
    func overlayController(
        _ controller: CaptureOverlayController,
        didRequest overlayAction: CaptureOverlayAction,
        for rect: CGRect,
        on screen: NSScreen
    ) {
        guard let displayID = Self.displayID(for: screen),
              let display = availableContent?.displays.first(where: { $0.id == displayID }) else {
            present(ScreenshotAppError.displayNotFound(0))
            return
        }

        let globalFrame = display.frameInGlobalPoints.value
        let localRect = rect.offsetBy(dx: -globalFrame.minX, dy: -globalFrame.minY)
        let action: CaptureCompletionAction
        switch overlayAction {
        case .copy: action = .copy
        case .save: action = .save
        case .pin: action = .pin
        }
        capture(target: .region(displayID: displayID, rectInDisplay: localRect), action: action)
    }

    func overlayControllerDidCancel(_ controller: CaptureOverlayController) {
        availableContent = nil
        controller.dismiss()
    }

    func overlayController(
        _ controller: CaptureOverlayController,
        windowAt globalPoint: CGPoint
    ) -> CGRect? {
        availableContent?.windows
            .first(where: { $0.frameInGlobalPoints.value.contains(globalPoint) })?
            .frameInGlobalPoints.value
    }
}

@MainActor
private final class PinWindowManager: PinWindowManaging {
    private var windows: [NSWindow] = []
    private let defaultOpacity: Double

    init(defaultOpacity: Double) {
        self.defaultOpacity = defaultOpacity
    }

    func createPin(for image: CGImage) {
        let sourceSize = CGSize(width: image.width, height: image.height)
        let maximum = CGSize(width: 460, height: 340)
        let scale = min(1, maximum.width / sourceSize.width, maximum.height / sourceSize.height)
        let size = CGSize(width: max(160, sourceSize.width * scale), height: max(100, sourceSize.height * scale))

        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.alphaValue = defaultOpacity
        panel.isReleasedWhenClosed = false

        let contentView = PinContentView(image: image, initialOpacity: defaultOpacity)
        contentView.onOpacityChanged = { [weak panel] opacity in
            panel?.alphaValue = opacity
        }
        contentView.onClose = { [weak panel] in
            panel?.close()
        }
        panel.contentView = contentView
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        windows.append(panel)
    }

    func closeAllPins() {
        windows.forEach { $0.close() }
        windows.removeAll()
    }
}

@MainActor
private final class PinContentView: NSView {
    var onOpacityChanged: ((CGFloat) -> Void)?
    var onClose: (() -> Void)?

    private let imageView: NSImageView
    private let opacitySlider = NSSlider(value: 1, minValue: 0.2, maxValue: 1, target: nil, action: nil)
    private let controls = NSVisualEffectView()

    init(image: CGImage, initialOpacity: Double) {
        imageView = NSImageView(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        controls.material = .hudWindow
        controls.blendingMode = .withinWindow
        controls.state = .active
        controls.wantsLayer = true
        controls.layer?.cornerRadius = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)

        opacitySlider.doubleValue = initialOpacity
        opacitySlider.target = self
        opacitySlider.action = #selector(changeOpacity)
        opacitySlider.controlSize = .small
        opacitySlider.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = NSButton(title: "×", target: self, action: #selector(closePin))
        closeButton.bezelStyle = .circular
        closeButton.controlSize = .small
        closeButton.font = .systemFont(ofSize: 13, weight: .semibold)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        controls.addSubview(opacitySlider)
        controls.addSubview(closeButton)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),

            controls.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            controls.widthAnchor.constraint(equalToConstant: 142),
            controls.heightAnchor.constraint(equalToConstant: 30),

            opacitySlider.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 9),
            opacitySlider.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            opacitySlider.widthAnchor.constraint(equalToConstant: 92),
            closeButton.leadingAnchor.constraint(equalTo: opacitySlider.trailingAnchor, constant: 5),
            closeButton.centerYAnchor.constraint(equalTo: controls.centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func changeOpacity() {
        onOpacityChanged?(opacitySlider.doubleValue)
    }

    @objc private func closePin() {
        onClose?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === imageView ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !controls.frame.contains(point), let window else {
            super.mouseDown(with: event)
            return
        }
        window.makeKeyAndOrderFront(nil)
        window.performDrag(with: event)
    }
}
