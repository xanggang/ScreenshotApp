import AppKit

@MainActor
protocol CaptureOverlayControllerDelegate: AnyObject {
    func overlayController(
        _ controller: CaptureOverlayController,
        didRequest action: CaptureOverlayAction,
        for rect: CGRect,
        on screen: NSScreen
    )
    func overlayControllerDidCancel(_ controller: CaptureOverlayController)
    func overlayController(_ controller: CaptureOverlayController, windowAt globalPoint: CGPoint) -> CGRect?
}

@MainActor
final class CaptureOverlayController: NSObject {
    weak var delegate: CaptureOverlayControllerDelegate?
    private(set) var windows: [CaptureOverlayWindow] = []

    func present() {
        dismiss()
        windows = NSScreen.screens.map { screen in
            let view = CaptureOverlayView()
            view.delegate = self
            let window = CaptureOverlayWindow(screen: screen, contentView: view)
            window.orderFrontRegardless()
            return window
        }
        windows.first?.makeKey()
        windows.first?.contentView?.window?.makeFirstResponder(windows.first?.contentView)
    }

    func dismiss() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

extension CaptureOverlayController: CaptureOverlayViewDelegate {
    func overlayDidMovePointer(_ overlay: CaptureOverlayView, to point: CGPoint) {
        guard !overlay.selection.hasSelection, let window = overlay.window else { return }
        let globalPoint = window.convertPoint(toScreen: point)
        guard let globalWindowRect = delegate?.overlayController(self, windowAt: globalPoint) else {
            overlay.highlightedWindowRect = nil
            return
        }
        overlay.highlightedWindowRect = window.convertFromScreen(globalWindowRect)
    }

    func overlay(_ overlay: CaptureOverlayView, didRequest action: CaptureOverlayAction, for rect: CGRect) {
        guard let window = overlay.window, let screen = window.screen else { return }
        delegate?.overlayController(self, didRequest: action, for: window.convertToScreen(rect), on: screen)
    }

    func overlayDidCancel(_ overlay: CaptureOverlayView) {
        delegate?.overlayControllerDidCancel(self)
    }
}
