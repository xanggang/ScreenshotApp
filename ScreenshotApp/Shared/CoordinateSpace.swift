import CoreGraphics

struct GlobalPointRect: Sendable, Equatable {
    let value: CGRect
    init(_ value: CGRect) { self.value = value }
}

struct DisplayPointRect: Sendable, Equatable {
    let value: CGRect
    init(_ value: CGRect) { self.value = value }
}

struct ImagePixelRect: Sendable, Equatable {
    let value: CGRect
    init(_ value: CGRect) { self.value = value }
}

protocol CoordinateConverting: Sendable {
    func displayPoints(from globalPoints: GlobalPointRect, on display: CaptureDisplay) -> DisplayPointRect
    func imagePixels(from displayPoints: DisplayPointRect, scale: CGFloat, imageHeight: CGFloat) -> ImagePixelRect
}
