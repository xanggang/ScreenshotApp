import AppKit

@MainActor
final class SelectionModel {
    enum Phase: Equatable {
        case idle
        case selecting
        case selected
        case moving
        case resizing(ResizeHandle)
    }

    enum ResizeHandle: CaseIterable, Equatable {
        case topLeft, top, topRight
        case left, right
        case bottomLeft, bottom, bottomRight
    }

    private(set) var phase: Phase = .idle
    private(set) var rect: CGRect = .zero
    private(set) var highlightedWindowRect: CGRect?

    private var dragStart: CGPoint = .zero
    private var initialRect: CGRect = .zero

    var hasSelection: Bool { rect.width >= 1 && rect.height >= 1 }

    func highlightWindow(_ rect: CGRect?) {
        guard phase == .idle else { return }
        highlightedWindowRect = rect
    }

    func beginSelection(at point: CGPoint) {
        highlightedWindowRect = nil
        dragStart = point
        initialRect = .zero
        rect = CGRect(origin: point, size: .zero)
        phase = .selecting
    }

    func updateSelection(to point: CGPoint) {
        guard phase == .selecting else { return }
        rect = Self.normalizedRect(from: dragStart, to: point)
    }

    func finishSelection() {
        guard phase == .selecting else { return }
        phase = hasSelection ? .selected : .idle
    }

    func selectWindow(rect: CGRect) {
        highlightedWindowRect = nil
        self.rect = rect.integral
        phase = .selected
    }

    func beginMove(at point: CGPoint) {
        guard phase == .selected, rect.contains(point) else { return }
        dragStart = point
        initialRect = rect
        phase = .moving
    }

    func updateMove(to point: CGPoint, constrainedTo bounds: CGRect) {
        guard phase == .moving else { return }
        let delta = CGPoint(x: point.x - dragStart.x, y: point.y - dragStart.y)
        var candidate = initialRect.offsetBy(dx: delta.x, dy: delta.y)
        candidate.origin.x = min(max(candidate.minX, bounds.minX), bounds.maxX - candidate.width)
        candidate.origin.y = min(max(candidate.minY, bounds.minY), bounds.maxY - candidate.height)
        rect = candidate.integral
    }

    func beginResize(_ handle: ResizeHandle, at point: CGPoint) {
        guard phase == .selected else { return }
        dragStart = point
        initialRect = rect
        phase = .resizing(handle)
    }

    func updateResize(to point: CGPoint, minimumSize: CGSize = CGSize(width: 8, height: 8)) {
        guard case let .resizing(handle) = phase else { return }

        var left = initialRect.minX
        var right = initialRect.maxX
        var bottom = initialRect.minY
        var top = initialRect.maxY

        switch handle {
        case .topLeft: left = point.x; top = point.y
        case .top: top = point.y
        case .topRight: right = point.x; top = point.y
        case .left: left = point.x
        case .right: right = point.x
        case .bottomLeft: left = point.x; bottom = point.y
        case .bottom: bottom = point.y
        case .bottomRight: right = point.x; bottom = point.y
        }

        if right - left < minimumSize.width {
            if [.topLeft, .left, .bottomLeft].contains(handle) { left = right - minimumSize.width }
            else { right = left + minimumSize.width }
        }
        if top - bottom < minimumSize.height {
            if [.bottomLeft, .bottom, .bottomRight].contains(handle) { bottom = top - minimumSize.height }
            else { top = bottom + minimumSize.height }
        }

        rect = CGRect(x: left, y: bottom, width: right - left, height: top - bottom).integral
    }

    func finishTransform() {
        switch phase {
        case .moving, .resizing: phase = .selected
        default: break
        }
    }

    func nudge(dx: CGFloat, dy: CGFloat, constrainedTo bounds: CGRect) {
        guard phase == .selected else { return }
        var candidate = rect.offsetBy(dx: dx, dy: dy)
        candidate.origin.x = min(max(candidate.minX, bounds.minX), bounds.maxX - candidate.width)
        candidate.origin.y = min(max(candidate.minY, bounds.minY), bounds.maxY - candidate.height)
        rect = candidate.integral
    }

    func reset() {
        phase = .idle
        rect = .zero
        highlightedWindowRect = nil
    }

    private static func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        ).integral
    }
}
