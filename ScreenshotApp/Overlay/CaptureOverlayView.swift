import AppKit
import Carbon

@MainActor
enum CaptureOverlayAction {
    case copy
    case save
    case pin
}

@MainActor
protocol CaptureOverlayViewDelegate: AnyObject {
    func overlayDidMovePointer(_ overlay: CaptureOverlayView, to point: CGPoint)
    func overlay(_ overlay: CaptureOverlayView, didRequest action: CaptureOverlayAction, for rect: CGRect)
    func overlayDidCancel(_ overlay: CaptureOverlayView)
}

@MainActor
final class CaptureOverlayView: NSView {
    weak var delegate: CaptureOverlayViewDelegate?
    let selection: SelectionModel

    var dimmingColor = NSColor.black.withAlphaComponent(0.32)
    var selectionStrokeColor = NSColor.controlAccentColor
    var highlightedWindowRect: CGRect? {
        didSet {
            selection.highlightWindow(highlightedWindowRect)
            needsDisplay = true
        }
    }

    private var trackingAreaToken: NSTrackingArea?
    private var activeHandle: SelectionModel.ResizeHandle?
    private var pendingWindowRect: CGRect?
    private let handleSize: CGFloat = 8
    private let minimumDragDistance: CGFloat = 4
    private let toolbarHeight: CGFloat = 34
    private let toolbarSpacing: CGFloat = 7

    init(selection: SelectionModel = SelectionModel()) {
        self.selection = selection
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaToken { removeTrackingArea(trackingAreaToken) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaToken = area
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.setFillColor(dimmingColor.cgColor)
        context.fill(bounds)

        let visibleRect = selection.hasSelection ? selection.rect : selection.highlightedWindowRect
        if let visibleRect {
            context.saveGState()
            context.setBlendMode(.clear)
            context.fill(visibleRect)
            context.restoreGState()

            context.setStrokeColor(selectionStrokeColor.cgColor)
            context.setLineWidth(1)
            context.stroke(visibleRect.insetBy(dx: 0.5, dy: 0.5))
        }

        if selection.hasSelection {
            drawHandles(context: context)
            drawSizeLabel(context: context)
            drawToolbar(context: context)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        delegate?.overlayDidMovePointer(self, to: point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let action = toolbarAction(at: point) {
            delegate?.overlay(self, didRequest: action, for: selection.rect)
            return
        } else if let handle = handle(at: point) {
            activeHandle = handle
            selection.beginResize(handle, at: point)
        } else if selection.hasSelection, selection.rect.contains(point) {
            selection.beginMove(at: point)
        } else {
            // Keep the hovered window as a candidate. A click captures it;
            // dragging from the same point turns into a free-form region.
            pendingWindowRect = selection.highlightedWindowRect?.contains(point) == true
                ? selection.highlightedWindowRect
                : nil
            selection.beginSelection(at: point)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch selection.phase {
        case .selecting: selection.updateSelection(to: point)
        case .moving: selection.updateMove(to: point, constrainedTo: bounds)
        case .resizing: selection.updateResize(to: point)
        default: break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch selection.phase {
        case .selecting:
            selection.finishSelection()
            let hasDragged = selection.rect.width >= minimumDragDistance || selection.rect.height >= minimumDragDistance
            if !hasDragged, let pendingWindowRect {
                selection.selectWindow(rect: pendingWindowRect)
            }
        case .moving, .resizing: selection.finishTransform()
        default: break
        }
        activeHandle = nil
        pendingWindowRect = nil
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            delegate?.overlayDidCancel(self)
        case 36, 76:
            guard selection.hasSelection else { return }
            delegate?.overlay(self, didRequest: .copy, for: selection.rect)
        case UInt16(kVK_ANSI_T):
            guard selection.hasSelection else { return }
            delegate?.overlay(self, didRequest: .pin, for: selection.rect)
        case 123:
            selection.nudge(dx: event.modifierFlags.contains(.shift) ? -10 : -1, dy: 0, constrainedTo: bounds)
        case 124:
            selection.nudge(dx: event.modifierFlags.contains(.shift) ? 10 : 1, dy: 0, constrainedTo: bounds)
        case 125:
            selection.nudge(dx: 0, dy: event.modifierFlags.contains(.shift) ? -10 : -1, constrainedTo: bounds)
        case 126:
            selection.nudge(dx: 0, dy: event.modifierFlags.contains(.shift) ? 10 : 1, constrainedTo: bounds)
        default:
            super.keyDown(with: event)
            return
        }
        needsDisplay = true
    }

    private func drawHandles(context: CGContext) {
        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(selectionStrokeColor.cgColor)
        context.setLineWidth(1)
        for rect in handleRects().values {
            context.fillEllipse(in: rect)
            context.strokeEllipse(in: rect)
        }
    }

    private func drawSizeLabel(context: CGContext) {
        let text = "\(Int(selection.rect.width)) × \(Int(selection.rect.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        var origin = CGPoint(x: selection.rect.minX, y: selection.rect.minY - textSize.height - 10)
        if origin.y < bounds.minY + 4 { origin.y = selection.rect.maxY + 6 }
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - textSize.width - 12)
        let background = CGRect(origin: CGPoint(x: origin.x - 6, y: origin.y - 3), size: CGSize(width: textSize.width + 12, height: textSize.height + 6))
        context.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
        context.addPath(CGPath(roundedRect: background, cornerWidth: 5, cornerHeight: 5, transform: nil))
        context.fillPath()
        text.draw(at: origin, withAttributes: attributes)
    }

    private func drawToolbar(context: CGContext) {
        for (action, rect) in toolbarButtonRects() {
            context.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 7, cornerHeight: 7, transform: nil))
            context.fillPath()
            context.setStrokeColor(NSColor.separatorColor.cgColor)
            context.setLineWidth(1)
            context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 6.5, cornerHeight: 6.5, transform: nil))
            context.strokePath()

            let title: String
            switch action {
            case .copy: title = "复制"
            case .save: title = "保存"
            case .pin: title = "贴图 T"
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(
                at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: attributes
            )
        }
    }

    private func handle(at point: CGPoint) -> SelectionModel.ResizeHandle? {
        handleRects().first(where: { $0.value.insetBy(dx: -3, dy: -3).contains(point) })?.key
    }

    private func toolbarAction(at point: CGPoint) -> CaptureOverlayAction? {
        toolbarButtonRects().first(where: { $0.1.contains(point) })?.0
    }

    private func toolbarButtonRects() -> [(CaptureOverlayAction, CGRect)] {
        let buttonWidth: CGFloat = 52
        let actions: [CaptureOverlayAction] = [.copy, .save, .pin]
        let width = buttonWidth * CGFloat(actions.count) + toolbarSpacing * CGFloat(actions.count - 1)
        var origin = CGPoint(x: selection.rect.maxX - width, y: selection.rect.minY - toolbarHeight - 10)
        if origin.y < bounds.minY + 4 { origin.y = selection.rect.maxY + 10 }
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - width - 4)

        return actions.enumerated().map { index, action in
            let x = origin.x + CGFloat(index) * (buttonWidth + toolbarSpacing)
            return (action, CGRect(x: x, y: origin.y, width: buttonWidth, height: toolbarHeight))
        }
    }

    private func handleRects() -> [SelectionModel.ResizeHandle: CGRect] {
        let rect = selection.rect
        let half = handleSize / 2
        func handle(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(x: x - half, y: y - half, width: handleSize, height: handleSize)
        }
        return [
            .topLeft: handle(rect.minX, rect.maxY),
            .top: handle(rect.midX, rect.maxY),
            .topRight: handle(rect.maxX, rect.maxY),
            .left: handle(rect.minX, rect.midY),
            .right: handle(rect.maxX, rect.midY),
            .bottomLeft: handle(rect.minX, rect.minY),
            .bottom: handle(rect.midX, rect.minY),
            .bottomRight: handle(rect.maxX, rect.minY)
        ]
    }
}
