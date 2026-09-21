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
                cropRectInDisplayPoints: sourceRect,
                displayPointSize: display.frame.size,
                // Capture the entire display, then crop the returned image.
                // SCStreamConfiguration.sourceRect has inconsistent scaling on
                // mixed-DPI displays, which can otherwise crop the wrong area.
                pixelSize: (width: display.width, height: display.height),
                scale: scale
            )

        case let .window(windowID):
            guard let window = content.windows.first(where: { $0.id == windowID }) else {
                throw ScreenshotAppError.windowNotFound(windowID)
            }
            let scale = Self.scale(forWindowBounds: window.bounds, displays: content.displays)
            request = CaptureRequest(
                filter: SCContentFilter(desktopIndependentWindow: window.screenCaptureWindow),
                cropRectInDisplayPoints: nil,
                displayPointSize: nil,
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
                cropRectInDisplayPoints: nil,
                displayPointSize: nil,
                pixelSize: (width: display.width, height: display.height),
                scale: scale
            )
        }

        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.width = request.pixelSize.width
        configuration.height = request.pixelSize.height
        do {
            let capturedImage = try await SCScreenshotManager.captureImage(
                contentFilter: request.filter,
                configuration: configuration
            )
            let image: CGImage
            if let cropRect = request.cropRectInDisplayPoints,
               let displayPointSize = request.displayPointSize {
                image = try Self.crop(
                    capturedImage,
                    to: cropRect,
                    inDisplayOfPointSize: displayPointSize
                )
            } else {
                image = capturedImage
            }
            return CaptureResult(
                image: image,
                target: target,
                scale: request.cropRectInDisplayPoints == nil
                    ? request.scale
                    : CGFloat(image.width) / request.cropRectInDisplayPoints!.width,
                capturedAt: Date()
            )
        } catch {
            throw ScreenshotAppError.captureFailed(error.localizedDescription)
        }
    }

    private struct CaptureRequest {
        let filter: SCContentFilter
        let cropRectInDisplayPoints: CGRect?
        let displayPointSize: CGSize?
        let pixelSize: (width: Int, height: Int)
        let scale: CGFloat
    }

    private static func crop(
        _ image: CGImage,
        to rectInDisplayPoints: CGRect,
        inDisplayOfPointSize displayPointSize: CGSize
    ) throws -> CGImage {
        guard displayPointSize.width > 0, displayPointSize.height > 0 else {
            throw ScreenshotAppError.captureFailed("显示器尺寸无效")
        }

        let xScale = CGFloat(image.width) / displayPointSize.width
        let yScale = CGFloat(image.height) / displayPointSize.height
        let cropRect = CGRect(
            x: (rectInDisplayPoints.minX * xScale).rounded(.down),
            y: (rectInDisplayPoints.minY * yScale).rounded(.down),
            width: (rectInDisplayPoints.width * xScale).rounded(.up),
            height: (rectInDisplayPoints.height * yScale).rounded(.up)
        ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral

        guard cropRect.width >= 1, cropRect.height >= 1,
              let cropped = image.cropping(to: cropRect) else {
            throw ScreenshotAppError.captureFailed("选区超出显示器范围")
        }
        return cropped
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
