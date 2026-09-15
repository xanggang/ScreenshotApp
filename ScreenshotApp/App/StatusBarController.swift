import AppKit
import ObjectiveC

@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem

    init(
        onInteractiveCapture: @escaping () -> Void,
        onDisplayCapture: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        statusItem.button?.title = "轻截"
        if let image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "轻截") {
            image.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.imagePosition = .imageLeading
        }
        statusItem.button?.toolTip = "轻截"

        let menu = NSMenu()
        menu.addItem(Self.item(title: "开始截图", keyEquivalent: "", action: onInteractiveCapture))
        menu.addItem(Self.item(title: "全屏截图", keyEquivalent: "", action: onDisplayCapture))
        menu.addItem(.separator())
        menu.addItem(Self.item(title: "偏好设置…", keyEquivalent: ",", action: onOpenSettings))
        menu.addItem(.separator())
        menu.addItem(Self.item(title: "退出轻截", keyEquivalent: "q", action: onQuit))
        statusItem.menu = menu
    }

    private static func item(title: String, keyEquivalent: String, action: @escaping () -> Void) -> NSMenuItem {
        let target = MenuActionTarget(action: action)
        let item = NSMenuItem(title: title, action: #selector(MenuActionTarget.performAction), keyEquivalent: keyEquivalent)
        item.target = target
        objc_setAssociatedObject(item, &AssociatedKeys.actionTarget, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return item
    }
}

private final class MenuActionTarget: NSObject {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func performAction() { action() }
}

private enum AssociatedKeys {
    nonisolated(unsafe) static var actionTarget: UInt8 = 0
}
