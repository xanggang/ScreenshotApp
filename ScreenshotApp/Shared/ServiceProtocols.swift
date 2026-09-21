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
    /// Displays the pin close to the source rectangle when one is available.
    func createPin(for image: CGImage, near sourceFrame: CGRect?)
    func closeAllPins()
}
