import CoreGraphics

protocol ScreenCapturing: Sendable {
    func availableContent() async throws -> AvailableCaptureContent
    func capture(_ target: CaptureTarget) async throws -> CaptureResult
}

@MainActor
protocol CaptureCoordinating: AnyObject {
    func beginCapture(mode: CaptureMode)
    func cancelCapture()
}

@MainActor
protocol ImageExporting: AnyObject {
    func copyToPasteboard(_ image: CGImage) async throws
    func save(_ image: CGImage) async throws
}

@MainActor
protocol PinWindowManaging: AnyObject {
    func createPin(for image: CGImage)
    func closeAllPins()
}
