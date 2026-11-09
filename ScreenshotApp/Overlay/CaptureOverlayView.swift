import AppKit
import Carbon

enum AnnotationTool: String, CaseIterable {
    case select = "选择", rectangle = "矩形", ellipse = "圆圈", arrow = "箭头", pen = "画笔", text = "文字", mosaic = "马赛克"
    static var drawingTools: [AnnotationTool] { allCases.filter { $0 != .select } }
}

struct CaptureAnnotation {
    var tool: AnnotationTool
    var points: [CGPoint]
    var text = ""
    var color: NSColor = .systemRed
    var width: CGFloat = 3
    var fontSize: CGFloat = 22

    var rect: CGRect {
        guard let first = points.first, let last = points.last else { return .zero }
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x-first.x), height: abs(last.y-first.y))
    }

    func draw(in context: CGContext) {
        guard let first = points.first, let last = points.last else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch tool {
        case .rectangle: context.stroke(rect)
        case .ellipse: context.strokeEllipse(in: rect)
        case .arrow:
            context.move(to: first); context.addLine(to: last); context.strokePath()
            let angle = atan2(last.y-first.y, last.x-first.x)
            let length = max(12, width * 4)
            context.move(to: last)
            context.addLine(to: CGPoint(x: last.x-length*cos(angle-0.45), y: last.y-length*sin(angle-0.45)))
            context.move(to: last)
            context.addLine(to: CGPoint(x: last.x-length*cos(angle+0.45), y: last.y-length*sin(angle+0.45)))
            context.strokePath()
        case .pen:
            context.move(to: first)
            points.dropFirst().forEach { context.addLine(to: $0) }
            context.strokePath()
        case .text:
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (text as NSString).draw(at: first, withAttributes: [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: color])
            NSGraphicsContext.restoreGraphicsState()
        case .mosaic:
            context.clip(to: rect)
            // Opaque replacement pixels never retain readable source content.
            // Preview and export share this renderer and the same grid origin.
            context.setBlendMode(.copy)
            context.setFillColor(NSColor(white: 0.32, alpha: 1).cgColor)
            context.fill(rect)
            let blockSize = max(8, width * 3)
            let startX = floor(rect.minX / blockSize) * blockSize
            let startY = floor(rect.minY / blockSize) * blockSize
            var row = 0
            for y in stride(from: startY, to: rect.maxY, by: blockSize) {
                var column = 0
                for x in stride(from: startX, to: rect.maxX, by: blockSize) {
                    let shade = CGFloat([0.24, 0.38, 0.48, 0.30][(row * 3 + column) % 4])
                    context.setFillColor(NSColor(white: shade, alpha: 1).cgColor)
                    context.fill(CGRect(x: x, y: y, width: blockSize, height: blockSize))
                    column += 1
                }
                row += 1
            }
        case .select: break
        }
    }
}

@MainActor
struct AnnotationSnapshot {
    let items: [CaptureAnnotation]
    let selection: CGRect

    func render(on image: CGImage) -> CGImage {
        guard !items.isEmpty,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        let pixelBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: pixelBounds)
        let scale = CGFloat(image.width) / selection.width
        context.scaleBy(x: scale, y: CGFloat(image.height) / selection.height)
        context.translateBy(x: -selection.minX, y: -selection.minY)
        context.clip(to: selection)
        for item in items {
            item.draw(in: context)
        }
        return context.makeImage() ?? image
    }
}

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
    private var annotationTool: AnnotationTool = .select
    private var annotations: [CaptureAnnotation] = []
    private var draft: CaptureAnnotation?
    private var selectedSize = 1
    private var selectedColor = 6
    private let palette: [NSColor] = [.systemBlue, .systemGreen, .systemYellow, .darkGray, .white, .black, .systemRed]
    private var textEditor: NSTextField?
    private var textOrigin = CGPoint.zero
    private var selectedAnnotation: Int?
    private var editingTextIndex: Int?
    private var editStartPoint: CGPoint?
    private var editOriginal: CaptureAnnotation?
    private var editCorner: Int?
    var annotationSnapshot: AnnotationSnapshot {
        commitText()
        return AnnotationSnapshot(items: annotations, selection: selection.rect)
    }

    init(selection: SelectionModel = SelectionModel()) {
        self.selection = selection
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    // Overlays are created on every display, but only one can be key at a
    // time. Accept the activating click so the first click on another display
    // immediately selects the window/region instead of being discarded.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
            context.saveGState()
            context.clip(to: selection.rect)
            for item in annotations { item.draw(in: context) }
            draft?.draw(in: context)
            drawAnnotationSelection(in: context)
            context.restoreGState()
            drawHandles(context: context)
            drawSizeLabel(context: context)
            drawToolbar(context: context)
            drawAnnotationToolbar()
            drawStyleToolbar()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        delegate?.overlayDidMovePointer(self, to: point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if selection.hasSelection, (annotationTool != .select || selectedAnnotation != nil),
           let index = styleButtonRects().firstIndex(where: { $0.contains(point) }) {
            if index < 3 { selectedSize = index }
            else if annotationTool != .mosaic { selectedColor = index - 3 }
            if let index = selectedAnnotation, annotations.indices.contains(index) {
                annotations[index].color = palette[selectedColor]
                annotations[index].width = currentWidth
                annotations[index].fontSize = currentFontSize
            }
            textEditor?.font = .systemFont(ofSize: currentFontSize)
            textEditor?.textColor = palette[selectedColor]
            needsDisplay = true
            return
        }
        commitText()
        if selection.hasSelection, let index = annotationButtonRects().firstIndex(where: { $0.contains(point) }) {
            selectedAnnotation = nil
            if index < AnnotationTool.drawingTools.count { annotationTool = AnnotationTool.drawingTools[index] }
            else { _ = annotations.popLast() }
            needsDisplay = true
            return
        }
        if selection.hasSelection, let action = toolbarAction(at: point) {
            delegate?.overlay(self, didRequest: action, for: selection.rect)
            return
        }
        if selection.hasSelection, toolbarStripRect.contains(point) { return }
        if selection.hasSelection {
            if let index = selectedAnnotation,
               let corner = annotationHandles(for: annotations[index]).firstIndex(where: { $0.contains(point) }) {
                editCorner = corner
                editStartPoint = point
                editOriginal = annotations[index]
                return
            }
            selectedAnnotation = annotations.indices.reversed().first(where: {
                annotationContains(point, item: annotations[$0])
            })
            if let index = selectedAnnotation {
                let item = annotations[index]
                selectedColor = palette.firstIndex(where: { $0.isEqual(item.color) }) ?? selectedColor
                if event.clickCount == 2, item.tool == .text, let origin = item.points.first {
                    beginText(at: origin)
                    textOrigin = origin
                    editingTextIndex = index
                    textEditor?.stringValue = item.text
                    textEditor?.font = .systemFont(ofSize: item.fontSize)
                    textEditor?.textColor = item.color
                } else {
                    editCorner = nil
                    editStartPoint = point
                    editOriginal = item
                }
                needsDisplay = true
                return
            }
            needsDisplay = true
        }
        if selection.hasSelection, annotationTool != .select, selection.rect.contains(point) {
            if annotationTool == .text {
                beginText(at: point)
            } else {
                draft = CaptureAnnotation(tool: annotationTool, points: [point, point], color: palette[selectedColor], width: currentWidth)
            }
            needsDisplay = true
            return
        }
        if selection.hasSelection, let action = toolbarAction(at: point) {
            delegate?.overlay(self, didRequest: action, for: selection.rect)
            return
        } else if !annotations.isEmpty {
            // Keep annotation coordinates stable once editing has started.
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
        if let index = selectedAnnotation, let start = editStartPoint, let original = editOriginal {
            var item = original
            let originalBounds = annotationBounds(original)
            if let corner = editCorner, originalBounds.width > 0, originalBounds.height > 0 {
                let anchors = [CGPoint(x: originalBounds.maxX, y: originalBounds.maxY), CGPoint(x: originalBounds.minX, y: originalBounds.maxY), CGPoint(x: originalBounds.maxX, y: originalBounds.minY), CGPoint(x: originalBounds.minX, y: originalBounds.minY)]
                let anchor = anchors[corner]
                let dragged = CGPoint(x: min(max(point.x, selection.rect.minX), selection.rect.maxX), y: min(max(point.y, selection.rect.minY), selection.rect.maxY))
                let target = CGRect(x: min(anchor.x, dragged.x), y: min(anchor.y, dragged.y), width: max(8, abs(anchor.x-dragged.x)), height: max(8, abs(anchor.y-dragged.y)))
                item.points = original.points.map { CGPoint(x: target.minX + ($0.x-originalBounds.minX)*target.width/originalBounds.width, y: target.minY + ($0.y-originalBounds.minY)*target.height/originalBounds.height) }
                if item.tool == .text { item.fontSize = max(10, original.fontSize * target.height/originalBounds.height) }
            } else {
                let dx = min(max(point.x-start.x, selection.rect.minX-originalBounds.minX), selection.rect.maxX-originalBounds.maxX)
                let dy = min(max(point.y-start.y, selection.rect.minY-originalBounds.minY), selection.rect.maxY-originalBounds.maxY)
                item.points = original.points.map { CGPoint(x: $0.x+dx, y: $0.y+dy) }
            }
            annotations[index] = item
            needsDisplay = true
            return
        }
        if draft != nil {
            let clamped = CGPoint(x: min(max(point.x, selection.rect.minX), selection.rect.maxX), y: min(max(point.y, selection.rect.minY), selection.rect.maxY))
            if annotationTool == .pen { draft?.points.append(clamped) }
            else { draft?.points[1] = clamped }
            needsDisplay = true
            return
        }
        switch selection.phase {
        case .selecting: selection.updateSelection(to: point)
        case .moving: selection.updateMove(to: point, constrainedTo: bounds)
        case .resizing: selection.updateResize(to: point)
        default: break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if editStartPoint != nil {
            editStartPoint = nil
            editOriginal = nil
            editCorner = nil
            return
        }
        if let draft {
            annotations.append(draft)
            self.draft = nil
            needsDisplay = true
            return
        }
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
        if event.modifierFlags.contains(.command), event.keyCode == UInt16(kVK_ANSI_Z) {
            selectedAnnotation = nil
            _ = annotations.popLast(); needsDisplay = true; return
        }
        if (event.keyCode == 51 || event.keyCode == 117), let index = selectedAnnotation {
            annotations.remove(at: index)
            selectedAnnotation = nil
            needsDisplay = true
            return
        }
        if !annotations.isEmpty, (123...126).contains(event.keyCode) { return }
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
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: NSColor.black.withAlphaComponent(0.2).cgColor)
        context.setFillColor(NSColor(white: 0.98, alpha: 1).cgColor)
        context.addPath(CGPath(roundedRect: toolbarStripRect, cornerWidth: 9, cornerHeight: 9, transform: nil))
        context.fillPath()
        context.restoreGState()
        let separatorX = toolbarStripRect.minX + 10 + CGFloat(AnnotationTool.drawingTools.count + 1) * toolbarSlotWidth + 5
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: separatorX, y: toolbarStripRect.minY + 13))
        context.addLine(to: CGPoint(x: separatorX, y: toolbarStripRect.maxY - 13))
        context.strokePath()
        for (action, rect) in toolbarButtonRects() {
            let iconIndex: Int
            switch action {
            case .copy: iconIndex = 10
            case .save: iconIndex = 7
            case .pin: iconIndex = 8
            }
            if drawToolbarIcon(iconIndex, in: rect) { continue }
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
        let actions: [CaptureOverlayAction] = [.copy, .save, .pin]
        return actions.enumerated().map { index, action in
            let x = toolbarStripRect.minX + 22 + CGFloat(AnnotationTool.drawingTools.count + 1 + index) * toolbarSlotWidth
            return (action, CGRect(x: x, y: toolbarBaseY + 4, width: toolbarSlotWidth, height: 36))
        }
    }

    private func annotationButtonRects() -> [CGRect] {
        let count = AnnotationTool.drawingTools.count + 1
        return (0..<count).map { CGRect(x: toolbarStripRect.minX + 10 + CGFloat($0)*toolbarSlotWidth, y: toolbarBaseY + 4, width: toolbarSlotWidth, height: 36) }
    }

    private var toolbarSlotWidth: CGFloat { min(44, max(24, (bounds.width - 48) / 10)) }

    private var toolbarStripRect: CGRect {
        let width = toolbarSlotWidth * 10 + 32
        let x = max(4, min(selection.rect.maxX - width, bounds.maxX - width - 4))
        return CGRect(x: x, y: toolbarBaseY, width: width, height: 44)
    }

    private var toolbarBaseY: CGFloat {
        let below = selection.rect.minY - 54
        if below >= bounds.minY + 42 { return below }
        return max(bounds.minY + 42, min(selection.rect.maxY + 10, bounds.maxY - 48))
    }

    private var currentWidth: CGFloat { [CGFloat(2), 4, 7][selectedSize] }
    private var currentFontSize: CGFloat { [CGFloat(16), 22, 32][selectedSize] }

    private func beginText(at point: CGPoint) {
        let height: CGFloat = 44
        let origin = CGPoint(x: min(point.x, selection.rect.maxX - 60), y: max(selection.rect.minY, min(point.y, selection.rect.maxY - height)))
        let field = NSTextField(frame: CGRect(x: origin.x, y: origin.y, width: max(60, selection.rect.maxX - origin.x), height: height))
        field.font = .systemFont(ofSize: currentFontSize)
        field.textColor = palette[selectedColor]
        field.backgroundColor = NSColor.white.withAlphaComponent(0.15)
        field.isBordered = true
        field.focusRingType = .none
        field.placeholderString = "输入文字"
        field.target = self
        field.action = #selector(finishText)
        addSubview(field)
        textEditor = field
        textOrigin = CGPoint(x: origin.x + 3, y: origin.y + 8)
        window?.makeKey()
        window?.makeFirstResponder(field)
    }

    @objc private func finishText() {
        commitText()
        window?.makeFirstResponder(self)
    }

    private func commitText() {
        guard let field = textEditor else { return }
        let text = field.stringValue
        if !text.isEmpty {
            let item = CaptureAnnotation(tool: .text, points: [textOrigin], text: text, color: field.textColor ?? palette[selectedColor], fontSize: field.font?.pointSize ?? currentFontSize)
            if let index = editingTextIndex, annotations.indices.contains(index) { annotations[index] = item }
            else { annotations.append(item) }
        }
        editingTextIndex = nil
        textEditor = nil
        field.removeFromSuperview()
        needsDisplay = true
    }

    private func styleButtonRects() -> [CGRect] {
        let count = annotationTool == .mosaic ? 3 : 3 + palette.count
        let width: CGFloat = 28
        let total = CGFloat(count) * width
        let x = max(4, min(toolbarStripRect.minX + 10, bounds.maxX - total - 4))
        let y = toolbarBaseY - 36
        return (0..<count).map { CGRect(x: x + CGFloat($0) * width, y: y, width: width, height: 30) }
    }

    private func drawStyleToolbar() {
        guard annotationTool != .select || selectedAnnotation != nil else { return }
        let rects = styleButtonRects()
        if let first = rects.first, let last = rects.last {
            NSColor(white: 0.98, alpha: 1).setFill()
            NSBezierPath(roundedRect: first.union(last).insetBy(dx: -4, dy: -2), xRadius: 6, yRadius: 6).fill()
        }
        for (index, rect) in rects.enumerated() {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(rect: rect).fill()
            if index < 3 {
                let color = index == selectedSize ? NSColor.controlAccentColor : NSColor.labelColor
                color.setFill()
                if annotationTool == .text || (selectedAnnotation.map { annotations[$0].tool == .text } ?? false) {
                    (["小", "中", "大"][index] as NSString).draw(at: CGPoint(x: rect.minX + 7, y: rect.minY + 8), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color])
                } else {
                    let diameter = CGFloat(3 + index * 3)
                    NSBezierPath(ovalIn: CGRect(x: rect.midX - diameter/2, y: rect.midY - diameter/2, width: diameter, height: diameter)).fill()
                }
            } else {
                palette[index - 3].setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 7), xRadius: 2, yRadius: 2).fill()
                if index - 3 == selectedColor {
                    NSColor.controlAccentColor.setStroke()
                    let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 4), xRadius: 3, yRadius: 3)
                    outline.lineWidth = 2
                    outline.stroke()
                }
            }
        }
    }

    private func annotationBounds(_ item: CaptureAnnotation) -> CGRect {
        guard let first = item.points.first else { return .zero }
        if item.tool == .text {
            let size = (item.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: item.fontSize)])
            return CGRect(origin: first, size: size)
        }
        let xs = item.points.map(\.x)
        let ys = item.points.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: max(1, (xs.max() ?? 0)-(xs.min() ?? 0)), height: max(1, (ys.max() ?? 0)-(ys.min() ?? 0)))
    }

    private func annotationContains(_ point: CGPoint, item: CaptureAnnotation) -> Bool {
        let rect = annotationBounds(item)
        let tolerance = max(6, item.width / 2 + 3)
        guard rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
        switch item.tool {
        case .text, .mosaic: return true
        case .rectangle:
            return !rect.insetBy(dx: tolerance, dy: tolerance).contains(point)
        case .ellipse:
            let rx = max(1, rect.width / 2)
            let ry = max(1, rect.height / 2)
            let normalized = hypot((point.x-rect.midX)/rx, (point.y-rect.midY)/ry)
            return abs(normalized - 1) * min(rx, ry) <= tolerance
        case .arrow, .pen:
            guard item.points.count > 1 else { return false }
            for index in 1..<item.points.count {
                let a = item.points[index-1], b = item.points[index]
                let dx = b.x-a.x, dy = b.y-a.y
                let length = dx*dx + dy*dy
                let t = length > 0 ? min(1, max(0, ((point.x-a.x)*dx + (point.y-a.y)*dy)/length)) : 0
                if hypot(point.x-a.x-t*dx, point.y-a.y-t*dy) <= tolerance { return true }
            }
            return false
        case .select: return false
        }
    }

    private func annotationHandles(for item: CaptureAnnotation) -> [CGRect] {
        let rect = annotationBounds(item)
        return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)].map { CGRect(x: $0.x-5, y: $0.y-5, width: 10, height: 10) }
    }

    private func drawAnnotationSelection(in context: CGContext) {
        guard let index = selectedAnnotation, annotations.indices.contains(index) else { return }
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1)
        context.stroke(annotationBounds(annotations[index]).insetBy(dx: -2, dy: -2))
        context.setFillColor(NSColor.white.cgColor)
        for rect in annotationHandles(for: annotations[index]) {
            context.fill(rect)
            context.stroke(rect)
        }
    }

    private func drawAnnotationToolbar() {
        let labels = AnnotationTool.drawingTools.map(\.rawValue) + ["撤销"]
        for (index, rect) in annotationButtonRects().enumerated() {
            let active = index < AnnotationTool.drawingTools.count && AnnotationTool.drawingTools[index] == annotationTool
            if active {
                NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 5, dy: 3), xRadius: 5, yRadius: 5).fill()
            }
            if drawToolbarIcon(index, in: rect) { continue }
            (labels[index] as NSString).draw(at: CGPoint(x: rect.minX+7, y: rect.minY+8), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: active ? NSColor.white : NSColor.labelColor])
        }
    }

    private func drawToolbarIcon(_ index: Int, in rect: CGRect) -> Bool {
        guard let atlas = NSImage(named: "AnnotationToolbar") else { return false }
        // The generated atlas has eleven evenly spaced cells, with artwork
        // vertically centered. Crop away transparent padding at draw time.
        let cellWidth = atlas.size.width / 11
        let source = CGRect(
            x: CGFloat(index) * cellWidth,
            y: (atlas.size.height - cellWidth) / 2,
            width: cellWidth,
            height: cellWidth
        )
        let side = min(34, rect.width - 6, rect.height - 4)
        let destination = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        atlas.draw(in: destination, from: source, operation: .sourceOver, fraction: 1)
        return true
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
