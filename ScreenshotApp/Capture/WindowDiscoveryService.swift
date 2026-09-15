import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A snapshot of capturable ScreenCaptureKit objects. The snapshot is deliberately
/// short lived: callers should refresh it when a new interactive capture starts.
struct DiscoveredCaptureContent: @unchecked Sendable {
    let displays: [SCDisplay]
    let windows: [DiscoveredWindow]
    let applications: [SCRunningApplication]
}

struct DiscoveredWindow: @unchecked Sendable, Identifiable {
    let screenCaptureWindow: SCWindow
    let layer: Int
    let bounds: CGRect

    var id: CGWindowID { screenCaptureWindow.windowID }
    var ownerProcessID: pid_t { screenCaptureWindow.owningApplication?.processID ?? 0 }
    var ownerName: String { screenCaptureWindow.owningApplication?.applicationName ?? "" }
    var title: String { screenCaptureWindow.title ?? "" }
}

protocol WindowDiscovering: Sendable {
    func discover() async throws -> DiscoveredCaptureContent
}

final class WindowDiscoveryService: WindowDiscovering, @unchecked Sendable {
    private let minimumWindowSize: CGFloat
    private let excludedProcessID: pid_t

    init(
        minimumWindowSize: CGFloat = 20,	
        excludedProcessID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) {
        self.minimumWindowSize = minimumWindowSize
        self.excludedProcessID = excludedProcessID
    }

    func discover() async throws -> DiscoveredCaptureContent {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        let supplementalInfo = Self.coreGraphicsWindowInfo()

        let windows = content.windows.compactMap { window -> DiscoveredWindow? in
            guard window.isOnScreen,
                  let application = window.owningApplication,
                  application.processID != excludedProcessID,
                  window.frame.width >= minimumWindowSize,
                  window.frame.height >= minimumWindowSize else {
                return nil
            }

            let info = supplementalInfo[window.windowID]
            let layer = info?.layer ?? 0
            guard Self.isUsefulWindow(window, layer: layer, supplemental: info) else {
                return nil
            }

            return DiscoveredWindow(
                screenCaptureWindow: window,
                layer: layer,
                bounds: info?.bounds ?? window.frame
            )
        }
        .sorted { lhs, rhs in
            // CGWindowListCopyWindowInfo is ordered front-to-back. Preserve that
            // order through the recorded index when possible.
            (supplementalInfo[lhs.id]?.order ?? Int.max)
                < (supplementalInfo[rhs.id]?.order ?? Int.max)
        }

        return DiscoveredCaptureContent(
            displays: content.displays,
            windows: windows,
            applications: content.applications
        )
    }

    private static func isUsefulWindow(
        _ window: SCWindow,
        layer: Int,
        supplemental: SupplementalWindowInfo?
    ) -> Bool {
        // Normal application windows live at layer 0. A small number of useful
        // panels/menus use nearby layers, while Dock, menu bar and desktop windows
        // live much higher. Keeping the range narrow avoids selecting system UI.
        guard (-1...3).contains(layer) else { return false }
        if supplemental?.alpha == 0 { return false }

        let owner = window.owningApplication?.applicationName.lowercased() ?? ""
        if owner == "dock" || owner == "windowmanager" { return false }
        return true
    }

    private struct SupplementalWindowInfo {
        let bounds: CGRect
        let layer: Int
        let alpha: Double
        let order: Int
    }

    private static func coreGraphicsWindowInfo() -> [CGWindowID: SupplementalWindowInfo] {
        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return [:]
        }

        var result: [CGWindowID: SupplementalWindowInfo] = [:]
        result.reserveCapacity(rawWindows.count)

        for (order, raw) in rawWindows.enumerated() {
            guard let number = raw[kCGWindowNumber as String] as? NSNumber,
                  let boundsDictionary = raw[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(
                      dictionaryRepresentation: boundsDictionary as CFDictionary
                  ) else {
                continue
            }
            let id = CGWindowID(number.uint32Value)
            result[id] = SupplementalWindowInfo(
                bounds: bounds,
                layer: (raw[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                alpha: (raw[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                order: order
            )
        }
        return result
    }
}
