import CoreGraphics
import Foundation
import ScreenCaptureKit

final class ScreenCaptureService: ScreenCapturing, @unchecked Sendable {
    private let discoveryService: any WindowDiscovering

    init(discoveryService: any WindowDiscovering = WindowDiscoveryService()) {
        self.discoveryService = discoveryService
    }

    func availableContent() async throws -> AvailableCaptureContent {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenshotAppError.permissionDenied
        }
        do {
            let discovered = try await discoveryService.discover()
            return AvailableCaptureContent(
                displays: discovered.displays.map { display in
                    CaptureDisplay(
                        id: display.displayID,
                        frameInGlobalPoints: GlobalPointRect(display.frame),
                        scale: Self.scale(for: display)
                    )
                },
                windows: discovered.windows.map { window in
                    CaptureWindow(
                        id: window.id,
                        ownerName: window.ownerName,
                        title: window.screenCaptureWindow.title,
                        frameInGlobalPoints: GlobalPointRect(window.bounds),
                        layer: window.layer
                    )
                }
            )
        } catch let error as ScreenshotAppError {
            throw error
        } catch {
            throw ScreenshotAppError.contentUnavailable
        }
    }

    func capture(_ target: CaptureTarget) async throws -> CaptureResult {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenshotAppError.permissionDenied
        }
        let content: DiscoveredCaptureContent
        do {
            content = try await discoveryService.discover()
        } catch {
            throw ScreenshotAppError.contentUnavailable
        }

        let request: CaptureRequest
        switch target {
        case let .region(displayID, rectInDisplay):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenshotAppError.displayNotFound(displayID)
            }
            let localDisplayBounds = CGRect(origin: .zero, size: display.frame.size)
            let sourceRect = rectInDisplay.standardized.intersection(localDisplayBounds)
            guard !sourceRect.isNull, sourceRect.width >= 1, sourceRect.height >= 1 else {
                throw ScreenshotAppError.captureFailed("The selected region is empty or outside the display.")
            }
            let scale = Self.scale(for: display)
            let filter = SCContentFilter(display: display, excludingWindows: [])
            request = CaptureRequest(
                filter: filter,
                sourceRect: sourceRect,
                pixelSize: Self.pixelSize(for: sourceRect.size, scale: scale),
                scale: scale
            )

        case let .window(windowID):
            guard let window = content.windows.first(where: { $0.id == windowID }) else {
                throw ScreenshotAppError.windowNotFound(windowID)
            }
            let scale = Self.scale(forWindowBounds: window.bounds, displays: content.displays)
            request = CaptureRequest(
                filter: SCContentFilter(desktopIndependentWindow: window.screenCaptureWindow),
                sourceRect: nil,
                pixelSize: Self.pixelSize(for: window.bounds.size, scale: scale),
                scale: scale
            )

        case let .display(displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenshotAppError.displayNotFound(displayID)
            }
            let scale = Self.scale(for: display)
            request = CaptureRequest(
                filter: SCContentFilter(display: display, excludingWindows: []),
                sourceRect: nil,
                pixelSize: (width: display.width, height: display.height),
                scale: scale
            )
        }

        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.width = request.pixelSize.width
        configuration.height = request.pixelSize.height
        if let sourceRect = request.sourceRect {
            configuration.sourceRect = sourceRect
        }

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: request.filter,
                configuration: configuration
            )
            return CaptureResult(
                image: image,
                target: target,
                scale: request.scale,
                capturedAt: Date()
            )
        } catch {
            throw ScreenshotAppError.captureFailed(error.localizedDescription)
        }
    }

    private struct CaptureRequest {
        let filter: SCContentFilter
        let sourceRect: CGRect?
        let pixelSize: (width: Int, height: Int)
        let scale: CGFloat
    }

    private static func scale(for display: SCDisplay) -> CGFloat {
        guard display.frame.width > 0 else { return 1 }
        return CGFloat(display.width) / display.frame.width
    }

    private static func scale(forWindowBounds bounds: CGRect, displays: [SCDisplay]) -> CGFloat {
        let bestDisplay = displays
            .map { ($0, $0.frame.intersection(bounds).area) }
            .max { $0.1 < $1.1 }?.0
        return bestDisplay.map(scale(for:)) ?? 1
    }

    private static func pixelSize(for pointSize: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        (
            width: max(1, Int((pointSize.width * scale).rounded())),
            height: max(1, Int((pointSize.height * scale).rounded()))
        )
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }
}
